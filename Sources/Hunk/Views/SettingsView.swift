import SwiftUI

/// 设置窗口（⌘,）：与主窗口同构——左侧 NavigationSplitView 侧栏(设置分类),
/// 右侧详情内容。统一标题栏、顶部分隔线、侧栏材质到顶都由 NavigationSplitView 原生提供。
struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case appearance, editor, extensions
        var id: String { rawValue }

        var label: String {
            switch self {
            case .appearance: return tr("外观", "Appearance")
            case .editor: return tr("编辑器", "Editor")
            case .extensions: return tr("扩展", "Extensions")
            }
        }
        var systemImage: String {
            switch self {
            case .appearance: return "paintbrush"
            case .editor: return "square.and.pencil"
            case .extensions: return "puzzlepiece.extension"
            }
        }
    }

    @State private var pane: Pane? = .appearance
    // 分类浏览历史（Xcode 式前进/后退）。cursor 指向当前项;suppressHistory 区分
    // 「用户在侧栏点选」与「前进后退触发的 pane 变更」,避免后者又被记一笔历史。
    @State private var history: [Pane] = [.appearance]
    @State private var cursor = 0
    @State private var suppressHistory = false

    private var canGoBack: Bool { cursor > 0 }
    private var canGoForward: Bool { cursor < history.count - 1 }

    private func goBack() {
        guard canGoBack else { return }
        cursor -= 1
        suppressHistory = true
        pane = history[cursor]
    }
    private func goForward() {
        guard canGoForward else { return }
        cursor += 1
        suppressHistory = true
        pane = history[cursor]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Label(item.label, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 215, ideal: 235, max: 320)
            .modifier(HideSidebarToggle())   // 设置窗口不需要折叠侧栏按钮
        } detail: {
            Group {
                switch pane {
                case .appearance, nil:
                    AppearanceSettings()
                case .editor:
                    EditorSettings()
                case .extensions:
                    ExtensionSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        // 仿 Xcode/系统设置:前进/后退作为 toolbar 按钮(系统给一个玻璃胶囊),
        // 标题用 navigationTitle——它是窗口标题、渲染成纯文本(不带胶囊),系统会把它
        // 排在工具栏按钮之后。若把标题也做成 toolbar 项,macOS 26 会把它并进按钮的胶囊里。
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!canGoBack)
                .help(tr("后退", "Back"))

                Button(action: goForward) {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!canGoForward)
                .help(tr("前进", "Forward"))
            }
        }
        .navigationTitle(pane?.label ?? tr("设置", "Settings"))
        .onChange(of: pane) { _, newValue in
            guard let newValue else { return }
            if suppressHistory { suppressHistory = false; return }
            guard history[cursor] != newValue else { return }
            // 用户在侧栏新点了一项:截掉当前位置之后的「前进」分支,再追加并前移光标
            if cursor + 1 < history.count {
                history.removeSubrange((cursor + 1)...)
            }
            history.append(newValue)
            cursor = history.count - 1
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 480, idealHeight: 520)
        // ESC 关闭设置窗口（⌘W 由全局命令兜底处理）
        .onExitCommand {
            NSApp.keyWindow?.performClose(nil)
        }
    }
}

/// 隐藏侧栏折叠按钮——必须作用在侧栏自身(List)上,作用在 NavigationSplitView 根上无效。
private struct HideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var extensions = ExtensionStore.shared

    var body: some View {
        Form {
            Section {
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                // 顶部菜单栏由系统按启动语言加载，切换后需重启
                if settings.language != settings.launchLanguage {
                    HStack(spacing: 8) {
                        Text(tr("顶部菜单栏将在重新启动后切换语言。",
                                "The menu bar switches language after a relaunch."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(tr("立即重启", "Relaunch Now")) {
                            AppRelaunch.relaunch()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section(tr("颜色主题", "Color Theme")) {
                Picker(tr("主题", "Theme"), selection: $settings.themeID) {
                    Text(tr("内置（跟随系统）", "Built-in (System)")).tag("system")
                    ForEach(extensions.installed.flatMap(\.colorThemes)) { ref in
                        Text(ref.label).tag(ref.id)
                    }
                }
                .onChange(of: settings.themeID) { _, _ in
                    ThemeStore.shared.loadActive()
                }

                Text(tr("选择深色主题时，整个应用会一并切换为深色外观。",
                        "Choosing a dark theme switches the whole app to dark appearance."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if extensions.installed.flatMap(\.colorThemes).isEmpty {
                    Text(tr("还没有可选主题——到「扩展」页从 open-vsx 下载（如 One Dark Pro、Dracula）。",
                            "No themes yet — install some from open-vsx in the Extensions tab (e.g. One Dark Pro, Dracula)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(tr("文件图标", "File Icons")) {
                Picker(tr("图标主题", "Icon Theme"), selection: $settings.iconThemeID) {
                    Text(tr("自动（优先已安装主题）", "Auto (prefer installed)")).tag("")
                    Text(tr("内置（SF Symbols）", "Built-in (SF Symbols)")).tag("sf")
                    ForEach(extensions.installed.flatMap(\.iconThemes)) { ref in
                        Text(ref.label).tag(ref.id)
                    }
                }
                .onChange(of: settings.iconThemeID) { _, _ in
                    IconThemeStore.shared.loadActive()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 编辑器

private struct EditorSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var monoFamilies: [String] = []
    @State private var allFamilies: [String] = []
    @State private var showRestoreConfirm = false
    @State private var newHiddenName = ""

    /// 字号输入框:不限制范围,手动输入(SwiftUI 默认仍会拦非法字符)
    private var sizeText: Binding<String> {
        Binding(
            get: { String(Int(settings.editorFontSize.rounded())) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if let value = Double(digits), value > 0 { settings.editorFontSize = value }
            }
        )
    }

    private var families: [String] {
        settings.showAllFonts ? allFamilies : monoFamilies
    }

    /// 终端字号输入框（终端只列等宽字体，故不复用 showAllFonts）。
    private var terminalSizeText: Binding<String> {
        Binding(
            get: { String(Int(settings.terminalFontSize.rounded())) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if let value = Double(digits), value > 0 { settings.terminalFontSize = value }
            }
        )
    }

    var body: some View {
        Form {
            Section(tr("字体", "Font")) {
                Picker(settings.showAllFonts ? tr("字体", "Font") : tr("等宽字体", "Monospaced Font"),
                       selection: $settings.editorFontName) {
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                    if !families.contains(settings.editorFontName) {
                        Text(settings.editorFontName).tag(settings.editorFontName)
                    }
                }

                Toggle(tr("显示全部字体（含非等宽）", "Show all fonts (including non-monospaced)"),
                       isOn: $settings.showAllFonts)

                HStack {
                    Text(tr("字号", "Size"))
                    Spacer()
                    TextField("", text: sizeText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: $settings.editorFontSize, in: 1...512, step: 1)
                        .labelsHidden()
                    Text("pt").foregroundStyle(.secondary)
                }

                HStack {
                    Text(tr("行高", "Line height"))
                    Slider(value: $settings.editorLineHeight, in: 1.0...2.2, step: 0.05)
                    Text(String(format: "%.2f×", settings.editorLineHeight))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Section(tr("终端", "Terminal")) {
                Picker(tr("终端字体", "Terminal font"), selection: $settings.terminalFontName) {
                    ForEach(monoFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                    if !monoFamilies.contains(settings.terminalFontName) {
                        Text(settings.terminalFontName).tag(settings.terminalFontName)
                    }
                }

                HStack {
                    Text(tr("字号", "Size"))
                    Spacer()
                    TextField("", text: terminalSizeText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: $settings.terminalFontSize, in: 1...512, step: 1)
                        .labelsHidden()
                    Text("pt").foregroundStyle(.secondary)
                }

                Text(tr("终端字体独立于编辑器，互不影响。",
                        "The terminal font is independent of the editor."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("视图", "View")) {
                Picker(tr("差异默认视图", "Default diff view"), selection: $settings.splitDiff) {
                    Text(tr("统一视图", "Unified")).tag(false)
                    Text(tr("左右分栏", "Side-by-side")).tag(true)
                }

                Picker(tr("文件列表风格", "File list style"), selection: $settings.fileTreeStyle) {
                    ForEach(FileTreeStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Text(tr("「文件列表风格」作用于「源代码管理」更改列表与提交详情的文件列表;页面内的切换开关与此设置同步。",
                        "“File list style” applies to the Source Control changes list and the commit-detail file list; the in-page toggle stays in sync with this setting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("隐藏文件", "Hidden Files")) {
                ForEach(settings.hiddenFileNames.sorted(), id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        Button {
                            settings.hiddenFileNames.remove(name)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(tr("移除", "Remove"))
                    }
                }

                HStack {
                    TextField(tr("添加名称，如 .DS_Store", "Add a name, e.g. .DS_Store"), text: $newHiddenName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addHiddenName() }
                    Button(tr("添加", "Add")) { addHiddenName() }
                        .disabled(newHiddenName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text(tr("文件树中不显示这些名字的文件/文件夹（匹配任意层级）。不影响「源代码管理」更改列表。",
                        "Files/folders with these names are hidden from the file tree (matched at any level). The Source Control changes list is unaffected."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("预览", "Preview")) {
                Text("func greet(name: String) -> String {\n    // 简单的示例 sample\n    let parts = [\"Hello\", name]\n    return parts.joined(separator: \", \") + \" 你好\"\n}")
                    .font(Font(settings.editorNSFont))
                    .lineSpacing(settings.editorFontSize * (settings.editorLineHeight - 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: ThemeStore.shared.editorBackground ?? .textBackgroundColor))
                    )
            }

            Section {
                Button(role: .destructive) {
                    showRestoreConfirm = true
                } label: {
                    Label(tr("恢复默认设置", "Restore Defaults"), systemImage: "arrow.counterclockwise")
                }
                .confirmationDialog(
                    tr("恢复编辑器与视图的默认设置？", "Restore editor & view defaults?"),
                    isPresented: $showRestoreConfirm,
                    titleVisibility: .visible
                ) {
                    Button(tr("恢复默认", "Restore Defaults"), role: .destructive) {
                        settings.restoreDefaults()
                    }
                } message: {
                    Text(tr("字体、字号、行高、差异视图、文件列表风格、隐藏文件名单将恢复为推荐值（不影响语言、主题、图标）。",
                            "Font, size, line height, diff view, file list style and hidden-file list return to recommended values (language, theme and icons are untouched)."))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if monoFamilies.isEmpty { monoFamilies = SettingsStore.monospacedFontFamilies }
            if allFamilies.isEmpty { allFamilies = SettingsStore.allFontFamilies }
        }
    }

    private func addHiddenName() {
        let name = newHiddenName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        settings.hiddenFileNames.insert(name)
        newHiddenName = ""
    }
}

// MARK: - 扩展（open-vsx）

private struct ExtensionSettings: View {
    @ObservedObject var extensions = ExtensionStore.shared
    @State private var customReference = ""

    private var recommended: [(reference: String, title: String, note: String)] {
        [
            ("PKief.material-icon-theme", "Material Icon Theme", tr("文件图标", "File icons")),
            ("zhuangtongfa.material-theme", "One Dark Pro", tr("颜色主题", "Color theme")),
            ("dracula-theme.theme-dracula", "Dracula Official", tr("颜色主题", "Color theme")),
            ("GitHub.github-vscode-theme", "GitHub Theme", tr("颜色主题", "Color theme")),
        ]
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr(
                        "从 open-vsx.org 下载 VS Code 图标主题与颜色主题（只使用其中的静态资产，不运行扩展代码）。",
                        "Download VS Code icon & color themes from open-vsx.org (static assets only — no extension code is executed)."
                    ))
                    Text(tr(
                        "用法：① 点下载；② 图标主题立即生效（图标主题处于「自动」时）；③ 颜色主题到「外观 → 颜色主题」中选择。自定义扩展标识可在 open-vsx.org 的扩展页 URL 中找到，格式为 namespace.name。",
                        "Usage: ① Install; ② icon themes apply immediately (when Icon Theme is set to Auto); ③ pick color themes under Appearance → Color Theme. Find custom identifiers in the open-vsx.org extension URL, formatted namespace.name."
                    ))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section(tr("推荐", "Recommended")) {
                ForEach(recommended, id: \.reference) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                            Text(item.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        installButton(for: item.reference)
                    }
                }
            }

            Section(tr("自定义", "Custom")) {
                HStack {
                    TextField("namespace.name", text: $customReference)
                        .textFieldStyle(.roundedBorder)
                    Button(tr("下载", "Install")) {
                        Task { await ExtensionStore.shared.install(customReference) }
                    }
                    .disabled(customReference.trimmingCharacters(in: .whitespaces).isEmpty
                              || extensions.busyInstalling != nil)
                }
            }

            if !extensions.installed.isEmpty {
                Section(tr("已安装", "Installed")) {
                    ForEach(extensions.installed) { ext in
                        HStack {
                            Text(ext.displayName)
                            Spacer()
                            Button(role: .destructive) {
                                ExtensionStore.shared.uninstall(ext.id)
                                IconThemeStore.shared.loadActive()
                                ThemeStore.shared.loadActive()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let error = extensions.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func installButton(for reference: String) -> some View {
        let id = reference
        let isInstalled = extensions.installed.contains { $0.id.lowercased() == id.lowercased() }
        if extensions.busyInstalling == id {
            ProgressView()
                .controlSize(.small)
        } else if isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Button(tr("下载", "Install")) {
                Task { await ExtensionStore.shared.install(reference) }
            }
            .disabled(extensions.busyInstalling != nil)
        }
    }
}
