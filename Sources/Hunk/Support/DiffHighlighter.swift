import SwiftUI
import HunkCore

/// diff 行语法高亮：只算可见行 + 后台线程 tokenize + 结果缓存。
///
/// 关键：`body` 不再同步 tokenize（那是卡死根源——LazyVStack 测量阶段会对子视图
/// 反复求值 body）。改为先渲染纯文本，可见行的 `.task` 异步在后台算高亮，算完更新。
/// 这样大文件也能逐行高亮，主线程永不阻塞；超长行（minified/压缩）直接降级为纯文本。
@MainActor
enum DiffHighlighter {
    /// 单行字符数超过此值不高亮（minified/压缩：tokenize 慢且无可读性收益）
    static let maxLineLength = 2000

    private static var cache: [String: AttributedString] = [:]

    /// 配色/主题变化时清缓存（缓存里存了带颜色的 AttributedString）
    static func invalidate() { cache.removeAll() }

    /// 异步高亮一行：缓存命中立即返回；否则后台 tokenize+着色后写缓存。
    /// 返回 nil 表示该用纯文本（超长行 / 该文件无对应语言）。
    static func highlight(text: String, filePath: String, settings: SettingsStore) async -> AttributedString? {
        let display = text.isEmpty ? " " : text
        guard display.count <= maxLineLength,
              let language = Lexer.language(forFileName: (filePath as NSString).lastPathComponent)
        else { return nil }

        let key = "\(settings.themeID)\u{1}\(language.name)\u{1}\(display)"
        if let cached = cache[key] { return cached }

        // 主线程快照配色，后台只做纯计算（不触碰 settings / 主线程状态）
        let colors = Dictionary(uniqueKeysWithValues:
            TokenType.allCases.map { ($0, settings.tokenColor(for: $0)) })
        let result = await Task.detached(priority: .userInitiated) {
            tokenizeAndColor(display, language: language, colors: colors)
        }.value

        if cache.count > 8000 { cache.removeAll() }  // 防无限增长
        cache[key] = result
        return result
    }

    /// 纯计算（后台线程）：tokenize + 着色。
    private nonisolated static func tokenizeAndColor(
        _ display: String, language: LanguageDef, colors: [TokenType: Color]
    ) -> AttributedString {
        var attributed = AttributedString(display)
        for token in Lexer.tokenize(display, language: language) {
            guard let stringRange = Range(token.range, in: display),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].foregroundColor = colors[token.type]
        }
        return attributed
    }
}
