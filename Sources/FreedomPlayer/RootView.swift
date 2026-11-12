import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var section: LibrarySection = .home
    @State private var showAddURL = false
    @State private var sidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            // 固定侧栏：始终与内容并排，绝不悬浮遮挡播放画面
            ZStack(alignment: .leading) {
                Sidebar(section: $section, showAddURL: $showAddURL)
                    .frame(width: 250)
                    .offset(x: sidebarVisible ? 0 : -250)
            }
            .frame(width: sidebarVisible ? 250 : 0, alignment: .leading)
            .clipped()

            if sidebarVisible {
                Divider().overlay(Color.black.opacity(0.6))
            }

            DetailView(section: $section, showAddURL: $showAddURL, sidebarVisible: $sidebarVisible)
        }
        .animation(.easeInOut(duration: 0.3), value: sidebarVisible)
        .onChange(of: player.currentItem) { item in
            if item == nil { sidebarVisible = true }
        }
        .onAppear {
            player.store = store
            if store.folders.isEmpty { Task { await store.rescan() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .freedomPlayerOpenFile)) { note in
            if let url = note.object as? URL, !url.hasDirectoryPath {
                // 直接播放，不自动收藏
                player.play(VideoItem(url: url, isOnline: !url.isFileURL, addedAt: Date(),
                                      duration: 0, progress: 0, lastPlayed: nil))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .freedomPlayerAddFolder)) { _ in
            store.addFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // 退出前把最后一段进度写盘（Periodic observer 最长 5 秒间隔）
            player.close()
        }
        .sheet(isPresented: $showAddURL) { AddURLSheet() }
    }
}

// MARK: - 侧边栏

private struct Sidebar: View {
    @Binding var section: LibrarySection
    @Binding var showAddURL: Bool
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var linksExpanded = true
    @State private var historyExpanded = true

    var body: some View {
        List(selection: $section) {
            Label("首页", systemImage: "house.fill")
                .tag(LibrarySection.home)

            Section {
                Label("全部视频", systemImage: "square.grid.2x2.fill")
                    .tag(LibrarySection.all)
                if store.folders.isEmpty {
                    Text("还没有文件夹")
                        .font(.callout)
                        .foregroundColor(Theme.textDim)
                } else {
                    ForEach(store.folders, id: \.self) { folder in
                        FolderTreeRow(path: folder.path)
                            .contextMenu {
                                Button("从媒体库移除", role: .destructive) { store.removeFolder(folder) }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("媒体库")
                    Spacer()
                    Button {
                        Task { await store.rescan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textDim)
                    .help(store.isScanning ? "扫描中…" : "重新扫描")
                }
            }

            Section("在线") {
                // 标题行：点三角只折叠/展开（不触发选中跳页），点标题才进列表页
                // 子项是独立的 List 行（不带 tag），点击子项只播放、不会整块选中变蓝
                OnlineSectionRow(title: "收藏链接", systemImage: "star.fill",
                                 expanded: $linksExpanded,
                                 itemCount: store.onlineItems.count)
                    .tag(LibrarySection.onlineLinks)
                if linksExpanded {
                    if store.onlineItems.isEmpty {
                        Text("暂无收藏")
                            .font(.callout)
                            .foregroundColor(Theme.textDim)
                            .padding(.leading, 24)
                    } else {
                        ForEach(store.onlineItems) { item in
                            VideoTreeRow(item: item)
                                .contextMenu {
                                    Button("从收藏中移除", role: .destructive) { store.removeOnline(item) }
                                }
                        }
                    }
                }

                OnlineSectionRow(title: "播放记录", systemImage: "clock.arrow.circlepath",
                                 expanded: $historyExpanded,
                                 itemCount: store.historyItems.count,
                                 clearHistoryAction: { store.clearHistory() })
                    .tag(LibrarySection.onlineHistory)
                if historyExpanded {
                    if store.historyItems.isEmpty {
                        Text("暂无记录")
                            .font(.callout)
                            .foregroundColor(Theme.textDim)
                            .padding(.leading, 24)
                    } else {
                        ForEach(store.historyItems) { item in
                            VideoTreeRow(item: item)
                                .contextMenu {
                                    Button("删除记录", role: .destructive) { store.removeHistory(item) }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    showAddURL = true
                } label: {
                    Label("播放网络视频", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    store.addFolder()
                } label: {
                    Label("添加本地文件夹", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
        }
    }
}

// MARK: - 侧边栏在线栏目行（可展开，展开/收起不触发跳页）

private struct OnlineSectionRow: View {
    let title: String
    let systemImage: String
    @Binding var expanded: Bool
    let itemCount: Int
    var clearHistoryAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundColor(Theme.textDim)
            }
            .buttonStyle(.plain)

            Label(title, systemImage: systemImage)
                .contextMenu {
                    if let clearHistoryAction {
                        Button("清空播放记录", role: .destructive) { clearHistoryAction() }
                    }
                }

            Spacer()

            if itemCount > 0 {
                Text("\(itemCount)")
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - 侧边栏文件夹树（可展开）

private struct FolderTreeRow: View {
    let path: String
    @State private var expanded = false
    @EnvironmentObject private var store: LibraryStore

    private var subdirs: [String] { store.subdirectories(inDirectory: path) }
    private var videos: [VideoItem] { store.directItems(inDirectory: path) }
    private var hasChildren: Bool { !subdirs.isEmpty || !videos.isEmpty }

    var body: some View {
        if hasChildren {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(subdirs, id: \.self) { dir in
                    FolderTreeRow(path: dir)
                }
                ForEach(videos) { item in
                    VideoTreeRow(item: item)
                }
            } label: {
                Label((path as NSString).lastPathComponent, systemImage: "folder.fill")
                    .contextMenu {
                        Button("在文件夹中显示", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
            }
        } else {
            Label((path as NSString).lastPathComponent, systemImage: "folder")
        }
    }
}

// MARK: - 侧边栏视频叶子节点

private struct VideoTreeRow: View {
    let item: VideoItem
    @EnvironmentObject private var player: PlayerController

    private var isPlaying: Bool { player.currentItem?.url == item.url }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.isOnline ? "antenna.radiowaves.left.and.right" : "film")
                .font(.system(size: 10))
                .foregroundColor(isPlaying ? Theme.accent : Theme.textDim)
            Text(item.displayName)
                .font(.system(size: 12.5))
                .foregroundColor(isPlaying ? Theme.accent : .primary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { player.play(item) }
    }
}

// MARK: - 主内容区

private struct DetailView: View {
    @Binding var section: LibrarySection
    @Binding var showAddURL: Bool
    @Binding var sidebarVisible: Bool
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Group {
            if player.currentItem != nil {
                // 播放时内容区就是播放器，文件夹树在侧边栏展开选择
                PlayerScreen(sidebarVisible: $sidebarVisible)
            } else {
                switch section {
                case .home: HomeView(showAddURL: $showAddURL)
                case .all: VideoListView(title: "全部视频", items: store.items, searchable: true)
                case .onlineLinks:
                    VideoListView(title: "收藏链接", items: store.onlineItems,
                                  emptyText: "还没有保存网络链接，点侧边栏下方「添加网络链接」试试",
                                  onDelete: { store.removeOnline($0) })
                case .onlineHistory:
                    VideoListView(title: "播放记录", items: store.historyItems,
                                  sortMode: .lastPlayed,
                                  emptyText: "还没有播放记录",
                                  onDelete: { store.removeHistory($0) })
                case .directory(nil):
                    RootDirectoryView(section: $section)
                case .directory(.some(let path)):
                    DirectoryView(section: $section, path: path)
                }
            }
        }
        .background(Theme.bg)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return true
        }
    }

    private func handleDrop(_ urls: [URL]) {
        for url in urls {
            if url.hasDirectoryPath {
                store.addFolder(url)
                Task { await store.rescan() }
            } else {
                // 直接播放，不自动收藏
                player.play(VideoItem(url: url, isOnline: !url.isFileURL, addedAt: Date(),
                                      duration: 0, progress: 0, lastPlayed: nil))
            }
        }
    }
}

// MARK: - 紧凑文件名列表

struct VideoListView: View {
    enum SortMode {
        case name, lastPlayed
    }

    let title: String
    let items: [VideoItem]
    var sortMode: SortMode = .name
    var emptyText = "暂无视频"
    var searchable = false
    var onDelete: ((VideoItem) -> Void)? = nil

    @State private var searchText = ""

    private var sortedItems: [VideoItem] {
        switch sortMode {
        case .name:
            // 按名称自然排序（数字按数值比较：1, 2, …, 10）
            items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .lastPlayed:
            items.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
    }

    private var visibleItems: [VideoItem] {
        let base = sortedItems
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                HStack {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white)
                    if searchable && !items.isEmpty {
                        searchField
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)
            }
            if visibleItems.isEmpty {
                Text(searchText.isEmpty ? emptyText : "没有匹配「\(searchText)」的视频")
                    .foregroundColor(Theme.textDim)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleItems) { item in
                            VideoRow(item: item)
                                .contextMenu {
                                    if let onDelete {
                                        Button("删除", role: .destructive) { onDelete(item) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Theme.textDim)
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        .frame(maxWidth: 240)
    }
}

// MARK: - 单行视频

struct VideoRow: View {
    let item: VideoItem
    @EnvironmentObject private var player: PlayerController
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isOnline ? "antenna.radiowaves.left.and.right" : "film")
                .font(.system(size: 12))
                .foregroundColor(Theme.textDim)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if item.percent > 0.005 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(Theme.accent)
                                .frame(width: geo.size.width * item.percent)
                        }
                    }
                    .frame(height: 3)
                }
            }

            Spacer(minLength: 8)

            if item.duration > 0 {
                Text(timeString(item.duration))
                    .font(.caption)
                    .foregroundColor(Theme.textDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Group {
                if player.currentItem?.url == item.url {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.16))
                } else if hover {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { player.play(item) }
    }
}

// MARK: - 单行文件夹

struct FolderRow: View {
    let path: String
    let count: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundColor(Theme.accent)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption)
                .foregroundColor(Theme.textDim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hover ? Color.white.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: - 媒体库根目录（已添加的文件夹列表）

private struct RootDirectoryView: View {
    @Binding var section: LibrarySection
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("文件夹")
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)
            if store.folders.isEmpty {
                Text("还没有添加文件夹，点侧边栏下方按钮添加")
                    .foregroundColor(Theme.textDim)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.folders, id: \.self) { folder in
                            FolderRow(path: folder.path, count: store.totalItemCount(inDirectory: folder.path)) {
                                section = .directory(folder.path)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

// MARK: - 子目录浏览（分层展示 + 面包屑）

private struct DirectoryView: View {
    @Binding var section: LibrarySection
    let path: String
    @EnvironmentObject private var store: LibraryStore

    private var subdirs: [String] { store.subdirectories(inDirectory: path) }
    private var videos: [VideoItem] { store.directItems(inDirectory: path) }

    /// 从媒体库根到当前目录的路径链（用于面包屑）
    private var crumbs: [String] {
        guard let root = store.folders.first(where: { path.hasPrefix($0.path + "/") || path == $0.path }) else {
            return [path]
        }
        var chain = [root.path]
        let rest = path.dropFirst(root.path.count + 1)
        for comp in rest.split(separator: "/") {
            chain.append(chain.last! + "/" + comp)
        }
        return chain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)

            if subdirs.isEmpty && videos.isEmpty {
                Text("此文件夹里没有视频")
                    .foregroundColor(Theme.textDim)
                    .padding(24)
            } else {
                ScrollView {
                    // 子文件夹用文字列表
                    if !subdirs.isEmpty {
                        LazyVStack(spacing: 2) {
                            ForEach(subdirs, id: \.self) { dir in
                                FolderRow(path: dir, count: store.totalItemCount(inDirectory: dir)) {
                                    section = .directory(dir)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                    }
                    // 最后一层的视频用海报墙
                    if !videos.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 22) {
                            ForEach(videos) { PosterCell(item: $0) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textDim)
                }
                let isCurrent = index == crumbs.count - 1
                Button {
                    section = .directory(crumb)
                } label: {
                    Text(index == 0 ? store.folders.first { $0.path == crumb }?.lastPathComponent ?? "根目录" : (crumb as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? .white : Theme.textDim)
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
            }
        }
    }
}

// MARK: - 首页

private struct HomeView: View {
    @Binding var showAddURL: Bool
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if !store.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("继续观看").font(.title2.weight(.semibold)).foregroundColor(.white)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(store.continueWatching) { item in
                                    ContinueCard(item: item)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("最近添加").font(.title2.weight(.semibold)).foregroundColor(.white)
                    VideoGrid(title: "", items: store.recentlyAdded, isEmbedded: true)
                }

                if store.items.isEmpty && store.onlineItems.isEmpty && !store.isScanning {
                    EmptyState(showAddURL: $showAddURL)
                        .padding(.top, 60)
                }
            }
            .padding(28)
        }
    }
}

// MARK: - 空状态

private struct EmptyState: View {
    @Binding var showAddURL: Bool
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [Theme.accent, Color(hex: 0xE6394B)], startPoint: .top, endPoint: .bottom))
            Text("欢迎来到 FreedomPlayer").font(.title.weight(.semibold)).foregroundColor(.white)
            Text("添加一个文件夹，或粘贴一个视频链接开始观看")
                .foregroundColor(Theme.textDim)

            HStack(spacing: 14) {
                Button {
                    store.addFolder()
                } label: {
                    Label("选择文件夹", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    showAddURL = true
                } label: {
                    Label("网络链接", systemImage: "link")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 网络链接弹窗

struct AddURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var text = ""
    @State private var name = ""

    /// 去掉首尾空白并自动补全 https:// 前缀；无效输入返回 nil
    private var normalizedURL: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://" + trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("播放网络视频").font(.title3.weight(.semibold)).foregroundColor(.white)
            Text("支持 MP4 直链、HLS（m3u8）；播放时可点 ☆ 按钮收藏到「收藏链接」")
                .font(.callout).foregroundColor(Theme.textDim)
            TextField("https://example.com/video.m3u8", text: $text)
                .textFieldStyle(.roundedBorder)
            TextField("视频名称（可选，不填则显示文件名）", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("播放") {
                    if let url = normalizedURL {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let item = VideoItem(url: url, isOnline: true, addedAt: Date(), duration: 0,
                                             progress: 0, lastPlayed: nil,
                                             customName: trimmed.isEmpty ? nil : trimmed)
                        player.play(item)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(normalizedURL == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.panel)
    }
}

// MARK: - 海报网格

struct VideoGrid: View {
    let title: String
    let items: [VideoItem]
    var emptyIcon = "film.stack"
    var isEmbedded = false

    var body: some View {
        let content = ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 20)], spacing: 26) {
                ForEach(items) { item in
                    PosterCell(item: item)
                }
            }
            .padding(28)
        }

        if isEmbedded {
            content.padding(.horizontal, -28).padding(.top, -28)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !title.isEmpty {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                }
                content
            }
        }
    }
}

// MARK: - 单个海报卡片

struct PosterCell: View {
    let item: VideoItem
    @EnvironmentObject private var player: PlayerController
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbView(url: item.url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if item.percent > 0.005 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3)).frame(height: 4).blur(radius: 0.5)
                                Capsule().fill(Theme.accent)
                                    .frame(width: geo.size.width * item.percent, height: 4)
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(height: 12)
                    }
                }
                .overlay {
                    if hover {
                        RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                }
                .onHover { hover = $0 }
                .onTapGesture { player.play(item) }
                .shadow(color: .black.opacity(hover ? 0.5 : 0.25), radius: hover ? 14 : 6, y: 5)
                .scaleEffect(hover ? 1.025 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hover)

            Text(item.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(item.percent > 0.005
                 ? (item.isFinished ? "已看完" : "已看 \(Int(item.percent * 100))%")
                 : (item.duration > 0 ? timeString(item.duration) : "在线视频"))
                .font(.caption)
                .foregroundColor(Theme.textDim)
        }
    }
}

// MARK: - 继续观看卡片

struct ContinueCard: View {
    let item: VideoItem
    @EnvironmentObject private var player: PlayerController
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbView(url: item.url)
                .frame(width: 300, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(12)
                        .opacity(hover ? 1 : 0.75)
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                            Capsule().fill(Theme.accent)
                                .frame(width: geo.size.width * item.percent, height: 4)
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
                .onHover { hover = $0 }
                .onTapGesture { player.play(item) }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .scaleEffect(hover ? 1.02 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hover)

            Text(item.displayName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text("剩余 \(timeString(max(0, item.duration - item.progress)))")
                .font(.caption)
                .foregroundColor(Theme.textDim)
        }
        .frame(width: 300)
    }
}

// MARK: - 缩略图

struct ThumbView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.card)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video.fill")
                    .font(.system(size: 26))
                    .foregroundColor(Theme.textDim.opacity(0.5))
            }
        }
        .clipped()
        .task(id: url) {
            image = await ThumbnailLoader.shared.image(for: url)
        }
    }
}
