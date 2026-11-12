import AVFoundation
import SwiftUI

struct VideoItem: Identifiable, Codable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    var isOnline: Bool
    var addedAt: Date
    var duration: Double
    var progress: Double
    var lastPlayed: Date?
    var customName: String?   // 网络视频的用户命名；nil 时按 URL 推导

    init(url: URL, isOnline: Bool, addedAt: Date, duration: Double,
         progress: Double, lastPlayed: Date?, customName: String? = nil) {
        self.url = url
        self.isOnline = isOnline
        self.addedAt = addedAt
        self.duration = duration
        self.progress = progress
        self.lastPlayed = lastPlayed
        self.customName = customName
    }

    var displayName: String {
        if let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if isOnline {
            // URL 带文件名就显示文件名（去扩展名），否则退回域名
            let name = url.deletingPathExtension().lastPathComponent
            return name.isEmpty ? (url.host ?? url.absoluteString) : name
        }
        return url.deletingPathExtension().lastPathComponent
    }
    var percent: Double { duration > 0 ? min(progress / duration, 1) : 0 }
    var isFinished: Bool { duration > 0 && progress >= duration - 15 }
    var folderName: String { url.deletingLastPathComponent().lastPathComponent }
}

/// 仅收录 AVFoundation 实际支持的容器格式（MKV/WMV/FLV/WebM 不受支持，见 AVURLAsset.audiovisualTypes）
enum SupportedFormats {
    static let videoExtensions = [
        "mp4", "mov", "m4v", "avi", "ts", "m2ts",
        "mpg", "mpeg", "3gp"
    ]
}

enum LibrarySection: Hashable {
    case home, all
    case onlineLinks      // 收藏链接（保存的网络视频）
    case onlineHistory    // 播放记录
    case directory(String?)   // nil = 媒体库根目录（显示已添加的文件夹）
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var onlineItems: [VideoItem] = []
    @Published private(set) var historyItems: [VideoItem] = []
    @Published private(set) var folders: [URL] = []
    @Published var isScanning = false

    private var progressDirty = false

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreedomPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    init() {
        load()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        folders = state.folders
        items = state.items
        onlineItems = state.onlineItems
        historyItems = state.history ?? []   // 旧版本 library.json 无此字段
    }

    func save() {
        let state = State(folders: folders, items: items, onlineItems: onlineItems, history: historyItems)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
        progressDirty = false
    }

    private struct State: Codable {
        var folders: [URL]
        var items: [VideoItem]
        var onlineItems: [VideoItem]
        var history: [VideoItem]?
    }

    // MARK: - 文件夹管理

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要加入媒体库的视频文件夹"
        if panel.runModal() == .OK {
            for u in panel.urls where !folders.contains(u) {
                folders.append(u)
            }
            Task { await rescan() }
        }
    }

    /// 程序化添加文件夹（拖拽进入）
    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
        save()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        // 精确匹配路径前缀（带分隔符），避免误删 /Movies2 之类同名前缀文件夹的内容
        items.removeAll { $0.url.path == url.path || $0.url.path.hasPrefix(url.path + "/") }
        save()
    }

    @MainActor
    func rescan() async {
        isScanning = true
        defer { isScanning = false }
        let folders = self.folders
        let oldItems = self.items

        // 目录遍历在后台线程进行，避免大媒体库卡住主线程
        let found: [VideoItem] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var found = [VideoItem]()
            for folder in folders {
                guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
                // allObjects 一次性取数组，避免 NSFastEnumeration 的 makeIterator 在 async 上下文不可用
                for case let fileURL as URL in enumerator.allObjects {
                    guard !fileURL.lastPathComponent.hasPrefix("."),
                          SupportedFormats.videoExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                    found.append(VideoItem(url: fileURL, isOnline: false, addedAt: Date(),
                                           duration: 0, progress: 0, lastPlayed: nil))
                }
            }
            return found
        }.value

        // 保留旧条目的进度、时长等状态
        var old = [String: VideoItem]()
        for item in oldItems { old[item.url.standardizedFileURL.path] = item }
        items = found
            .map { old[$0.url.standardizedFileURL.path] ?? $0 }
            .sorted { $0.addedAt < $1.addedAt }
        save()
        await loadMissingDurations()
    }

    /// 并发加载缺失时长（上限 8 路，避免海量文件时打满磁盘/解码器）
    private func loadMissingDurations() async {
        let targets = items.filter { $0.duration == 0 }.map { $0.url }
        guard !targets.isEmpty else { return }
        var next = 0
        var durations = [String: Double]()

        await withTaskGroup(of: (URL, Double?).self) { group in
            func addNext() {
                guard next < targets.count else { return }
                let url = targets[next]
                next += 1
                group.addTask { (url, await LibraryStore.duration(of: url)) }
            }
            for _ in 0..<min(8, targets.count) { addNext() }
            while let (url, d) = await group.next() {
                if let d { durations[url.absoluteString] = d }
                addNext()
            }
        }

        for i in items.indices where items[i].duration == 0 {
            if let d = durations[items[i].url.absoluteString] {
                items[i].duration = d
            }
        }
        save()
    }

    nonisolated static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds else { return nil }
        return seconds.isFinite ? seconds : nil
    }

    // MARK: - 在线视频

    func addOnline(url: URL, name: String? = nil) -> VideoItem {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = onlineItems.firstIndex(where: { $0.url == url }) {
            // 已收藏过：用户重新命名时更新名称
            if let trimmed, !trimmed.isEmpty, onlineItems[i].customName != trimmed {
                onlineItems[i].customName = trimmed
                save()
            }
            return onlineItems[i]
        }
        let item = VideoItem(url: url, isOnline: true, addedAt: Date(), duration: 0,
                             progress: 0, lastPlayed: nil, customName: trimmed)
        onlineItems.insert(item, at: 0)
        save()
        return item
    }

    func removeOnline(_ item: VideoItem) {
        onlineItems.removeAll { $0.id == item.id }
        save()
    }

    func isFavorite(url: URL) -> Bool {
        onlineItems.contains { $0.url == url }
    }

    /// 用户显式收藏/取消收藏（播放本身不会自动收藏）
    func setFavorite(_ item: VideoItem, _ favorite: Bool) {
        if favorite {
            if !onlineItems.contains(where: { $0.url == item.url }) {
                onlineItems.insert(item, at: 0)
            }
        } else {
            onlineItems.removeAll { $0.url == item.url }
        }
        save()
    }

    func removeHistory(_ item: VideoItem) {
        historyItems.removeAll { $0.id == item.id }
        save()
    }

    func clearHistory() {
        historyItems.removeAll()
        save()
    }

    // MARK: - 观看进度

    func updateProgress(url: URL, seconds: Double, duration: Double) {
        func apply(_ index: Int, in array: inout [VideoItem]) {
            array[index].progress = seconds
            if duration > 0 { array[index].duration = duration }
            array[index].lastPlayed = Date()
        }
        if let i = items.firstIndex(where: { $0.url == url }) {
            apply(i, in: &items)
            progressDirty = true
        } else if let i = onlineItems.firstIndex(where: { $0.url == url }) {
            apply(i, in: &onlineItems)
            progressDirty = true
        }

        // 记入播放历史（独立于收藏，删除收藏不影响历史）
        if let i = historyItems.firstIndex(where: { $0.url == url }) {
            apply(i, in: &historyItems)
        } else if let source = items.first(where: { $0.url == url }) ?? onlineItems.first(where: { $0.url == url }) {
            var entry = source
            entry.progress = seconds
            if duration > 0 { entry.duration = duration }
            entry.lastPlayed = Date()
            historyItems.insert(entry, at: 0)
        } else {
            // 独立播放（未收藏、未入库）：也记入历史
            let entry = VideoItem(url: url, isOnline: !url.isFileURL, addedAt: Date(),
                                  duration: duration > 0 ? duration : 0,
                                  progress: seconds, lastPlayed: Date())
            historyItems.insert(entry, at: 0)
        }
        progressDirty = true

        // 播放记录封顶 200 条，避免 library.json 无限膨胀
        if historyItems.count > 200 {
            historyItems.removeLast(historyItems.count - 200)
        }
    }

    func flush() {
        if progressDirty { save() }
    }

    // MARK: - 目录浏览

    /// 某个目录下的直属视频（不含子目录），按名称自然排序（集数 1,2,…10 正确排列）
    func directItems(inDirectory path: String) -> [VideoItem] {
        items
            .filter { $0.url.deletingLastPathComponent().path == path }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// 某个目录下的直属子目录（由视频所在路径推导），自然排序
    func subdirectories(inDirectory path: String) -> [String] {
        var dirs = Set<String>()
        for item in items {
            let parent = item.url.deletingLastPathComponent().path
            if parent.hasPrefix(path + "/") {
                let rest = parent.dropFirst(path.count + 1)
                if let first = rest.split(separator: "/").first {
                    dirs.insert(path + "/" + first)
                }
            }
        }
        return dirs.sorted {
            ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    /// 某个目录（含所有子目录）下的视频总数
    func totalItemCount(inDirectory path: String) -> Int {
        items.filter { $0.url.path.hasPrefix(path + "/") }.count
    }

    // MARK: - 视图数据

    var continueWatching: [VideoItem] {
        (items + onlineItems)
            .filter { $0.progress > 30 && !$0.isFinished }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    var recentlyAdded: [VideoItem] {
        items.sorted { $0.addedAt > $1.addedAt }.prefix(24).map { $0 }
    }
}
