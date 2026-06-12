import SwiftUI
import HunkCore

struct ContentView: View {
    @EnvironmentObject var vm: RepoViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        Group {
            if vm.repoRoot == nil {
                WelcomeView()
            } else {
                MainSplitView()
            }
        }
        // 拖入文件直接打开，拖入文件夹询问在哪个窗口打开
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            vm.handleDrop(url: url)
            return true
        }
        .confirmationDialog(
            tr("打开文件夹「\(vm.pendingFolderDrop?.lastPathComponent ?? "")」",
               "Open folder “\(vm.pendingFolderDrop?.lastPathComponent ?? "")”"),
            isPresented: Binding(
                get: { vm.pendingFolderDrop != nil },
                set: { if !$0 { vm.pendingFolderDrop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tr("在当前窗口打开", "Open in This Window")) {
                if let url = vm.pendingFolderDrop {
                    vm.pendingFolderDrop = nil
                    Task { await vm.open(url) }
                }
            }
            Button(tr("在新窗口打开", "Open in New Window")) {
                if let url = vm.pendingFolderDrop {
                    vm.pendingFolderDrop = nil
                    openWindow(value: url.path)
                }
            }
            Button(tr("取消", "Cancel"), role: .cancel) {
                vm.pendingFolderDrop = nil
            }
        }
        .alert(
            tr("新建文件", "New File"),
            isPresented: Binding(
                get: { vm.newFilePrompt != nil },
                set: { if !$0 { vm.newFilePrompt = nil } }
            )
        ) {
            TextField(tr("文件名（可含子路径，如 docs/note.md）", "File name (may include subpath)"), text: $vm.newFileName)
            Button(tr("创建", "Create")) { vm.confirmNewFile() }
            Button(tr("取消", "Cancel"), role: .cancel) { vm.newFilePrompt = nil }
        } message: {
            let dir = vm.newFilePrompt?.directory ?? ""
            Text(dir.isEmpty
                 ? tr("位置：仓库根目录", "Location: repository root")
                 : tr("位置：\(dir)/", "Location: \(dir)/"))
        }
        .alert(
            tr("出错了", "Something went wrong"),
            isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )
        ) {
            Button(tr("好", "OK"), role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .overlay {
            if vm.showQuickOpen {
                QuickOpenView()
            }
        }
        .overlay {
            if vm.showGlobalSearch {
                GlobalSearchView()
            }
        }
        // 分支面板：窗口内居中浮层
        .overlay(alignment: .top) {
            if vm.showBranchPanel {
                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { vm.showBranchPanel = false }

                    BranchPopover(isPresented: $vm.showBranchPanel)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                        .padding(.top, 90)
                }
                .onExitCommand { vm.showBranchPanel = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard vm.repoRoot != nil, !vm.isSyncing else { return }
            Task { await vm.refresh() }
        }
        // `hunk` 命令行送来的路径（原子领取，多窗口只处理一次）
        .onReceive(NotificationCenter.default.publisher(for: CLIOpenRouter.notification)) { _ in
            if let path = CLIOpenRouter.takePending() {
                vm.openFromCLI(path)
            }
        }
        .alert(
            tr("提示", "Notice"),
            isPresented: Binding(
                get: { vm.notice != nil },
                set: { if !$0 { vm.notice = nil } }
            )
        ) {
            Button(tr("好", "OK"), role: .cancel) { vm.notice = nil }
        } message: {
            Text(vm.notice ?? "")
        }
        .task {
            // 冷启动：open 事件早于视图订阅送达时，路径暂存在路由里，这里补领一次
            if let path = CLIOpenRouter.takePending() {
                vm.openFromCLI(path)
            }
            // 文件图标默认走 open-vsx：首启自动安装 Material Icon Theme
            IconThemeStore.shared.bootstrap()
            // 静默检查新版本（开发构建跳过）
            UpdateChecker.shared.checkAutomatically()
        }
        .alert(
            tr("发现新版本", "Update Available"),
            isPresented: Binding(
                get: { updater.available != nil },
                set: { if !$0 { updater.available = nil } }
            )
        ) {
            Button(tr("前往下载", "Download")) {
                if let release = updater.available { updater.openDownloadPage(release) }
            }
            Button(tr("跳过此版本", "Skip This Version")) {
                if let release = updater.available { updater.skip(release) }
            }
            Button(tr("稍后", "Later"), role: .cancel) {
                updater.available = nil
            }
        } message: {
            Text(tr("「\(updater.available?.name ?? "")」已在 GitHub 发布。", "“\(updater.available?.name ?? "")” is available on GitHub."))
        }
        .alert(
            tr("检查更新", "Check for Updates"),
            isPresented: Binding(
                get: { updater.checkResultMessage != nil },
                set: { if !$0 { updater.checkResultMessage = nil } }
            )
        ) {
            Button(tr("好", "OK"), role: .cancel) { updater.checkResultMessage = nil }
        } message: {
            Text(updater.checkResultMessage ?? "")
        }
    }
}

struct MainSplitView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        NavigationSplitView(
            columnVisibility: Binding(
                get: { vm.sidebarVisible ? .all : .detailOnly },
                set: { vm.sidebarVisible = $0 != .detailOnly }
            )
        ) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 460)
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        // 仓库名并入分支胶囊（Xcode 式），标题栏不再单独显示项目名与副标题
        .navigationTitle(vm.repoRoot?.lastPathComponent ?? "Hunk")
        .modifier(HideToolbarTitle())
        .toolbar {
            // 同步操作在「历史」模块头部，工具栏只保留分支
            ToolbarItem(placement: .navigation) {
                BranchMenu()
            }
        }
    }
}

/// 隐藏标题栏文字（macOS 15+；旧系统保留标题）。
private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// 详情区：根据选择展示 diff / 编辑器 / 图片预览 / 空态。
struct DetailView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        if vm.historyDetail != nil {
            HistoryDetailView()
        } else {
            selectionDetail
        }
    }

    @ViewBuilder
    private var selectionDetail: some View {
        switch vm.selection {
        case nil:
            EmptyDetailView()
        case .change(let path, let area):
            if area == .conflicted {
                EditorArea(activePath: path, showConflictBar: true)
            } else if FileIcon.isImage(path) {
                ImagePreviewView(path: path)
            } else if vm.editingChangedFile {
                EditorArea(activePath: path)
            } else {
                DiffDetailView(path: path)
            }
        case .file(let path):
            EditorArea(activePath: path, showConflictBar: !vm.conflictBlocks.isEmpty && vm.editorPath == path)
        }
    }
}

struct EmptyDetailView: View {
    var body: some View {
        // 未选择文件时保持纯净，不展示任何提示内容
        Color(nsColor: .textBackgroundColor)
            .ignoresSafeArea(edges: .bottom)
    }
}

struct ImagePreviewView: View {
    @EnvironmentObject var vm: RepoViewModel
    let path: String

    var body: some View {
        Group {
            if let root = vm.repoRoot,
               let image = NSImage(contentsOf: root.appendingPathComponent(path)) {
                VStack(spacing: 8) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 800, maxHeight: 600)
                        .shadow(radius: 4)
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(tr("无法预览此图片", "Cannot preview this image"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
