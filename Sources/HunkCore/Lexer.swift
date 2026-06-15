import Foundation

public enum TokenType: Hashable, Sendable, CaseIterable {
    case keyword
    case string
    case comment
    case number
    case type      // 首字母大写的标识符（仅部分语言启用）
}

public struct Token: Hashable, Sendable {
    public let range: NSRange
    public let type: TokenType

    public init(range: NSRange, type: TokenType) {
        self.range = range
        self.type = type
    }
}

public struct LanguageDef: Sendable {
    public let name: String
    public let keywords: Set<String>
    public let lineComments: [String]
    public let blockCommentStart: String?
    public let blockCommentEnd: String?
    public let stringDelimiters: [Character]
    public let capitalizedTypes: Bool

    public init(
        name: String,
        keywords: Set<String>,
        lineComments: [String] = ["//"],
        blockCommentStart: String? = "/*",
        blockCommentEnd: String? = "*/",
        stringDelimiters: [Character] = ["\"", "'"],
        capitalizedTypes: Bool = false
    ) {
        self.name = name
        self.keywords = keywords
        self.lineComments = lineComments
        self.blockCommentStart = blockCommentStart
        self.blockCommentEnd = blockCommentEnd
        self.stringDelimiters = stringDelimiters
        self.capitalizedTypes = capitalizedTypes
    }
}

/// 轻量通用词法着色器：识别注释 / 字符串 / 数字 / 关键字 / 类型名。
/// 不追求语法精确，追求零依赖与足够好的观感。
public enum Lexer {

    public static func tokenize(_ text: String, language: LanguageDef) -> [Token] {
        if language.name == "Markdown" {
            return tokenizeMarkdown(text)
        }
        var tokens: [Token] = []
        let chars = Array(text.utf16)
        let scalars = Array(text)  // 按 Character 扫描，utf16 偏移单独累计
        _ = chars

        var utf16Offset = 0
        var i = 0
        var guardI = -1  // 上一轮的扫描位置，用于死循环防御（见循环顶部）
        let count = scalars.count

        func utf16Length(_ c: Character) -> Int { String(c).utf16.count }

        func matches(_ literal: String, at index: Int) -> Bool {
            let lit = Array(literal)
            guard index + lit.count <= count else { return false }
            for k in 0..<lit.count where scalars[index + k] != lit[k] { return false }
            return true
        }

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < count {
            // 死循环防御：上一轮处理后扫描位置没有前进（语言规则 bug / 病态输入）→
            // 强制吃掉一个字符再继续。保证 i 严格递增 ⇒ 循环至多 count 轮、token 数
            // ≤ 字符数，杜绝「i 不动 → 无限 append」（曾因此让单行 [Token] 涨到
            // 数百 MB 触发 OOM）。
            if i == guardI {
                utf16Offset += utf16Length(scalars[i])
                i += 1
                continue
            }
            guardI = i

            let c = scalars[i]

            // 行注释
            if let comment = language.lineComments.first(where: { matches($0, at: i) }) {
                // SQL 的 "--" 不能吞掉 "-->" 之类；简单处理即可
                _ = comment
                let start = utf16Offset
                while i < count, scalars[i] != "\n" {
                    utf16Offset += utf16Length(scalars[i])
                    i += 1
                }
                tokens.append(Token(range: NSRange(location: start, length: utf16Offset - start), type: .comment))
                continue
            }

            // 块注释
            if let bcStart = language.blockCommentStart,
               let bcEnd = language.blockCommentEnd,
               matches(bcStart, at: i) {
                let start = utf16Offset
                var k = i + bcStart.count
                utf16Offset += bcStart.utf16.count
                while k < count, !matches(bcEnd, at: k) {
                    utf16Offset += utf16Length(scalars[k])
                    k += 1
                }
                if k < count {
                    utf16Offset += bcEnd.utf16.count
                    k += bcEnd.count
                }
                i = k
                tokens.append(Token(range: NSRange(location: start, length: utf16Offset - start), type: .comment))
                continue
            }

            // 字符串（同行终止；遇换行视为结束，避免错误状态蔓延）
            if language.stringDelimiters.contains(c) {
                let delimiter = c
                let start = utf16Offset
                utf16Offset += utf16Length(c)
                i += 1
                while i < count {
                    let s = scalars[i]
                    if s == "\\", i + 1 < count {
                        utf16Offset += utf16Length(s) + utf16Length(scalars[i + 1])
                        i += 2
                        continue
                    }
                    if s == "\n" { break }
                    utf16Offset += utf16Length(s)
                    i += 1
                    if s == delimiter { break }
                }
                tokens.append(Token(range: NSRange(location: start, length: utf16Offset - start), type: .string))
                continue
            }

            // 数字
            if c.isNumber, i == 0 || !isWordChar(scalars[i - 1]) {
                let start = utf16Offset
                while i < count {
                    let s = scalars[i]
                    let isNumberChar = s.isHexDigit || s == "." || s == "_"
                        || s == "x" || s == "X" || s == "o" || s == "O"
                        || s == "b" || s == "p" || s == "P" || s == "e" || s == "E"
                    guard isNumberChar else { break }
                    utf16Offset += utf16Length(s)
                    i += 1
                }
                tokens.append(Token(range: NSRange(location: start, length: utf16Offset - start), type: .number))
                continue
            }

            // 标识符 / 关键字 / 类型名
            if c.isLetter || c == "_" {
                let start = utf16Offset
                var word = ""
                while i < count, isWordChar(scalars[i]) {
                    word.append(scalars[i])
                    utf16Offset += utf16Length(scalars[i])
                    i += 1
                }
                if language.keywords.contains(word) {
                    tokens.append(Token(range: NSRange(location: start, length: utf16Offset - start), type: .keyword))
                } else if language.capitalizedTypes, let first = word.first, first.isUppercase {
                    tokens.append(Token(range: NSRange(location: start, length: utf16Offset - start), type: .type))
                }
                continue
            }

            utf16Offset += utf16Length(c)
            i += 1
        }
        return tokens
    }

    // MARK: - Markdown（按行 + 行内标记）

    private static func tokenizeMarkdown(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let nsString = text as NSString
        var location = 0
        var inFence = false

        while location < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
            var contentLength = lineRange.length
            if contentLength > 0, nsString.character(at: NSMaxRange(lineRange) - 1) == 0x0A {
                contentLength -= 1
            }
            let contentRange = NSRange(location: lineRange.location, length: contentLength)
            let line = nsString.substring(with: contentRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                tokens.append(Token(range: contentRange, type: .string))
            } else if inFence {
                tokens.append(Token(range: contentRange, type: .string))
            } else if trimmed.hasPrefix("#") {
                tokens.append(Token(range: contentRange, type: .keyword))
            } else if trimmed.hasPrefix(">") {
                tokens.append(Token(range: contentRange, type: .comment))
            } else {
                tokens += markdownInlineTokens(line, offset: contentRange.location)
            }
            location = NSMaxRange(lineRange)
        }
        return tokens
    }

    private static func markdownInlineTokens(_ line: String, offset: Int) -> [Token] {
        var tokens: [Token] = []

        func append(_ pattern: some RegexComponent, _ type: TokenType) {
            for match in line.matches(of: pattern) {
                let nsRange = NSRange(match.range, in: line)
                tokens.append(Token(range: NSRange(location: offset + nsRange.location, length: nsRange.length), type: type))
            }
        }

        append(#/`[^`]+`/#, .string)                  // 行内代码
        append(#/\*\*[^*]+\*\*/#, .type)              // 加粗
        append(#/\[[^\]]+\]\([^)]+\)/#, .number)      // 链接
        append(#/^\s*(?:[-*+]|\d+\.)\s/#, .keyword)   // 列表标记
        append(#/^\s*(?:-{3,}|={3,})\s*$/#, .comment) // 分隔线 / Setext 下划线
        return tokens
    }

    // MARK: - 语言注册表

    public static func language(forFileExtension ext: String) -> LanguageDef? {
        languages[ext.lowercased()]
    }

    public static func language(forFileName name: String) -> LanguageDef? {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let lang = language(forFileExtension: ext) { return lang }
        // 按完整文件名映射（Makefile / Dockerfile / Gemfile …），表见 languages.json
        if let mapped = filenameMap[name], let lang = languages[mapped] { return lang }
        return nil
    }

    // MARK: - 数据驱动的语言表（Resources/languages.json）

    /// 语言数据外置在 json：新增/修正语言只改数据、不动引擎。加载失败（资源缺失/
    /// 损坏）→ 返回空表，高亮降级为纯文本，绝不崩。
    private struct LanguagesDoc: Decodable {
        let filenames: [String: String]
        let languages: [LangDTO]
    }

    private struct LangDTO: Decodable {
        let name: String
        let extensions: [String]
        let keywords: [String]
        let lineComments: [String]?
        let blockComment: [String]?       // [start, end]
        let stringDelimiters: [String]?
        let capitalizedTypes: Bool?

        func toDef() -> LanguageDef {
            LanguageDef(
                name: name,
                keywords: Set(keywords),
                lineComments: lineComments ?? [],
                blockCommentStart: blockComment?.first,
                blockCommentEnd: (blockComment?.count ?? 0) >= 2 ? blockComment?[1] : nil,
                stringDelimiters: (stringDelimiters ?? ["\"", "'"]).compactMap(\.first),
                capitalizedTypes: capitalizedTypes ?? false
            )
        }
    }

    private static let registry: (byExtension: [String: LanguageDef], byFilename: [String: String]) = {
        guard let url = Bundle.module.url(forResource: "languages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(LanguagesDoc.self, from: data)
        else { return ([:], [:]) }
        var map: [String: LanguageDef] = [:]
        for dto in doc.languages {
            let def = dto.toDef()
            for ext in dto.extensions { map[ext.lowercased()] = def }
        }
        return (map, doc.filenames)
    }()

    private static var languages: [String: LanguageDef] { registry.byExtension }
    private static var filenameMap: [String: String] { registry.byFilename }

    /// 已加载的语言扩展名数量（0 表示 languages.json 没加载到——资源缺失或打包漏拷 bundle）。
    public static var loadedExtensionCount: Int { registry.byExtension.count }
}
