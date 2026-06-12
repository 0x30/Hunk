import SwiftUI
import HunkCore

struct ContentView: View {
    @EnvironmentObject var vm: RepoViewModel
    @Environment(\.openWindow) private var openWindow

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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard vm.repoRoot != nil, !vm.isSyncing else { return }
            Task { await vm.refresh() }
        }
        .task {
            // 文件图标默认走 open-vsx：首启自动安装 Material Icon Theme
            IconThemeStore.shared.bootstrap()
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
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(vm.repoRoot?.lastPathComponent ?? "Hunk")
        .navigationSubtitle(vm.headSummary ?? "")
        .toolbar {
            // Xcode 式：导航器图标组（点选中的再点一次收起侧边栏），分支与同步紧随其后
            ToolbarItemGroup(placement: .navigation) {
                navButton(
                    tab: .files,
                    systemImage: "folder",
                    help: tr("文件 (⌘1)", "Files (⌘1)")
                )
                navButton(
                    tab: .changes,
                    systemImage: "plus.forwardslash.minus",
                    badge: vm.changes.count,
                    help: tr("源代码管理 (⌘2)", "Source Control (⌘2)")
                )
                BranchMenu()
                SyncControls()
            }
        }
    }

    private func navButton(tab: SidebarTab, systemImage: String, badge: Int = 0, help: String) -> some View {
        let selected = vm.sidebarVisible && vm.sidebarTab == tab
        return Button {
            vm.toggleSidebarTab(tab)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .overlay(alignment: .topTrailing) {
                    Text(badge > 0 ? "\(min(badge, 99))" : "")
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, badge > 0 ? 3 : 0)
                        .padding(.vertical, badge > 0 ? 0.5 : 0)
                        .background(Capsule().fill(badge > 0 ? Color.accentColor : .clear))
                        .offset(x: 9, y: -5)
                }
        }
        .help(help)
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
        VStack(spacing: 12) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.quaternary)
            Text(tr("选择一个文件查看差异或编辑", "Select a file to view its diff or edit"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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
