import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

import AVKit

@MainActor
final class PlayerController: NSObject, ObservableObject {
    let player = AVPlayer()

    @Published var currentItem: VideoItem?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var errorMessage: String?
    @Published var osdMessage: String?
    @Published var currentTime: Double = 0
    /// 最近一次 seek 的目标位置：远端视频缓冲完成前，进度条停在这里（避免回跳）
    @Published var seekTarget: Double? = nil
    @Published var duration: Double = 0
    @Published var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
            if volume != oldValue { showOSD(volume == 0 ? "静音" : "音量 \(Int(volume * 100))%") }
        }
    }
    @Published var speed: Float {
        didSet { UserDefaults.standard.set(speed, forKey: "playerSpeed") }
    }
    @Published var showControls = true
    /// 当前播放上下文（来自同一文件夹/列表的兄弟视频），用于上一集/下一集与自动连播
    @Published var queue: [VideoItem] = []
    @Published var isPiPActive = false
    @Published var isPiPSupported = false
    @Published var subtitleNames: [String] = []
    @Published var selectedSubtitle: Int? = nil
    @Published var hasExternalSubtitle = false
    @Published var audioTrackNames: [String] = []
    @Published var selectedAudioTrack: Int? = nil
    @Published var currentCue: SubtitleCue?

    weak var store: LibraryStore?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var hideTask: Task<Void, Never>?
    private var osdTask: Task<Void, Never>?
    private var legibleGroup: AVMediaSelectionGroup?
    private var legibleOptions: [AVMediaSelectionOption] = []
    private var audibleGroup: AVMediaSelectionGroup?
    private var audibleOptions: [AVMediaSelectionOption] = []
    private var externalCues: [SubtitleCue] = []
    private var lastSaveTime = Date.distantPast
    private var endObserver: NSObjectProtocol?
    private var pipController: AVPictureInPictureController?
    private weak var attachedLayer: AVPlayerLayer?

    // MARK: - 设置项（设置页写入 UserDefaults）

    private var autoPlayNext: Bool { UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true }
    private var resumePlayback: Bool { UserDefaults.standard.object(forKey: "resumePlayback") as? Bool ?? true }

    var hasPrevious: Bool {
        guard let current = currentItem,
              let i = queue.firstIndex(where: { $0.url == current.url }) else { return false }
        return i > 0
    }

    var hasNext: Bool {
        guard let current = currentItem,
              let i = queue.firstIndex(where: { $0.url == current.url }) else { return false }
        return i + 1 < queue.count
    }

    override init() {
        // 直接初始化 @Published 的底层存储：在 super.init() 之前不能经属性包装器赋值
        _volume = Published(initialValue: UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 1)
        _speed = Published(initialValue: UserDefaults.standard.object(forKey: "playerSpeed") as? Float ?? 1)
        super.init()
        player.volume = volume
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.handleTime(time.seconds) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                self?.isPlaying = p.timeControlStatus == .playing
                self?.isBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        // 播放结束 → 记录进度并按设置自动连播
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.handlePlaybackEnded()
            }
        }
    }

    private func handlePlaybackEnded() {
        saveProgress()
        if autoPlayNext, let current = currentItem,
           let i = queue.firstIndex(where: { $0.url == current.url }), i + 1 < queue.count {
            let next = queue[i + 1]
            showOSD("即将播放：\(next.displayName)")
            play(next, queue: queue)
        } else {
            showControls = true
        }
    }

    func playNext() {
        guard let current = currentItem,
              let i = queue.firstIndex(where: { $0.url == current.url }),
              i + 1 < queue.count else { return }
        play(queue[i + 1], queue: queue)
    }

    func playPrevious() {
        // 与主流播放器一致：播放超过 5 秒时先回到片头，否则切上一个
        if currentTime > 5 {
            seek(to: 0)
            return
        }
        guard let current = currentItem,
              let i = queue.firstIndex(where: { $0.url == current.url }),
              i > 0 else { return }
        play(queue[i - 1], queue: queue)
    }

    // MARK: - 播放

    func play(_ item: VideoItem, queue: [VideoItem]? = nil) {
        saveProgress()
        // 未显式给出上下文时清空队列（从收藏/历史/拖拽等入口播放）
        self.queue = queue ?? []
        currentItem = item
        duration = item.duration
        currentTime = item.progress
        seekTarget = nil
        errorMessage = nil
        osdMessage = nil
        externalCues = []
        currentCue = nil
        hasExternalSubtitle = false
        legibleGroup = nil
        legibleOptions = []
        audibleGroup = nil
        audibleOptions = []
        subtitleNames = []
        selectedSubtitle = nil
        audioTrackNames = []
        selectedAudioTrack = nil

        let asset = AVURLAsset(url: item.url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.audioTimePitchAlgorithm = .timeDomain
        statusObservation?.invalidate()
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] pi, _ in
            Task { @MainActor in
                guard let self, pi === self.player.currentItem else { return }
                if pi.status == .readyToPlay {
                    let d = pi.duration.seconds
                    if d.isFinite && d > 0 {
                        self.duration = d
                        self.store?.updateProgress(url: self.currentItem?.url ?? item.url, seconds: self.currentTime,
                                                   duration: d, customName: self.currentItem?.customName)
                    }
                    await self.loadMediaOptions()
                } else if pi.status == .failed {
                    self.errorMessage = pi.error?.localizedDescription ?? "无法播放该视频（格式不支持或文件已损坏）"
                }
            }
        }
        player.replaceCurrentItem(with: playerItem)

        // 记忆播放位置：接近结尾则从头播（可在设置中关闭）
        if resumePlayback && item.progress > 5 && !item.isFinished {
            player.seek(to: CMTime(seconds: item.progress, preferredTimescale: 600))
        }
        player.play()
        player.defaultRate = speed
        player.rate = speed
        bumpInteraction()

        loadExternalSubtitleAuto(for: item.url)
    }

    func close() {
        saveProgress()
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        errorMessage = nil
        showControls = true
        hideTask?.cancel()
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        bumpInteraction()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : .greatestFiniteMagnitude))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        seekTarget = clamped
        if !externalCues.isEmpty { updateCue() }
        bumpInteraction()
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
        showOSD(delta > 0 ? "快进 \(Int(delta)) 秒" : "快退 \(Int(-delta)) 秒")
    }

    func setSpeed(_ s: Float) {
        speed = s
        player.defaultRate = s
        if isPlaying || player.timeControlStatus != .paused { player.rate = s }
        showOSD(String(format: "%.2gx", s))
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
        bumpInteraction()
    }

    // MARK: - 音轨与字幕

    private func loadMediaOptions() async {
        guard let item = player.currentItem else { return }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            legibleGroup = group
            legibleOptions = group.options
            subtitleNames = group.options.map(\.displayName)
        }
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
            audibleGroup = group
            audibleOptions = group.options
            audioTrackNames = group.options.map(\.displayName)
        }
    }

    func selectAudioTrack(index: Int) {
        selectedAudioTrack = index
        guard let group = audibleGroup, index < audibleOptions.count else { return }
        player.currentItem?.select(audibleOptions[index], in: group)
        showOSD("音轨：\(audibleOptions[index].displayName)")
    }

    func selectSubtitle(index: Int?) {
        selectedSubtitle = index
        if let index, index < legibleOptions.count, let group = legibleGroup {
            externalCues = []
            hasExternalSubtitle = false
            currentCue = nil
            player.currentItem?.select(legibleOptions[index], in: group)
        } else if let group = legibleGroup {
            player.currentItem?.select(nil, in: group)
        }
    }

    func pickExternalSubtitle() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = {
            var types = [UTType]()
            if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
            if let vtt = UTType(filenameExtension: "vtt") { types.append(vtt) }
            return types.isEmpty ? [.text] : types
        }()
        panel.message = "选择 SRT / VTT 字幕文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        externalCues = SubtitleParser.load(from: url)
        hasExternalSubtitle = !externalCues.isEmpty
        selectedSubtitle = nil
        if let group = legibleGroup {
            player.currentItem?.select(nil, in: group)
        }
    }

    private func loadExternalSubtitleAuto(for url: URL) {
        let base = url.deletingPathExtension()
        for ext in ["srt", "vtt"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                externalCues = SubtitleParser.load(from: candidate)
                hasExternalSubtitle = !externalCues.isEmpty
                return
            }
        }
    }

    // MARK: - 控制条显隐

    func bumpInteraction() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled && isPlaying { showControls = false }
        }
    }

    // MARK: - 内部

    private func handleTime(_ seconds: Double) {
        if seconds.isFinite && seconds > 0 {
            if let target = seekTarget {
                // seek 缓冲完成（真实时间追上目标位置）后切回真实时间显示
                if abs(seconds - target) < 2 {
                    seekTarget = nil
                    currentTime = seconds
                }
            } else {
                currentTime = seconds
            }
        }
        if !externalCues.isEmpty { updateCue() }
        if let url = currentItem?.url, Date().timeIntervalSince(lastSaveTime) > 5 {
            lastSaveTime = Date()
            store?.updateProgress(url: url, seconds: currentTime, duration: duration,
                                  customName: currentItem?.customName)
            store?.flush()
        }
    }

    private func updateCue() {
        let t = currentTime
        currentCue = externalCues.first { t >= $0.start && t <= $0.end }
    }

    private func saveProgress() {
        guard let url = currentItem?.url else { return }
        store?.updateProgress(url: url, seconds: currentTime, duration: duration,
                              customName: currentItem?.customName)
        store?.flush()
    }

    /// 居中 OSD 提示（快进/音量/倍速反馈），1 秒后自动消失
    private func showOSD(_ text: String) {
        osdMessage = text
        osdTask?.cancel()
        osdTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { osdMessage = nil }
        }
    }

    // MARK: - 画中画

    /// 播放视图创建 AVPlayerLayer 后登记，用于创建画中画控制器
    func attachPlayerLayer(_ layer: AVPlayerLayer) {
        guard layer !== attachedLayer else { return }
        attachedLayer = layer
        pipController?.delegate = nil
        pipController = nil
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPSupported = false
            return
        }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        pipController = controller
        isPiPSupported = controller != nil
    }

    func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }
}

extension PlayerController: AVPictureInPictureControllerDelegate {
    // @objc 协议回调声明为 nonisolated，回到主 actor 后再更新状态
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.showOSD("已进入画中画")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isPiPActive = false
            self.showOSD("画中画启动失败")
        }
    }
}
