import Foundation

/// VS Code 生态的主题 JSON 普遍是 JSONC（允许注释与尾逗号），
/// 解析前先做一次净化。
enum JSONC {
    static func sanitize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var chars = Array(text)
        let count = chars.count
        var i = 0
        var inString = false

        while i < count {
            let c = chars[i]
            if inString {
                result.append(c)
                if c == "\\", i + 1 < count {
                    result.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i += 1
                continue
            }
            if c == "/", i + 1 < count, chars[i + 1] == "/" {
                while i < count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, count)
                continue
            }
            result.append(c)
            i += 1
        }

        // 去掉尾逗号：`,` 后跟（空白）`}` 或 `]`
        chars = Array(result)
        var cleaned = ""
        cleaned.reserveCapacity(chars.count)
        inString = false
        i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                cleaned.append(c)
                if c == "\\", i + 1 < chars.count {
                    cleaned.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                cleaned.append(c)
                i += 1
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    i += 1
                    continue
                }
            }
            cleaned.append(c)
            i += 1
        }
        return cleaned
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let data = Data(sanitize(raw).utf8)
        return try JSONDecoder().decode(type, from: data)
    }
}
