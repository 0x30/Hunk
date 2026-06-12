import SwiftUI
import AppKit
import notify

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cliNotifyToken: Int32 = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPM 可执行程序没有 app bundle，需要手动升级为常规前台应用
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 立即加载持久化的颜色/图标主题（ThemeStore 是惰性单例，
        // 不主动触碰的话要等首次打开编辑器才会应用全局外观）
        _ = ThemeStore.shared
        _ = IconThemeStore.shared

        // 预热 LaunchServices：进程内首次 LS 查询会触发整库初始化，期间系统把
        // 数据库经 XPC 整份拷贝（本机约 200MB），多线程首查还会竞态各拷一份，
        // 内存瞬时冲到 400MB+。启动时在单一后台线程先查一次，之后打开文件
        // 走已建好的只读映射，不再出现尖峰。
        DispatchQueue.global(qos: .utility).async {
            // 必须是真正命中数据库的查询，太轻的（缓存内）触发不了初始化
            _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        }

        // hunk 命令行的轻量通道：应用在运行时脚本走 darwin 通知送路径，
        // 绕开系统 odoc 打开事件（每次都会触发 LaunchServices 整库拷贝的内存尖峰）
        notify_register_dispatch(CLIOpenRouter.notifyName, &cliNotifyToken, .main) { _ in
            Task { @MainActor in CLIOpenRouter.consumeChannelFile() }
        }
    }

    /// `hunk` 命令行 / 访达「打开方式」送来的路径
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in CLIOpenRouter.route(url.path) }
    }

    /// 所有窗口都关闭后自动退出应用
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// 命令行打开请求的路由（VS Code 式）：
/// 已有窗口开着该仓库 → 聚焦它；有空白窗口 → 就地打开；否则开新窗口。
/// 冷启动时窗口还不存在，路径暂存，由首个窗口的 .task 补领。
@MainActor
enum CLIOpenRouter {
    /// 冷启动暂存的路径
    private static var pendingPath: String?
    /// 等新窗口仓库打开后要定位的文件
    private static var pendingReveal: String?

    static func route(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        // 解析符号链接（如 /tmp → /private/tmp），与 git 返回的仓库根对齐
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let file = isDirectory.boolValue ? nil : url.path

        let vms = RepoViewModel.instances.allObjects
        guard !vms.isEmpty else {
            pendingPath = path
            return
        }

        // 1. 某个窗口已打开该仓库（目标在其根目录内）→ 聚焦并定位
        // 仓库根也走同样的符号链接归一化（git 返回 /private/tmp，URL 解析出 /tmp）
        func canonicalRoot(_ vm: RepoViewModel) -> String? {
            vm.repoRoot?.resolvingSymlinksInPath().path
        }
        if let vm = vms.first(where: { vm in
            guard let root = canonicalRoot(vm) else { return false }
            return directory.path == root || directory.path.hasPrefix(root + "/")
        }) {
            vm.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let file, let root = canonicalRoot(vm), file.hasPrefix(root + "/") {
                vm.revealInFiles(String(file.dropFirst(root.count + 1)))
            }
            return
        }

        // 2. 有空白窗口（欢迎页）→ 就地打开
        if let vm = vms.first(where: { $0.repoRoot == nil }) {
            vm.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            vm.openFromCLI(path)
            return
        }

        // 3. 都被占用 → 开新窗口（绝不替换现有窗口的仓库）
        pendingReveal = file
        let requester = vms.first { $0.window?.isKeyWindow == true } ?? vms[0]
        requester.openWindowRequest = directory.path
    }

    static func takePending() -> String? {
        defer { pendingPath = nil }
        return pendingPath
    }

    static func takePendingReveal() -> String? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    // MARK: 轻量通道（应用运行中时 hunk 脚本直接送路径，绕开 odoc 事件）

    /// darwin 通知名，与安装的 hunk 脚本约定一致
    nonisolated static let notifyName = "app.hunk.cli.open"

    /// 路径中转文件：脚本写入，应用读取后删除
    nonisolated static var channelFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hunk/cli-open")
    }

    static func consumeChannelFile() {
        guard let raw = try? String(contentsOf: channelFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: channelFile)
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        route(path)
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
        // 打开事件统一走 AppDelegate 路由，禁止 SwiftUI 自己再造窗口
        .handlesExternalEvents(matching: [])
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
            // 记录所在 NSWindow，供命令行路由聚焦窗口
            .background(WindowAccessor { vm.window = $0 })
    }
}

/// 捕获视图所在的 NSWindow。
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
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
