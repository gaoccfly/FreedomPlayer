import AVFoundation
import SwiftUI

// MARK: - AVPlayerLayer 承载视图

struct VideoPlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    final class HostView: NSView {
        let playerLayer = AVPlayerLayer()

        init(player: AVPlayer) {
            super.init(frame: .zero)
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            wantsLayer = true
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> HostView {
        HostView(player: player)
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

// MARK: - 播放界面

struct PlayerScreen: View {
    @EnvironmentObject private var player: PlayerController
    @Binding var sidebarVisible: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayerLayer(player: player.player).ignoresSafeArea()
            if player.isBuffering && player.errorMessage == nil {
                ProgressView().scaleEffect(1.3).tint(.white)
            }
            CueOverlay()
            ControlsOverlay(sidebarVisible: $sidebarVisible)
            OSDOverlay()
            if let message = player.errorMessage {
                PlaybackErrorOverlay(message: message)
            }
        }
        .background(Button("") { player.togglePlay() }.keyboardShortcut(.space, modifiers: []).opacity(0))
        .background(Button("") { player.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: []).opacity(0))
        .background(Button("") { player.skip(10) }.keyboardShortcut(.rightArrow, modifiers: []).opacity(0))
        .background(Button("") {
            // 全屏时 Esc 先退全屏，非全屏才返回列表
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                player.toggleFullscreen()
            } else {
                player.close()
            }
        }.keyboardShortcut(.escape, modifiers: []).opacity(0))
        .onAppear { player.bumpInteraction() }
    }
}

// MARK: - 播放错误浮层

private struct PlaybackErrorOverlay: View {
    let message: String
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(Theme.accent)
                Text("无法播放")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.callout)
                    .foregroundColor(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                Button("返回") { player.close() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - 操作反馈 OSD

private struct OSDOverlay: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Group {
            if let message = player.osdMessage {
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .animation(.easeInOut(duration: 0.15), value: player.osdMessage)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 外挂字幕渲染

private struct CueOverlay: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        VStack {
            Spacer()
            if let cue = player.currentCue {
                Text(cue.text)
                    .font(.system(size: 22, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, player.showControls ? 150 : 70)
                    .animation(.easeInOut(duration: 0.15), value: player.showControls)
                    .transition(.opacity)
                    .id(cue)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.currentCue)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 控制条

private struct ControlsOverlay: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: LibraryStore
    @Binding var sidebarVisible: Bool

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.toggleFullscreen() }
                .onTapGesture { player.togglePlay() }
                .onContinuousHover { _ in player.bumpInteraction() }

            if player.showControls {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: player.showControls)
    }

    private var title: String {
        player.currentItem?.displayName ?? ""
    }

    // 顶部：返回 + 标题 + 列表开关
    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                player.close()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("返回 (Esc)")

            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(sidebarVisible ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("显示/隐藏侧边栏")

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    // 底部：进度条 + 按钮
    private var bottomBar: some View {
        VStack(spacing: 14) {
            SeekSlider()
                .padding(.horizontal, 24)

            HStack(spacing: 0) {
                timeLabels
                Spacer()
                controlButtons
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 20)
        .padding(.top, 50)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var timeLabels: some View {
        HStack(spacing: 6) {
            Text(timeString(player.currentTime)).foregroundColor(.white)
            Text("/").foregroundColor(.white.opacity(0.4))
            Text(timeString(player.duration)).foregroundColor(.white.opacity(0.6))
        }
        .font(.system(size: 13).monospacedDigit())
    }

    private var controlButtons: some View {
        HStack(spacing: 22) {
            Button {
                player.skip(-10)
            } label: { Image(systemName: "gobackward.10").controlIcon() }
                .buttonStyle(.plain).help("后退 10 秒 (←)")

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .help("播放/暂停 (空格)")

            Button {
                player.skip(10)
            } label: { Image(systemName: "goforward.10").controlIcon() }
                .buttonStyle(.plain).help("前进 10 秒 (→)")

            volumeControl

            speedMenu

            audioMenu

            subtitleMenu

            // 收藏当前网络视频（点星标才会进收藏链接，播放本身不自动收藏）
            if let current = player.currentItem, current.isOnline {
                Button {
                    store.setFavorite(current, !store.isFavorite(url: current.url))
                } label: {
                    Image(systemName: store.isFavorite(url: current.url) ? "star.fill" : "star")
                        .controlIcon()
                        .foregroundColor(store.isFavorite(url: current.url) ? Theme.accent : .white)
                }
                .buttonStyle(.plain)
                .help(store.isFavorite(url: current.url) ? "取消收藏" : "收藏到「收藏链接」")
            }

            Button {
                player.toggleFullscreen()
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").controlIcon() }
                .buttonStyle(.plain)
                .help("全屏 (⌃⌘F)")
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : (player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"))
                .controlIcon()
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                .frame(width: 90)
                .tint(.white)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { s in
                Button {
                    player.setSpeed(Float(s))
                } label: {
                    if Float(s) == player.speed {
                        Label(speedLabel(s), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(s))
                    }
                }
            }
        } label: {
            Text(player.speed == 1 ? "倍速" : String(format: "%.2gx", player.speed))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度")
    }

    private func speedLabel(_ s: Double) -> String {
        s == 1 ? "正常速度" : String(format: "%.2gx", s)
    }

    private var audioMenu: some View {
        Menu {
            if player.audioTrackNames.isEmpty {
                Text("仅一条音轨").foregroundColor(Theme.textDim)
            } else {
                ForEach(Array(player.audioTrackNames.enumerated()), id: \.offset) { index, name in
                    Button {
                        player.selectAudioTrack(index: index)
                    } label: {
                        if player.selectedAudioTrack == index {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .controlIcon()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("音轨")
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                player.selectSubtitle(index: nil)
            } label: {
                if player.selectedSubtitle == nil && !player.hasExternalSubtitle {
                    Label("关闭字幕", systemImage: "checkmark")
                } else {
                    Text("关闭字幕")
                }
            }

            ForEach(Array(player.subtitleNames.enumerated()), id: \.offset) { index, name in
                Button {
                    player.selectSubtitle(index: index)
                } label: {
                    if player.selectedSubtitle == index {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }

            Divider()
            Button {
                player.pickExternalSubtitle()
            } label: {
                Label("加载外挂字幕…", systemImage: "doc.badge.plus")
            }
            if player.hasExternalSubtitle {
                Text("已加载外挂字幕").foregroundColor(Theme.textDim)
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .controlIcon()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕")
    }
}

private extension Image {
    func controlIcon() -> some View {
        font(.system(size: 17, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
    }
}

// MARK: - 进度条

private struct SeekSlider: View {
    @EnvironmentObject private var player: PlayerController
    @State private var dragging = false
    @State private var dragValue: Double = 0

    /// 拖动中显示拖动位置；seek 缓冲未完成前停在目标位置，完成后跟随真实时间
    private var value: Double { dragging ? dragValue : (player.seekTarget ?? player.currentTime) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = player.duration > 0 ? min(max(value / player.duration, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 5)
                Capsule().fill(Theme.accent).frame(width: max(0, width * fraction), height: 5)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .frame(width: dragging ? 15 : 0, height: dragging ? 15 : 0)
                    .offset(x: max(0, width * fraction) - 7.5)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        dragValue = min(max(Double(g.location.x / width), 0), 1) * player.duration
                        player.bumpInteraction()
                    }
                    .onEnded { _ in
                        player.seek(to: dragValue)
                        dragging = false
                    }
            )
            .onHover { _ in player.bumpInteraction() }
        }
        .frame(height: 22)
    }
}
