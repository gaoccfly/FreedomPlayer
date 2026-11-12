import SwiftUI

struct SettingsView: View {
    @AppStorage("autoPlayNext") private var autoPlayNext = true
    @AppStorage("resumePlayback") private var resumePlayback = true
    @AppStorage("subtitleFontSize") private var subtitleFontSize = 22.0
    @State private var cacheCleared = false

    var body: some View {
        Form {
            Section("播放") {
                Toggle("自动连播下一个视频", isOn: $autoPlayNext)
                Toggle("记忆播放进度", isOn: $resumePlayback)
            }

            Section("字幕") {
                HStack {
                    Text("字幕字号")
                    Slider(value: $subtitleFontSize, in: 14...36, step: 1)
                    Text("\(Int(subtitleFontSize)) pt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text("示例：外挂字幕会以该字号显示")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("缓存") {
                HStack {
                    Button("清理缩略图缓存") {
                        Task {
                            await ThumbnailLoader.shared.clearCache()
                            cacheCleared = true
                        }
                    }
                    if cacheCleared {
                        Text("已清理")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text("删除已生成的视频缩略图，下次浏览时重新生成")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
