import SwiftUI
import AppKit
import notify
import HunkCore

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
        // vnode 监视通道目录：应用已在前台时 `open -a Hunk` 不触发激活，仅靠 didBecomeActive
        // 会漏读（在 Hunk 终端里 `hunk 某目录` 毫无反应即此因）。监视写入即时领取。
        Task { @MainActor in CLIOpenRouter.startWatchingChannel() }

        // 诊断日志（实时落盘，崩溃后可复盘）+ 内存看门狗（异常暴涨时清缓存/主动退出，
        // 避免拖垮整个系统的 OOM 连锁）。日志在 ~/Library/Logs/Hunk/session.log
        Diagnostics.start()
        MemoryGuard.start()
        // HunkCore 够不到 app 层的 tr，启动时注入翻译器，让 git 错误/状态描述跟随语言
        CoreLocale.translate = { zh, en in tr(zh, en) }
        // 确认语法高亮的语言表已从 bundle 加载（0 = 打包漏拷 SPM 资源包，高亮会降级纯文本）
        Diagnostics.log("语言表加载 \(Lexer.loadedExtensionCount) 个扩展名")

        // AppKit 接管「文件 → 最近打开」（两行：项目名 + 灰色路径）。
        // SwiftUI 建好菜单的时机晚于此处，故在窗口出现、应用激活、菜单栏追踪时都确保接管一次（幂等）。
        for name: NSNotification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSApplication.didBecomeActiveNotification,
            NSMenu.didBeginTrackingNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RecentMenuController.shared.install() }
            }
        }
        // hunk 命令行走通道送路径 + 普通激活（open 不带文件）；应用激活时读取通道并路由，
        // 绕开 odoc 冷启动不建窗口的问题。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CLIOpenRouter.consumeChannelFile() }
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

    /// ⌘Q / 退出前：任一窗口有未保存改动就拦下来,弹「全部保存 / 不保存 / 取消」。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let dirty = RepoViewModel.instances.allObjects.filter { $0.hasUnsavedChanges() }
            guard !dirty.isEmpty else { return .terminateNow }

            let alert = NSAlert()
            alert.messageText = tr("有未保存的修改", "You have unsaved changes")
            alert.informativeText = tr("退出前是否保存所有改动?", "Save all changes before quitting?")
            alert.addButton(withTitle: tr("全部保存", "Save All"))
            alert.addButton(withTitle: tr("不保存", "Don't Save"))
            alert.addButton(withTitle: tr("取消", "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:            // 全部保存后再退
                Task { @MainActor in
                    for vm in dirty { await vm.saveAllDirty() }
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            case .alertSecondButtonReturn:           // 不保存,直接退
                return .terminateNow
            default:                                 // 取消
                return .terminateCancel
            }
        }
    }
}

/// 关窗口前查未保存改动的窗口代理：拦 windowShouldClose,其余事件转发给 SwiftUI 原代理。
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var vm: RepoViewModel?
    weak var original: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let vm, vm.hasUnsavedChanges() {
            vm.confirmCloseWindow(sender)   // 异步弹 sheet,先别关
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    // 未实现的 NSWindowDelegate 方法转发给 SwiftUI 原代理,别破坏其窗口管理
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (original?.responds(to: aSelector) ?? false) ? original : super.forwardingTarget(for: aSelector)
    }
}

/// 命令行打开请求的路由（VS Code 式）：
/// 已有窗口开着该仓库 → 聚焦它；有空白窗口 → 就地打开；否则开新窗口。
/// 冷启动时窗口还不存在，路径暂存，由首个窗口的 .task 补领。
@MainActor
enum CLIOpenRouter {
    /// 冷启动暂存的路径
    private static var pendingPath: String?
    /// 冷启动是否带了命令行路径——窗口初始化(非 MainActor 隔离的 @StateObject init)据此避让
    /// restoreLast，避免「恢复上次仓库」抢掉 CLI 文件。必须用 nonisolated 标志，
    /// 不能在 init 里跨 actor 读 @MainActor 状态（assumeIsolated 会崩溃）。
    nonisolated static var hasChannelContent: Bool {
        ((try? String(contentsOf: channelFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    /// 等新窗口仓库打开后要定位的文件
    private static var pendingReveal: String?

    static func route(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        // 解析符号链接（如 /tmp → /private/tmp），与 git 返回的仓库根对齐
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()

        let vms = RepoViewModel.instances.allObjects
        guard !vms.isEmpty else {
            pendingPath = path
            scheduleColdStartRetry(attempt: 0)
            return
        }

        // 仓库根也走符号链接归一化（git 返回 /private/tmp，URL 解析出 /tmp）
        func canonicalRoot(_ vm: RepoViewModel) -> String? {
            vm.repoRoot?.resolvingSymlinksInPath().path
        }
        func focus(_ vm: RepoViewModel) {
            vm.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // 文件夹（VS Code 式）：已打开则聚焦，否则在新窗口打开
        if isDirectory.boolValue {
            if let vm = vms.first(where: { canonicalRoot($0) == directory.path }) {
                focus(vm)
            } else {
                let requester = vms.first { $0.window?.isKeyWindow == true } ?? vms[0]
                requester.openWindowRequest = directory.path
            }
            return
        }

        // 单文件①：落在某个已打开项目内 → 聚焦那个项目窗口并定位到该文件
        let file = url.path
        if let vm = vms.first(where: { vm in
            guard let root = canonicalRoot(vm) else { return false }
            return file.hasPrefix(root + "/")
        }) {
            focus(vm)
            if let root = canonicalRoot(vm) {
                vm.revealInFiles(String(file.dropFirst(root.count + 1)))
            }
            return
        }

        // 单文件②：不在任何打开的项目内 → 在当前窗口打开它
        let target = vms.first { $0.window?.isKeyWindow == true } ?? vms[0]
        focus(target)
        target.openStandaloneFile(url)
    }

    /// 冷启动：odoc 打开事件常早于 SwiftUI 窗口建立，pendingPath 暂存后窗口侧 .task 取不到。
    /// 轮询等窗口就绪（每 0.25s，最多 ~3s），就绪后重走路由消费暂存的路径。
    private static func scheduleColdStartRetry(attempt: Int) {
        guard attempt < 12, pendingPath != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let p = pendingPath else { return }  // 已被窗口的 .task 消费
            if !RepoViewModel.instances.allObjects.isEmpty {
                _ = takePending()
                route(p)
            } else {
                scheduleColdStartRetry(attempt: attempt + 1)
            }
        }
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

    // 监视通道目录：脚本写入 cli-open 立即领取，不依赖应用「激活」事件。
    // 之前只在 didBecomeActive 时消费——应用已在前台（如在 Hunk 自带终端里敲 `hunk 某目录`）
    // 时 `open -a Hunk` 不触发激活，通道永远没人读，表现为「毫无反应」。vnode 监视根治此问题。
    private static var channelWatchFD: Int32 = -1
    private static var channelWatchSource: DispatchSourceFileSystemObject?

    static func startWatchingChannel() {
        let dir = channelFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 消费后会删文件，下次脚本写入即「新建」，目录 .write 事件可靠触发
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        channelWatchFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { CLIOpenRouter.consumeChannelFile() } }
        src.setCancelHandler { Darwin.close(fd) }
        channelWatchSource = src
        src.resume()
        // 启动瞬间脚本可能已写好通道（冷启动竞速），先领一次
        consumeChannelFile()
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

        // 设置窗口用普通 Window(而非 Settings 场景):Settings 场景是 macOS 专有的
        // 「偏好设置」窗口,圆角/标题栏/红绿灯与侧栏的融合都和普通窗口不同,NavigationSplitView
        // 盖不住。改用 Window 后,设置窗口与主窗口同型,外观完全一致;⌘, 由下方 .appSettings 命令打开。
        Window(tr("设置", "Settings"), id: settingsWindowID) {
            SettingsView()
                .environmentObject(settings)
                .id(settings.language)
        }
        .windowResizability(.contentSize)
    }
}

/// 设置窗口的场景 id（⌘, 与「设置…」菜单项据此 openWindow）
let settingsWindowID = "hunk.settings"

/// ⌘⇧N 空白欢迎窗口的哨兵值前缀（带 UUID 保证每次都开新窗）
let welcomeWindowSentinel = "hunk://welcome"

/// 窗口根：每个窗口持有自己的 RepoViewModel。
private struct WindowRoot: View {
    @StateObject private var vm: RepoViewModel

    init(initialPath: String?) {
        if let initialPath, initialPath.hasPrefix(welcomeWindowSentinel) {
            // 空白欢迎窗口：不恢复上次仓库
            _vm = StateObject(wrappedValue: RepoViewModel(initialPath: nil, restoreLast: false))
        } else {
            let path = (initialPath?.isEmpty ?? true) ? nil : initialPath
            _vm = StateObject(wrappedValue: RepoViewModel(initialPath: path))
        }
    }

    var body: some View {
        ContentView()
            .environmentObject(vm)
            .frame(minWidth: 900, minHeight: 560)
            .focusedSceneObject(vm)
            // 记录所在 NSWindow（供命令行路由聚焦），并装上「关闭前查未保存」代理
            .background(WindowAccessor { window in
                vm.window = window
                if let window { vm.installCloseGuard(on: window) }
            })
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
    @Environment(\.openWindow) private var openWindow
    // 观察语言设置：切换语言后自定义菜单项即时换文案
    @ObservedObject private var settings = SettingsStore.shared

    var body: some Commands {
        // 关于面板：带作者署名（GitHub: 0x30，可点击）
        CommandGroup(replacing: .appInfo) {
            Button(tr("关于 Hunk", "About Hunk")) {
                let credits = NSMutableAttributedString(
                    string: tr("作者：0x30（GitHub）", "Author: 0x30 (GitHub)"),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
                if let range = credits.string.range(of: "0x30") {
                    credits.addAttribute(
                        .link,
                        value: "https://github.com/0x30",
                        range: NSRange(range, in: credits.string)
                    )
                }
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
            }
        }
        // 设置窗口改用普通 Window 后,需自己提供「设置…」菜单项与 ⌘,（原 Settings 场景自带）
        CommandGroup(replacing: .appSettings) {
            Button(tr("设置…", "Settings…")) {
                openWindow(id: settingsWindowID)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            Button(tr("检查更新…", "Check for Updates…")) {
                Task { await UpdateChecker.shared.check(userInitiated: true) }
            }
            Button(tr("安装 hunk 命令行工具…", "Install 'hunk' Command…")) {
                vm?.notice = CLIInstaller.install()
            }
            .disabled(vm == nil)
            Button(tr("在访达中显示诊断日志", "Reveal Diagnostic Log")) {
                NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL])
            }
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

            Button(tr("新建窗口", "New Window")) {
                openWindow(value: "\(welcomeWindowSentinel)/\(UUID().uuidString)")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(tr("打开仓库…", "Open Repository…")) {
                vm?.openRepoPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(vm == nil)

            // 「最近打开」子菜单由 RecentMenuController（AppKit）插入，
            // 用 attributedTitle 实现两行（项目名 + 灰色路径），此处不再用 SwiftUI Menu
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
                vm?.openSearchTab(replace: false)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(vm?.repoRoot == nil)

            Button(tr("全局替换…", "Replace in Repository…")) {
                vm?.openSearchTab(replace: true)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(vm?.repoRoot == nil)

            Button(tr("查找", "Find")) {
                // 触发编辑器的查找条（NSTextView usesFindBar）
                let item = NSMenuItem()
                item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            }
            .keyboardShortcut("f", modifiers: .command)

            Button(tr("替换", "Replace")) {
                // 触发编辑器查找条的「替换」模式（NSTextView usesFindBar）
                let item = NSMenuItem()
                item.tag = Int(NSTextFinder.Action.showReplaceInterface.rawValue)
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            }
            .keyboardShortcut("r", modifiers: .command)
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

            Button(tr("清空终端", "Clear Terminal")) {
                vm?.clearActiveTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(vm?.terminalFocused != true)

            Divider()

            // 终端聚焦时 ⌘⇧[]/⌘⇧] 切终端标签，否则切编辑器文件标签
            Button(vm?.terminalFocused == true ? tr("下一个终端", "Next Terminal") : tr("下一个标签页", "Next Tab")) {
                if let vm, vm.terminalFocused { vm.cycleTerminal(offset: 1) }
                else { vm?.activateNeighborTab(offset: 1) }
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(vm == nil)

            Button(vm?.terminalFocused == true ? tr("上一个终端", "Previous Terminal") : tr("上一个标签页", "Previous Tab")) {
                if let vm, vm.terminalFocused { vm.cycleTerminal(offset: -1) }
                else { vm?.activateNeighborTab(offset: -1) }
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(vm == nil)

            Divider()

            // 刷新保留为菜单项,不再占用 ⌘R（已让给编辑器替换）
            Button(tr("刷新", "Refresh")) {
                if let vm { Task { await vm.refresh() } }
            }
            .disabled(vm == nil)

            Button(tr("提交", "Commit")) {
                vm?.commit()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(vm == nil)
        }
    }
}
