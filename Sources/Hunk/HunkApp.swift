import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPM 可执行程序没有 app bundle，需要手动升级为常规前台应用
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 立即加载持久化的颜色/图标主题（ThemeStore 是惰性单例，
        // 不主动触碰的话要等首次打开编辑器才会应用全局外观）
        _ = ThemeStore.shared
        _ = IconThemeStore.shared
    }

    /// `hunk` 命令行 / 访达「打开方式」送来的路径
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        CLIOpenRouter.deliver(url.path)
    }

    /// 所有窗口都关闭后自动退出应用
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// 命令行打开请求的路由：冷启动暂存，热运行广播；窗口原子领取防止多窗重复处理。
enum CLIOpenRouter {
    static let notification = Notification.Name("hunk.cli.open")
    private static var pendingPath: String?
    private static let lock = NSLock()

    static func deliver(_ path: String) {
        lock.lock()
        pendingPath = path
        lock.unlock()
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func takePending() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let path = pendingPath
        pendingPath = nil
        return path
    }
}

@main
struct HunkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        // 每个窗口一个独立仓库（拖入文件夹可选择「在新窗口打开」）
        WindowGroup(for: String.self) { $repoPath in
            WindowRoot(initialPath: repoPath)
                .environmentObject(settings)
                .id(settings.language)  // 切换语言时整树重建
        }
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .id(settings.language)
        }
    }
}

/// 窗口根：每个窗口持有自己的 RepoViewModel。
private struct WindowRoot: View {
    @StateObject private var vm: RepoViewModel

    init(initialPath: String?) {
        let path = (initialPath?.isEmpty ?? true) ? nil : initialPath
        _vm = StateObject(wrappedValue: RepoViewModel(initialPath: path))
    }

    var body: some View {
        ContentView()
            .environmentObject(vm)
            .frame(minWidth: 900, minHeight: 560)
            .focusedSceneObject(vm)
    }
}

/// 菜单命令：作用于当前聚焦窗口的视图模型。
private struct AppCommands: Commands {
    @FocusedObject private var vm: RepoViewModel?
    // 观察语言设置：切换语言后自定义菜单项即时换文案
    @ObservedObject private var settings = SettingsStore.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(tr("检查更新…", "Check for Updates…")) {
                Task { await UpdateChecker.shared.check(userInitiated: true) }
            }
            Button(tr("安装 hunk 命令行工具…", "Install 'hunk' Command…")) {
                vm?.notice = CLIInstaller.install()
            }
            .disabled(vm == nil)
        }
        CommandGroup(replacing: .newItem) {
            // 终端聚焦时 ⌘N/⌘W 切换为终端语义（VS Code 式）
            Button(vm?.terminalFocused == true ? tr("新建终端", "New Terminal") : tr("新建文件", "New File")) {
                if let vm, vm.terminalFocused {
                    vm.newTerminal()
                } else {
                    vm?.newUntitledFile()
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(vm?.repoRoot == nil)

            Button(tr("打开仓库…", "Open Repository…")) {
                vm?.openRepoPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(vm == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(tr("保存", "Save")) {
                if let vm { Task { await vm.saveEditor() } }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(vm?.editorDirty != true)

            Button(vm?.terminalFocused == true ? tr("关闭终端", "Kill Terminal") : tr("关闭标签页", "Close Tab")) {
                if let vm {
                    if vm.terminalFocused {
                        vm.closeActiveTerminal()
                    } else {
                        vm.closeActiveTab()
                    }
                } else {
                    // 设置等无 vm 的窗口：⌘W 直接关窗
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .printItem) {
            Button(tr("快速打开…", "Quick Open…")) {
                vm?.showQuickOpen = true
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(vm == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(tr("全局搜索…", "Search in Repository…")) {
                vm?.showGlobalSearch = true
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(vm?.repoRoot == nil)

            Button(tr("查找", "Find")) {
                // 触发编辑器的查找条（NSTextView usesFindBar）
                let item = NSMenuItem()
                item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button(tr("文件", "Files")) {
                vm?.toggleSidebarTab(.files)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(vm == nil)

            Button(tr("源代码管理", "Source Control")) {
                vm?.toggleSidebarTab(.changes)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(vm == nil)

            Button(tr("终端", "Terminal")) {
                vm?.toggleTerminal()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(vm?.repoRoot == nil)

            Divider()

            Button(tr("下一个标签页", "Next Tab")) {
                vm?.activateNeighborTab(offset: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(vm == nil)

            Button(tr("上一个标签页", "Previous Tab")) {
                vm?.activateNeighborTab(offset: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(vm == nil)

            Divider()

            Button(tr("刷新", "Refresh")) {
                if let vm { Task { await vm.refresh() } }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(vm == nil)

            Button(tr("提交", "Commit")) {
                vm?.commit()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(vm == nil)
        }
    }
}
