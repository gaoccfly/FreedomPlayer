import SwiftUI
import UniformTypeIdentifiers

@main
struct FreedomPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var player = PlayerController()

    var body: some Scene {
        Window("FreedomPlayer", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(player)
                .frame(minWidth: 1080, minHeight: 700)
                .background(Theme.bg.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开视频文件…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.movie, .video, .mpeg4Movie]
                    if panel.runModal() == .OK {
                        for url in panel.urls {
                            NotificationCenter.default.post(name: .freedomPlayerOpenFile, object: url)
                        }
                    }
                }
                .keyboardShortcut("o")

                Button("打开文件夹…") {
                    NotificationCenter.default.post(name: .freedomPlayerAddFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    // 支持从 Finder 双击视频文件打开
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .freedomPlayerOpenFile, object: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Notification.Name {
    static let freedomPlayerOpenFile = Notification.Name("freedomPlayerOpenFile")
    static let freedomPlayerAddFolder = Notification.Name("freedomPlayerAddFolder")
}
