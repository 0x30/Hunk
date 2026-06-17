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
        // 分支面板：窗口内居中浮层
        .overlay(alignment: .top) {
            if vm.showBranchPanel && vm.isGitRepo {
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
        // 命令行路由要求开新窗口（当前窗口都被占用时）
        .onChange(of: vm.openWindowRequest) { _, path in
            if let path {
                vm.openWindowRequest = nil
                openWindow(value: path)
            }
        }
        // 新窗口的仓库打开后，定位命令行指定的文件
        .onChange(of: vm.repoRoot) { _, root in
            guard let root,
                  let reveal = CLIOpenRouter.takePendingReveal(),
                  reveal.hasPrefix(root.path + "/")
            else { return }
            vm.revealInFiles(String(reveal.dropFirst(root.path.count + 1)))
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
            // 终端是详情区底部的固定高度面板（VS Code 式，⌘J 切换）：
            // 高度只由拖拽分隔条改变，开关面板/切换文件不影响。
            // 用 GeometryReader 把终端高度钳到「可用高度 - 详情区下限」，
            // 避免窗口被缩小到比终端还矮时约束无解、Auto Layout 反复重入卡死。
            GeometryReader { geo in
                VStack(spacing: 0) {
                    DetailView()
                        .frame(maxHeight: .infinity)
                    if vm.showTerminal {
                        TerminalResizeDivider()
                        TerminalPanel()
                            .frame(height: min(vm.terminalHeight, max(120, geo.size.height - 160)))
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // 删除分支的确认框（单个删除与批量清理共用）
        .confirmationDialog(
            tr("删除 \(vm.branchesToDelete?.count ?? 0) 个分支？",
               "Delete \(vm.branchesToDelete?.count ?? 0) branch(es)?"),
            isPresented: Binding(
                get: { vm.branchesToDelete != nil },
                set: { if !$0 { vm.branchesToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tr("删除", "Delete"), role: .destructive) {
                vm.confirmDeleteBranches()
            }
            Button(tr("取消", "Cancel"), role: .cancel) {
                vm.branchesToDelete = nil
            }
        } message: {
            Text((vm.branchesToDelete ?? []).joined(separator: "\n"))
        }
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

/// 详情区:统一标签系统——顶部标签栏(文件/diff/提交/搜索) + 当前激活标签的内容。
struct DetailView: View {
    @EnvironmentObject var vm: RepoViewModel

    private var hasTabs: Bool {
        !vm.openTabs.isEmpty || vm.diffPath != nil || vm.historyDetail != nil || vm.searchTabOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasTabs {
                EditorTabBar()
                Divider()
            }
            content
        }
        // 关闭未保存文件的确认(从标签 × 触发,与具体激活内容无关,放这一层常驻)
        .confirmationDialog(
            tr("「\(vm.pendingCloseTab.map { vm.displayName(for: $0) } ?? "")」有未保存的修改",
               "“\(vm.pendingCloseTab.map { vm.displayName(for: $0) } ?? "")” has unsaved changes"),
            isPresented: Binding(
                get: { vm.pendingCloseTab != nil },
                set: { if !$0 { vm.pendingCloseTab = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tr("保存并关闭", "Save & Close")) {
                if let path = vm.pendingCloseTab { vm.pendingCloseTab = nil; vm.saveAndCloseTab(path) }
            }
            Button(tr("放弃更改", "Discard Changes"), role: .destructive) {
                if let path = vm.pendingCloseTab { vm.pendingCloseTab = nil; vm.performCloseTab(path) }
            }
            Button(tr("取消", "Cancel"), role: .cancel) { vm.pendingCloseTab = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.activeDetail {
        case .file(let path):
            EditorArea(activePath: path, showConflictBar: !vm.conflictBlocks.isEmpty && vm.editorPath == path)
        case .diff:
            diffContent(path: vm.diffPath ?? "")
        case .commit:
            HistoryDetailView()
        case .search:
            SearchPanelView()
        case nil:
            EmptyDetailView()
        }
    }

    /// diff 标签的内容:冲突/图片/「编辑模式」分别走对应视图,否则才是 diff。
    @ViewBuilder
    private func diffContent(path: String) -> some View {
        if vm.diffArea == .conflicted {
            EditorArea(activePath: path, showConflictBar: true)
        } else if FileIcon.isImage(path) {
            ImagePreviewView(path: path)
        } else if vm.editingChangedFile {
            EditorArea(activePath: path)
        } else {
            DiffDetailView(path: path)
        }
    }
}

struct EmptyDetailView: View {
    var body: some View {
        // 未选择文件时保持纯净，不展示任何提示内容
        Color(nsColor: .textBackgroundColor)
            .ignoresSafeArea(edges: .bottom)
            .contentShape(Rectangle())
            .onTapGesture {
                // 点击空白编辑器：把键盘焦点从终端移走，⌘N 回到「新建文件」语义
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
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
