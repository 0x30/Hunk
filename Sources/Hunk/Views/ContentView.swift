import SwiftUI
import HunkCore

struct ContentView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        Group {
            if vm.repoRoot == nil {
                WelcomeView()
            } else {
                MainSplitView()
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
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 460)
        } detail: {
            DetailView()
        }
        .navigationTitle(vm.repoRoot?.lastPathComponent ?? "Hunk")
        .navigationSubtitle(vm.headSummary ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                BranchMenu()
                SyncControls()
            }
            ToolbarItemGroup {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(tr("刷新 (⌘R)", "Refresh (⌘R)"))

                Button {
                    vm.openRepoPanel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help(tr("打开仓库 (⌘O)", "Open Repository (⌘O)"))
            }
        }
    }
}

/// 详情区：根据选择展示 diff / 编辑器 / 图片预览 / 空态。
struct DetailView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        switch vm.selection {
        case nil:
            EmptyDetailView()
        case .change(let path, let area):
            if area == .conflicted {
                EditorView(path: path, showConflictBar: true)
            } else if FileIcon.isImage(path) {
                ImagePreviewView(path: path)
            } else if vm.editingChangedFile {
                EditorView(path: path, showConflictBar: false)
            } else {
                DiffDetailView(path: path)
            }
        case .file(let path):
            if FileIcon.isImage(path) {
                ImagePreviewView(path: path)
            } else {
                EditorView(path: path, showConflictBar: !vm.conflictBlocks.isEmpty)
            }
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
