import SwiftUI
import SwiftTerm

// MARK: - 终端会话

/// 单个 shell 会话：持有终端视图与进程，面板隐藏/切换标签时只是移出层级，会话不中断。
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    /// shell 退出（用户输入 exit）时回调
    var onExit: ((TerminalSession) -> Void)?
    /// 终端获得/失去键盘焦点（用于 ⌘N/⌘W 路由到终端语义）
    var onFocusChange: ((Bool) -> Void)?

    private var terminalView: FocusReportingTerminalView?

    /// 返回现有会话视图；没有则启动用户默认 shell（登录式，工作目录为仓库根）。
    func view(root: URL?, font: NSFont) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = FocusReportingTerminalView(frame: .zero)
        view.onFocusChange = { [weak self] focused in self?.onFocusChange?(focused) }
        view.processDelegate = self
        view.font = font
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("LANG=zh_CN.UTF-8")
        view.startProcess(
            executable: shell,
            environment: environment,
            execName: "-" + (shell as NSString).lastPathComponent,  // 登录 shell，读取用户配置
            currentDirectory: root?.path
        )
        terminalView = view
        return view
    }

    /// 主动结束会话（⌘W / 垃圾桶按钮）。
    func terminate() {
        terminalView?.terminate()
        terminalView = nil
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminalView = nil
        onExit?(self)
    }
}

/// 上报键盘焦点变化的终端视图：菜单 ⌘N/⌘W 据此切换文件/终端语义。
/// （become/resignFirstResponder 在 SwiftTerm 里非 open，改用 KVO 观察窗口第一响应者）
private final class FocusReportingTerminalView: LocalProcessTerminalView {
    var onFocusChange: ((Bool) -> Void)?
    private var observation: NSKeyValueObservation?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            observation = nil
            report(false)
            return
        }
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            guard let self else { return }
            var focused = false
            var responder = window.firstResponder as? NSView
            while let view = responder {
                if view === self { focused = true; break }
                responder = view.superview
            }
            self.report(focused)
        }
    }

    private func report(_ focused: Bool) {
        guard focused != lastReported else { return }
        lastReported = focused
        onFocusChange?(focused)
    }
}

// MARK: - 面板

/// VS Code 式底部终端面板（⌘J 切换；多会话标签；⌘N 新建、⌘W 关闭当前会话）。
struct TerminalPanel: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(tr("终端", "Terminal"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                // 会话标签
                ForEach(Array(vm.terminals.enumerated()), id: \.element.id) { index, session in
                    Button {
                        vm.activeTerminalID = session.id
                    } label: {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(session.id == vm.activeTerminalID ? Color.primary : .secondary)
                            .frame(width: 18, height: 16)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(session.id == vm.activeTerminalID ? Color.primary.opacity(0.12) : .clear)
                            )
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button {
                    vm.newTerminal()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tr("新建终端（终端聚焦时 ⌘N）", "New Terminal (⌘N while focused)"))

                Button {
                    vm.closeActiveTerminal()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tr("结束当前会话（终端聚焦时 ⌘W）", "Kill Session (⌘W while focused)"))

                Button {
                    vm.toggleTerminal()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tr("收起面板（⌘J）", "Hide Panel (⌘J)"))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)

            Divider()

            if let session = vm.activeTerminal {
                TerminalHostView(
                    session: session,
                    root: vm.repoRoot,
                    font: settings.editorNSFont
                )
                .id(session.id)  // 切换会话时重挂对应的终端视图
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 终端与详情区之间的拖拽分隔条：高度存在视图模型里，开关面板/切换文件都不会变。
struct TerminalResizeDivider: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var heightAtDragStart: CGFloat?

    var body: some View {
        Divider()
            .frame(maxWidth: .infinity)
            .overlay(Color.clear.frame(height: 8).contentShape(Rectangle()))
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if heightAtDragStart == nil { heightAtDragStart = vm.terminalHeight }
                        let proposed = (heightAtDragStart ?? 240) - value.translation.height
                        vm.terminalHeight = min(max(proposed, 80), 700)
                    }
                    .onEnded { _ in heightAtDragStart = nil }
            )
    }
}

/// 终端 NSView 桥接：复用 TerminalSession 持有的视图实例。
private struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let root: URL?
    let font: NSFont

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.view(root: root, font: font)
        // 面板弹出后直接可输入
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        if view.font != font {
            view.font = font
        }
    }
}
