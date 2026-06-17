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

/// 文件列表的展示风格（全局,文件树 + 提交详情文件列表都遵循）。
enum FileTreeStyle: String, CaseIterable, Identifiable {
    case flat         // 全部平铺,每行完整相对路径
    case fullTree     // 完全展开:每层文件夹各占一级
    case mergedTree   // 合并单链路径(推荐):a/b/c 合成一行,分叉才拆

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .flat: return tr("平铺列表", "Flat list")
        case .fullTree: return tr("完全展开树", "Full tree")
        case .mergedTree: return tr("合并路径树（推荐）", "Merged-path tree (recommended)")
        }
    }
}

/// 全局翻译函数：`tr("中文", "English")`。
/// 字符串直接内联在调用点，新增文案无需维护 key 表。
func tr(_ zh: String, _ en: String) -> String {
    SettingsStore.shared.resolvedLanguage == .zh ? zh : en
}

/// 当前 app 语言对应的 Locale（跟随设置、不跟系统）——相对时间与绝对日期格式化都用它。
/// 否则 Foundation 的格式化默认走系统 locale，app 内切到 English 后仍显示中文。
var appLocale: Locale {
    Locale(identifier: SettingsStore.shared.resolvedLanguage == .zh ? "zh_Hans" : "en")
}

/// 跟随 app 语言设置的相对时间（"3周前" / "3w ago"）。
func relativeTime(_ date: Date, to reference: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.locale = appLocale
    return formatter.localizedString(for: date, relativeTo: reference)
}

// MARK: - 设置存储

/// 应用级设置，全部持久化到 UserDefaults，变更实时发布。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "appLanguage")
            syncSystemLanguage()
        }
    }

    /// 应用启动时的语言：用于判断「重启后才生效」的提示该不该显示
    let launchLanguage: AppLanguage

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

    /// diff 布局：分栏 / 统一
    @Published var splitDiff: Bool {
        didSet { defaults.set(splitDiff, forKey: "splitDiff") }
    }

    /// 文件列表风格（全局）：平铺 / 完全展开树 / 合并路径树
    @Published var fileTreeStyle: FileTreeStyle {
        didSet { defaults.set(fileTreeStyle.rawValue, forKey: "fileTreeStyle") }
    }

    /// 编辑器行高倍数（1.0 = 字体自带行距；偏紧的等宽字体建议 1.2~1.4）
    @Published var editorLineHeight: Double {
        didSet { defaults.set(editorLineHeight, forKey: "editorLineHeight") }
    }

    /// 字体选择器是否列出全部字体（默认只列等宽——代码可读性更好）
    @Published var showAllFonts: Bool {
        didSet { defaults.set(showAllFonts, forKey: "showAllFonts") }
    }

    /// 「源代码管理」里被折叠的分区（"conflicted"/"staged"/"unstaged"/"stash"）。
    /// 持久化：折叠一次（如收起贮藏）后长期生效，不必每次重折。
    @Published var collapsedChangeSections: Set<String> {
        didSet { defaults.set(Array(collapsedChangeSections), forKey: "collapsedChangeSections") }
    }

    private init() {
        let saved = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        language = saved
        launchLanguage = saved
        editorFontName = defaults.string(forKey: "editorFontName") ?? "SF Mono"
        let size = defaults.double(forKey: "editorFontSize")
        editorFontSize = size > 0 ? size : 13
        themeID = defaults.string(forKey: "themeID") ?? "system"
        iconThemeID = defaults.string(forKey: "iconThemeID") ?? ""
        splitDiff = defaults.object(forKey: "splitDiff") as? Bool ?? true  // 默认左右分栏比对
        fileTreeStyle = FileTreeStyle(rawValue: defaults.string(forKey: "fileTreeStyle") ?? "") ?? .mergedTree
        let lineHeight = defaults.double(forKey: "editorLineHeight")
        editorLineHeight = lineHeight > 0 ? lineHeight : 1.3
        showAllFonts = defaults.bool(forKey: "showAllFonts")
        collapsedChangeSections = Set(defaults.stringArray(forKey: "collapsedChangeSections") ?? [])
    }

    /// 恢复编辑器 / 视图相关设置为默认（不动语言、主题、图标——那些是有意的选择）。
    func restoreDefaults() {
        editorFontName = "SF Mono"
        editorFontSize = 13
        editorLineHeight = 1.3
        showAllFonts = false
        fileTreeStyle = .mergedTree
        splitDiff = true
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

    /// 顶部菜单栏（文件/编辑/窗口…与系统标准项）由 AppKit 按应用语言加载，
    /// 需写入本应用域的 AppleLanguages，重启后生效。
    private func syncSystemLanguage() {
        switch language {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .zhHans: defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english: defaults.set(["en"], forKey: "AppleLanguages")
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

    /// 系统上全部字体族（字体选择器开启「显示全部」时用）。
    static var allFontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }
}

// MARK: - 重启应用

/// 重新启动应用（语言切换后让系统菜单生效）。
enum AppRelaunch {
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            // 先退出再拉起：open 对已退出的应用会启动新实例
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 0.3; /usr/bin/open \"\(bundlePath)\""]
            try? task.run()
        }
        NSApp.terminate(nil)
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
