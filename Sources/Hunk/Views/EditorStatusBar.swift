import SwiftUI
import HunkCore

/// 编辑器底部状态栏（类 VSCode/Zed）：光标行列 · 选中行数 · 高亮语言（可点切换）· 终端开关。
struct EditorStatusBar: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var showLanguagePicker = false

    var body: some View {
        HStack(spacing: 12) {
            Text(cursorText)

            Spacer(minLength: 8)

            // 高亮语言：点击弹出带搜索的选择面板（新建未保存文件可借此提前选语言高亮）
            Button {
                showLanguagePicker = true
            } label: {
                Text(vm.editorLanguageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("切换高亮语言", "Change highlight language"))
            .popover(isPresented: $showLanguagePicker, arrowEdge: .bottom) {
                LanguagePicker(isPresented: $showLanguagePicker)
                    .environmentObject(vm)
            }

            // 终端开关（⌘J）
            Button {
                vm.toggleTerminal()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(vm.showTerminal ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("终端（⌘J）", "Terminal (⌘J)"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 18)  // 右侧留白，避开窗口右下角圆角对终端按钮的遮挡
        .frame(height: 22)
        .background(.bar)
    }

    private var cursorText: String {
        if vm.editorSelectedLines > 1 {
            return tr("第 \(vm.editorCursorLine) 行，第 \(vm.editorCursorColumn) 列 · 选中 \(vm.editorSelectedLines) 行",
                      "Ln \(vm.editorCursorLine), Col \(vm.editorCursorColumn) · \(vm.editorSelectedLines) lines selected")
        }
        return tr("第 \(vm.editorCursorLine) 行，第 \(vm.editorCursorColumn) 列",
                  "Ln \(vm.editorCursorLine), Col \(vm.editorCursorColumn)")
    }
}
