import SwiftUI

/// 设置窗口（⌘,）：Xcode 风格——左侧分类列表，右侧内容面板。
struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case appearance, editor, extensions
        var id: String { rawValue }
    }

    @State private var pane: Pane = .appearance

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $pane) {
                Label(tr("外观", "Appearance"), systemImage: "paintbrush")
                    .tag(Pane.appearance)
                Label(tr("编辑器", "Editor"), systemImage: "square.and.pencil")
                    .tag(Pane.editor)
                Label(tr("扩展", "Extensions"), systemImage: "puzzlepiece.extension")
                    .tag(Pane.extensions)
            }
            .listStyle(.sidebar)
            .frame(width: 178)

            Divider()

            Group {
                switch pane {
                case .appearance:
                    AppearanceSettings()
                case .editor:
                    EditorSettings()
                case .extensions:
                    ExtensionSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 740, height: 500)
        // ESC 关闭设置窗口（⌘W 由全局命令兜底处理）
        .onExitCommand {
            NSApp.keyWindow?.performClose(nil)
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
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section(tr("字体", "Font")) {
                Picker(tr("等宽字体", "Monospaced Font"), selection: $settings.editorFontName) {
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                    if !families.contains(settings.editorFontName) {
                        Text(settings.editorFontName).tag(settings.editorFontName)
                    }
                }

                HStack {
                    Text(tr("字号", "Size"))
                    Slider(value: $settings.editorFontSize, in: 9...22, step: 1)
                    Text("\(Int(settings.editorFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section(tr("预览", "Preview")) {
                Text("func greet(name: String) -> String {\n    // 简单的示例 sample\n    return \"Hello, \\(name)! 你好\"\n}")
                    .font(Font(settings.editorNSFont))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: ThemeStore.shared.editorBackground ?? .textBackgroundColor))
                    )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if families.isEmpty {
                families = SettingsStore.monospacedFontFamilies
            }
        }
    }
}

// MARK: - 扩展（open-vsx）

private struct ExtensionSettings: View {
    @ObservedObject var extensions = ExtensionStore.shared
    @State private var customReference = ""

    private let recommended: [(reference: String, title: String, note: String)] = [
        ("PKief.material-icon-theme", "Material Icon Theme", "文件图标 / File icons"),
        ("zhuangtongfa.material-theme", "One Dark Pro", "颜色主题 / Color theme"),
        ("dracula-theme.theme-dracula", "Dracula Official", "颜色主题 / Color theme"),
        ("GitHub.github-vscode-theme", "GitHub Theme", "颜色主题 / Color theme"),
    ]

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
