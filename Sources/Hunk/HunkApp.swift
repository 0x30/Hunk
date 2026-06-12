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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("新建文件", "New File")) {
                vm?.newUntitledFile()
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

            Button(tr("关闭标签页", "Close Tab")) {
                vm?.closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(vm == nil)
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
