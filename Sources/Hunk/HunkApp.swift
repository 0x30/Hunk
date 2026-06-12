import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPM 可执行程序没有 app bundle，需要手动升级为常规前台应用
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct HunkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = RepoViewModel()
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .environmentObject(settings)
                .id(settings.language)  // 切换语言时整树重建
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(tr("打开仓库…", "Open Repository…")) {
                    vm.openRepoPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button(tr("保存", "Save")) {
                    Task { await vm.saveEditor() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!vm.editorDirty)

                Button(tr("关闭标签页", "Close Tab")) {
                    vm.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(tr("文件", "Files")) {
                    vm.sidebarTab = .files
                }
                .keyboardShortcut("1", modifiers: .command)

                Button(tr("源代码管理", "Source Control")) {
                    vm.sidebarTab = .changes
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button(tr("下一个标签页", "Next Tab")) {
                    vm.activateNeighborTab(offset: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button(tr("上一个标签页", "Previous Tab")) {
                    vm.activateNeighborTab(offset: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                Button(tr("刷新", "Refresh")) {
                    Task { await vm.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(tr("提交", "Commit")) {
                    vm.commit()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(vm)
                .environmentObject(settings)
                .id(settings.language)
        }
    }
}
