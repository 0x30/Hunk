import SwiftUI
import HunkCore

/// 状态栏语言选择面板（VSCode 式）：顶部搜索框，列表可上下键导航、回车选中，
/// 当前生效语言打勾并默认预选。
struct LanguagePicker: View {
    @EnvironmentObject var vm: RepoViewModel
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private struct Option: Identifiable {
        let id: String
        let name: String
        let ext: String?  // nil = 自动（按文件名）
    }

    private var allOptions: [Option] {
        [Option(id: "__auto__", name: tr("自动（按文件名）", "Auto (by file name)"), ext: nil)]
            + Lexer.allLanguages.map { Option(id: $0.ext, name: $0.name, ext: $0.ext) }
    }

    private var matches: [Option] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allOptions }
        return allOptions.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(tr("选择语言…", "Select language…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { choose() }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, opt in
                            row(opt, highlighted: index == selectedIndex)
                                .id(opt.id)   // 与 ForEach 的 id 一致，避免双 identity 冲突复用错行
                                .contentShape(Rectangle())
                                .onTapGesture { choose(opt) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
                .onChange(of: selectedIndex) { _, i in
                    if matches.indices.contains(i) { proxy.scrollTo(matches[i].id, anchor: nil) }
                }
            }
        }
        .frame(width: 300)
        .onAppear {
            focused = true
            selectedIndex = matches.firstIndex { $0.ext == vm.editorLanguageOverride } ?? 0
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private func row(_ opt: Option, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(opt.ext == vm.editorLanguageOverride ? 1 : 0)
            Text(opt.name)
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        selectedIndex = max(0, min(matches.count - 1, selectedIndex + delta))
        return .handled
    }

    private func choose(_ opt: Option? = nil) {
        let target = opt ?? (matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil)
        guard let target else { return }
        vm.editorLanguageOverride = target.ext
        isPresented = false
    }
}
