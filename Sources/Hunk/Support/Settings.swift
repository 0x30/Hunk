import SwiftUI
import HunkCore

// MARK: - 语言

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return tr("跟随系统", "System")
        case .zhHans: return "简体中文"
        case .english: return "English"
        }
    }
}

enum ResolvedLanguage { case zh, en }

/// 全局翻译函数：`tr("中文", "English")`。
/// 字符串直接内联在调用点，新增文案无需维护 key 表。
func tr(_ zh: String, _ en: String) -> String {
    SettingsStore.shared.resolvedLanguage == .zh ? zh : en
}

// MARK: - 设置存储

/// 应用级设置，全部持久化到 UserDefaults，变更实时发布。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "appLanguage") }
    }

    @Published var editorFontName: String {
        didSet { defaults.set(editorFontName, forKey: "editorFontName") }
    }

    @Published var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: "editorFontSize") }
    }

    /// 颜色主题 id："system" 表示内置（跟随系统明暗），其余为已下载的 VS Code 主题
    @Published var themeID: String {
        didSet { defaults.set(themeID, forKey: "themeID") }
    }

    /// 文件图标主题 id：
    /// "" = 自动（优先使用已安装的图标主题），"sf" = 强制内置 SF Symbols，
    /// 其余为已下载的 VS Code 图标主题 id。
    @Published var iconThemeID: String {
        didSet { defaults.set(iconThemeID, forKey: "iconThemeID") }
    }

    /// 侧边栏更改列表：树状 / 扁平
    @Published var changesAsTree: Bool {
        didSet { defaults.set(changesAsTree, forKey: "changesAsTree") }
    }

    /// diff 布局：分栏 / 统一
    @Published var splitDiff: Bool {
        didSet { defaults.set(splitDiff, forKey: "splitDiff") }
    }

    private init() {
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        editorFontName = defaults.string(forKey: "editorFontName") ?? "SF Mono"
        let size = defaults.double(forKey: "editorFontSize")
        editorFontSize = size > 0 ? size : 13
        themeID = defaults.string(forKey: "themeID") ?? "system"
        iconThemeID = defaults.string(forKey: "iconThemeID") ?? ""
        changesAsTree = defaults.object(forKey: "changesAsTree") as? Bool ?? true
        splitDiff = defaults.bool(forKey: "splitDiff")
    }

    var resolvedLanguage: ResolvedLanguage {
        switch language {
        case .zhHans: return .zh
        case .english: return .en
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .zh : .en
        }
    }

    var editorNSFont: NSFont {
        NSFont(name: editorFontName, size: editorFontSize)
            ?? .monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    var editorFont: Font {
        Font(editorNSFont)
    }

    /// 系统上可用的等宽字体族。
    static var monospacedFontFamilies: [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
}

// MARK: - 语法着色（内置配色，task 4 接入 VS Code 主题后由 ThemeStore 覆盖）

extension SettingsStore {
    func tokenNSColor(for type: TokenType) -> NSColor {
        if let themed = ThemeStore.shared.tokenNSColor(for: type) {
            return themed
        }
        switch type {
        case .keyword: return .systemPurple
        case .string: return .systemRed
        case .comment: return .secondaryLabelColor
        case .number: return .systemBlue
        case .type: return .systemTeal
        }
    }

    func tokenColor(for type: TokenType) -> Color {
        Color(nsColor: tokenNSColor(for: type))
    }
}
