import Foundation

/// Markdown 智能回车产生的一次纯文本编辑。
///
/// 所有范围均使用 `NSString` / `NSTextView` 相同的 UTF-16 坐标，UI 层可直接应用。
public struct MarkdownNewlineEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let selectedRange: NSRange

    public init(range: NSRange, replacement: String, selectedRange: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selectedRange = selectedRange
    }
}

/// Markdown 列表编辑规则。保持为纯函数，避免把文本判断散落到 AppKit 委托中。
public enum MarkdownSmartNewline {
    /// 为当前光标计算智能回车编辑；不应接管系统默认回车时返回 `nil`。
    ///
    /// - Important: `selectedRange` 使用 UTF-16 坐标。非空选区不会被接管，以免改变
    ///   `NSTextView` 原生的“以换行替换选区”行为。
    public static func edit(in text: String, selectedRange: NSRange) -> MarkdownNewlineEdit? {
        let source = text as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length == 0,
              selectedRange.location <= source.length
        else { return nil }

        let caret = selectedRange.location
        let bounds = lineBounds(containing: caret, in: source)
        guard !isInsideFence(before: bounds.start, in: source) else { return nil }

        let lineRange = NSRange(location: bounds.start, length: bounds.contentEnd - bounds.start)
        let line = source.substring(with: lineRange) as NSString
        guard let item = listItem(in: line) else { return nil }

        let offsetInLine = caret - bounds.start
        // 光标落在缩进、标记或任务复选框中时交还系统，避免拆坏 Markdown 语法。
        guard offsetInLine >= item.prefixLength else { return nil }

        let contentRange = NSRange(
            location: item.prefixLength,
            length: line.length - item.prefixLength
        )
        let content = line.substring(with: contentRange)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 空列表项再次回车：去掉整项（但不吞掉已有换行），退出列表。
            return MarkdownNewlineEdit(
                range: lineRange,
                replacement: "",
                selectedRange: NSRange(location: bounds.start, length: 0)
            )
        }

        let continuation = "\n" + item.continuation
        return MarkdownNewlineEdit(
            range: selectedRange,
            replacement: continuation,
            selectedRange: NSRange(
                location: caret + (continuation as NSString).length,
                length: 0
            )
        )
    }

    private struct ListItem {
        let prefixLength: Int
        let continuation: String
    }

    private static let listPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:(\d+)([.)])|([-+*]))([ \t]+)"#
    )

    private static let taskPattern = try! NSRegularExpression(
        pattern: #"\[([ xX])\]([ \t]+)"#
    )

    private static func listItem(in line: NSString) -> ListItem? {
        let fullRange = NSRange(location: 0, length: line.length)
        guard let match = listPattern.firstMatch(in: line as String, range: fullRange),
              match.range.location == 0
        else { return nil }

        let indent = substring(match.range(at: 1), from: line)
        let orderedNumberRange = match.range(at: 2)
        let separator = substring(match.range(at: 5), from: line)

        if orderedNumberRange.location != NSNotFound {
            let number = substring(orderedNumberRange, from: line)
            let delimiter = substring(match.range(at: 3), from: line)
            return ListItem(
                prefixLength: NSMaxRange(match.range),
                continuation: indent + incrementDecimal(number) + delimiter + separator
            )
        }

        let bullet = substring(match.range(at: 4), from: line)
        let contentStart = NSMaxRange(match.range)
        let remaining = NSRange(location: contentStart, length: line.length - contentStart)
        if let task = taskPattern.firstMatch(
            in: line as String,
            options: .anchored,
            range: remaining
        ),
           task.range.location == contentStart {
            let taskSpacing = substring(task.range(at: 2), from: line)
            return ListItem(
                prefixLength: NSMaxRange(task.range),
                continuation: indent + bullet + separator + "[ ]" + taskSpacing
            )
        }

        return ListItem(
            prefixLength: contentStart,
            continuation: indent + bullet + separator
        )
    }

    private static func substring(_ range: NSRange, from source: NSString) -> String {
        guard range.location != NSNotFound else { return "" }
        return source.substring(with: range)
    }

    /// 任意长度十进制加一，避免异常长的有序列表编号触发整数溢出。
    private static func incrementDecimal(_ value: String) -> String {
        var digits = Array(value.utf8)
        var index = digits.count - 1
        while true {
            if digits[index] < 57 {
                digits[index] += 1
                break
            }
            digits[index] = 48
            if index == 0 {
                digits.insert(49, at: 0)
                break
            }
            index -= 1
        }
        return String(decoding: digits, as: UTF8.self)
    }

    private struct LineBounds {
        let start: Int
        let contentEnd: Int
    }

    private static func lineBounds(containing caret: Int, in source: NSString) -> LineBounds {
        var start = caret
        while start > 0 {
            let character = source.character(at: start - 1)
            if character == 0x0A || character == 0x0D { break }
            start -= 1
        }

        var end = caret
        while end < source.length {
            let character = source.character(at: end)
            if character == 0x0A || character == 0x0D { break }
            end += 1
        }
        return LineBounds(start: start, contentEnd: end)
    }

    private struct Fence {
        let character: unichar
        let length: Int
    }

    /// 判断当前行之前是否存在尚未闭合的 ``` / ~~~ 围栏。
    private static func isInsideFence(before lineStart: Int, in source: NSString) -> Bool {
        var openFence: Fence?
        var position = 0

        while position < lineStart {
            var contentEnd = position
            while contentEnd < lineStart {
                let character = source.character(at: contentEnd)
                if character == 0x0A || character == 0x0D { break }
                contentEnd += 1
            }

            let range = NSRange(location: position, length: contentEnd - position)
            if let candidate = fence(in: source.substring(with: range) as NSString) {
                if let currentFence = openFence {
                    if candidate.character == currentFence.character,
                       candidate.length >= currentFence.length,
                       candidate.isClosing {
                        openFence = nil
                    }
                } else {
                    openFence = Fence(character: candidate.character, length: candidate.length)
                }
            }

            position = contentEnd
            if position < lineStart, source.character(at: position) == 0x0D { position += 1 }
            if position < lineStart, source.character(at: position) == 0x0A { position += 1 }
        }
        return openFence != nil
    }

    private struct FenceCandidate {
        let character: unichar
        let length: Int
        let isClosing: Bool
    }

    private static func fence(in line: NSString) -> FenceCandidate? {
        var position = 0
        var spaces = 0
        while position < line.length, line.character(at: position) == 0x20, spaces < 4 {
            spaces += 1
            position += 1
        }
        guard spaces <= 3, position < line.length else { return nil }

        let character = line.character(at: position)
        guard character == 0x60 || character == 0x7E else { return nil } // ` 或 ~

        let start = position
        while position < line.length, line.character(at: position) == character {
            position += 1
        }
        let length = position - start
        guard length >= 3 else { return nil }

        var onlyWhitespaceAfter = true
        while position < line.length {
            let trailing = line.character(at: position)
            if trailing != 0x20 && trailing != 0x09 {
                onlyWhitespaceAfter = false
                break
            }
            position += 1
        }
        return FenceCandidate(
            character: character,
            length: length,
            isClosing: onlyWhitespaceAfter
        )
    }
}
