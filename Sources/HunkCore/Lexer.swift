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
        switch name {
        case "Makefile", "makefile": return languages["sh"]
        case "Dockerfile": return languages["sh"]
        default: return nil
        }
    }

    private static let cFamilyKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
        "register", "return", "short", "signed", "sizeof", "static", "struct", "switch",
        "typedef", "union", "unsigned", "void", "volatile", "while", "class", "namespace",
        "template", "typename", "public", "private", "protected", "virtual", "override",
        "new", "delete", "this", "nullptr", "true", "false", "using", "constexpr", "noexcept",
        "operator", "friend", "explicit", "mutable", "thread_local", "static_cast",
        "dynamic_cast", "reinterpret_cast", "const_cast", "try", "catch", "throw",
        "@interface", "@implementation", "@property", "@end", "id", "self", "nil", "YES", "NO",
    ]

    private static let languages: [String: LanguageDef] = {
        var map: [String: LanguageDef] = [:]

        let swift = LanguageDef(
            name: "Swift",
            keywords: [
                "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                "func", "import", "init", "inout", "internal", "let", "open", "operator",
                "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
                "typealias", "var", "break", "case", "continue", "default", "defer", "do",
                "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
                "switch", "where", "while", "as", "any", "catch", "false", "is", "nil",
                "super", "self", "Self", "throw", "throws", "true", "try", "await", "async",
                "actor", "some", "lazy", "weak", "unowned", "mutating", "nonmutating",
                "override", "required", "convenience", "final", "indirect", "macro",
            ],
            capitalizedTypes: true
        )
        map["swift"] = swift

        let jsTS = LanguageDef(
            name: "JavaScript/TypeScript",
            keywords: [
                "abstract", "any", "as", "async", "await", "boolean", "break", "case",
                "catch", "class", "const", "continue", "debugger", "declare", "default",
                "delete", "do", "else", "enum", "export", "extends", "false", "finally",
                "for", "from", "function", "get", "if", "implements", "import", "in",
                "instanceof", "interface", "is", "keyof", "let", "namespace", "never",
                "new", "null", "number", "object", "of", "package", "private", "protected",
                "public", "readonly", "return", "set", "static", "string", "super",
                "switch", "symbol", "this", "throw", "true", "try", "type", "typeof",
                "undefined", "unique", "unknown", "var", "void", "while", "with", "yield",
            ],
            stringDelimiters: ["\"", "'", "`"],
            capitalizedTypes: true
        )
        map["js"] = jsTS
        map["jsx"] = jsTS
        map["ts"] = jsTS
        map["tsx"] = jsTS
        map["mjs"] = jsTS
        map["cjs"] = jsTS

        let python = LanguageDef(
            name: "Python",
            keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue",
                "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
                "raise", "return", "try", "while", "with", "yield", "True", "False",
                "None", "self", "match", "case",
            ],
            lineComments: ["#"],
            blockCommentStart: nil, blockCommentEnd: nil,
            capitalizedTypes: true
        )
        map["py"] = python

        let ruby = LanguageDef(
            name: "Ruby",
            keywords: [
                "alias", "and", "begin", "break", "case", "class", "def", "defined?",
                "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
                "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return",
                "self", "super", "then", "true", "undef", "unless", "until", "when",
                "while", "yield", "require", "require_relative", "attr_accessor",
                "attr_reader", "attr_writer", "puts", "raise", "lambda", "proc",
            ],
            lineComments: ["#"],
            blockCommentStart: nil, blockCommentEnd: nil,
            capitalizedTypes: true
        )
        map["rb"] = ruby

        let go = LanguageDef(
            name: "Go",
            keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
                "map", "package", "range", "return", "select", "struct", "switch", "type",
                "var", "nil", "true", "false", "iota", "make", "new", "append", "len",
                "cap", "copy", "delete", "panic", "recover", "error", "string", "int",
                "int8", "int16", "int32", "int64", "uint", "byte", "rune", "float32",
                "float64", "bool", "any",
            ],
            stringDelimiters: ["\"", "'", "`"]
        )
        map["go"] = go

        let rust = LanguageDef(
            name: "Rust",
            keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn",
                "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
                "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                "self", "Self", "static", "struct", "super", "trait", "true", "type",
                "unsafe", "use", "where", "while", "macro_rules", "u8", "u16", "u32",
                "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "bool",
                "char", "str", "String", "Vec", "Option", "Result", "Some", "None", "Ok", "Err",
            ],
            capitalizedTypes: true
        )
        map["rs"] = rust

        let java = LanguageDef(
            name: "Java/Kotlin",
            keywords: [
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
                "class", "const", "continue", "default", "do", "double", "else", "enum",
                "extends", "final", "finally", "float", "for", "if", "implements",
                "import", "instanceof", "int", "interface", "long", "native", "new",
                "package", "private", "protected", "public", "return", "short", "static",
                "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
                "transient", "try", "void", "volatile", "while", "true", "false", "null",
                "var", "val", "fun", "when", "object", "companion", "data", "sealed",
                "suspend", "lateinit", "by", "is", "in", "out", "override", "open",
                "internal", "inline", "reified", "crossinline", "noinline",
            ],
            capitalizedTypes: true
        )
        map["java"] = java
        map["kt"] = java
        map["kts"] = java
        map["scala"] = java
        map["groovy"] = java
        map["dart"] = java

        let cFamily = LanguageDef(name: "C/C++/Objective-C", keywords: cFamilyKeywords, capitalizedTypes: true)
        map["c"] = cFamily
        map["h"] = cFamily
        map["cpp"] = cFamily
        map["cc"] = cFamily
        map["cxx"] = cFamily
        map["hpp"] = cFamily
        map["hh"] = cFamily
        map["m"] = cFamily
        map["mm"] = cFamily

        let csharp = LanguageDef(
            name: "C#",
            keywords: cFamilyKeywords.union([
                "abstract", "async", "await", "base", "bool", "byte", "checked", "decimal",
                "delegate", "event", "fixed", "foreach", "implicit", "internal", "is",
                "lock", "object", "out", "params", "readonly", "ref", "sbyte", "sealed",
                "stackalloc", "string", "uint", "ulong", "unchecked", "unsafe", "ushort",
                "var", "virtual", "where", "yield", "record", "init", "nameof", "null",
            ]),
            capitalizedTypes: true
        )
        map["cs"] = csharp

        let php = LanguageDef(
            name: "PHP",
            keywords: [
                "abstract", "and", "array", "as", "break", "callable", "case", "catch",
                "class", "clone", "const", "continue", "declare", "default", "do", "echo",
                "else", "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif",
                "endswitch", "endwhile", "enum", "extends", "final", "finally", "fn",
                "for", "foreach", "function", "global", "goto", "if", "implements",
                "include", "include_once", "instanceof", "insteadof", "interface", "isset",
                "list", "match", "namespace", "new", "or", "print", "private", "protected",
                "public", "readonly", "require", "require_once", "return", "static",
                "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor",
                "yield", "true", "false", "null", "this", "self", "parent",
            ],
            lineComments: ["//", "#"],
            capitalizedTypes: true
        )
        map["php"] = php

        let shell = LanguageDef(
            name: "Shell",
            keywords: [
                "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
                "until", "do", "done", "in", "function", "select", "time", "break",
                "continue", "return", "exit", "export", "local", "readonly", "declare",
                "unset", "shift", "source", "alias", "echo", "printf", "read", "cd",
                "set", "trap", "eval", "exec", "true", "false", "test",
            ],
            lineComments: ["#"],
            blockCommentStart: nil, blockCommentEnd: nil
        )
        map["sh"] = shell
        map["bash"] = shell
        map["zsh"] = shell
        map["fish"] = shell

        let yaml = LanguageDef(
            name: "YAML",
            keywords: ["true", "false", "null", "yes", "no", "on", "off"],
            lineComments: ["#"],
            blockCommentStart: nil, blockCommentEnd: nil
        )
        map["yaml"] = yaml
        map["yml"] = yaml
        map["toml"] = yaml
        map["ini"] = LanguageDef(
            name: "INI", keywords: [],
            lineComments: ["#", ";"],
            blockCommentStart: nil, blockCommentEnd: nil
        )

        map["json"] = LanguageDef(
            name: "JSON",
            keywords: ["true", "false", "null"],
            lineComments: ["//"],  // 容忍 JSONC
            stringDelimiters: ["\""]
        )
        map["jsonc"] = map["json"]

        let markup = LanguageDef(
            name: "HTML/XML",
            keywords: [],
            lineComments: [],
            blockCommentStart: "<!--", blockCommentEnd: "-->"
        )
        map["html"] = markup
        map["htm"] = markup
        map["xml"] = markup
        map["svg"] = markup
        map["plist"] = markup
        map["vue"] = markup
        map["svelte"] = markup

        map["css"] = LanguageDef(
            name: "CSS",
            keywords: ["important", "inherit", "initial", "unset", "auto", "none"],
            lineComments: []
        )
        map["scss"] = LanguageDef(
            name: "SCSS",
            keywords: ["important", "inherit", "mixin", "include", "extend", "if", "else", "for", "each", "while", "function", "return", "use", "forward"],
            lineComments: ["//"]
        )
        map["less"] = map["scss"]

        let markdown = LanguageDef(
            name: "Markdown",
            keywords: [],
            lineComments: [],
            blockCommentStart: nil, blockCommentEnd: nil,
            stringDelimiters: []
        )
        map["md"] = markdown
        map["markdown"] = markdown
        map["rst"] = markdown

        map["sql"] = LanguageDef(
            name: "SQL",
            keywords: [
                "select", "from", "where", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "index", "view", "drop", "alter", "add",
                "join", "inner", "left", "right", "outer", "full", "on", "as", "and",
                "or", "not", "null", "is", "in", "like", "between", "order", "by",
                "group", "having", "limit", "offset", "distinct", "union", "all",
                "exists", "case", "when", "then", "else", "end", "primary", "key",
                "foreign", "references", "default", "constraint", "unique", "begin",
                "commit", "rollback", "transaction",
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                "DELETE", "CREATE", "TABLE", "INDEX", "VIEW", "DROP", "ALTER", "ADD",
                "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "FULL", "ON", "AS", "AND",
                "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "ORDER", "BY",
                "GROUP", "HAVING", "LIMIT", "OFFSET", "DISTINCT", "UNION", "ALL",
                "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END", "PRIMARY", "KEY",
                "FOREIGN", "REFERENCES", "DEFAULT", "CONSTRAINT", "UNIQUE", "BEGIN",
                "COMMIT", "ROLLBACK", "TRANSACTION",
            ],
            lineComments: ["--"]
        )

        return map
    }()
}
