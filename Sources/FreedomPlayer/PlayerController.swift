import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlayerController: ObservableObject {
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

    init() {
        volume = UserDefaults.standard.object(forKey: "playerVolume") as? Float ?? 1
        speed = UserDefaults.standard.object(forKey: "playerSpeed") as? Float ?? 1
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
    }

    // MARK: - 播放

    func play(_ item: VideoItem) {
        saveProgress()
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

        // 记忆播放位置：接近结尾则从头播
        if item.progress > 5 && !item.isFinished {
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
}
