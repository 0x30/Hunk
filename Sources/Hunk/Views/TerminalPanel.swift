import SwiftUI
import SwiftTerm

// MARK: - 终端会话

/// 持有终端视图与 shell 进程：面板隐藏时视图只是移出层级，会话不中断。
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    /// shell 退出（用户输入 exit）时回调，由视图模型用来收起面板
    var onExit: (() -> Void)?

    private var terminalView: LocalProcessTerminalView?

    /// 返回现有会话视图；没有则启动用户默认 shell（登录式，工作目录为仓库根）。
    func view(root: URL?, font: NSFont) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = LocalProcessTerminalView(frame: .zero)
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

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminalView = nil  // 下次打开重新起一个 shell
        onExit?()
    }
}

// MARK: - 面板

/// VS Code 式底部终端面板（⌘J 切换）。
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
                Spacer()
                Button {
                    vm.showTerminal = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(tr("关闭终端（⌘J）", "Close Terminal (⌘J)"))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)

            Divider()

            TerminalHostView(
                session: vm.terminal,
                root: vm.repoRoot,
                font: settings.editorNSFont
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
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
