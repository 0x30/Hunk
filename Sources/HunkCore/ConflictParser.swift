import Foundation

/// 文件文本中的一个合并冲突块（按行号定位，0 基）。
public struct ConflictBlock: Identifiable, Hashable, Sendable {
    public let id: Int
    /// `<<<<<<<` 标记所在行。
    public let startLine: Int
    /// `>>>>>>>` 标记所在行。
    public let endLine: Int
    /// 当前分支侧的行（`<<<<<<<` 与 `|||||||`/`=======` 之间）。
    public let currentLines: [String]
    /// 传入分支侧的行（`=======` 与 `>>>>>>>` 之间）。
    public let incomingLines: [String]
    public let currentLabel: String   // <<<<<<< 后的标签，如 HEAD
    public let incomingLabel: String  // >>>>>>> 后的标签，如分支名

    public enum Resolution: Sendable {
        case current
        case incoming
        case both
    }
}

public enum ConflictParser {
    /// 解析文本中的所有冲突块。
    public static func parse(_ text: String) -> [ConflictBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ConflictBlock] = []
        var i = 0
        var blockID = 0

        while i < lines.count {
            guard lines[i].hasPrefix("<<<<<<<") else {
                i += 1
                continue
            }
            let start = i
            let currentLabel = String(lines[i].dropFirst(7)).trimmingCharacters(in: .whitespaces)
            var current: [String] = []
            var incoming: [String] = []
            var j = i + 1
            var sawSeparator = false
            var incomingLabel = ""
            var closed = false

            scan: while j < lines.count {
                let line = lines[j]
                if line.hasPrefix("|||||||"), !sawSeparator {
                    // diff3 风格的基底段，跳到 =======
                    j += 1
                    while j < lines.count, !lines[j].hasPrefix("=======") { j += 1 }
                    continue scan
                }
                if line.hasPrefix("=======") {
                    sawSeparator = true
                } else if line.hasPrefix(">>>>>>>") {
                    incomingLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    closed = true
                    break scan
                } else if sawSeparator {
                    incoming.append(line)
                } else {
                    current.append(line)
                }
                j += 1
            }

            if closed {
                blocks.append(ConflictBlock(
                    id: blockID,
                    startLine: start,
                    endLine: j,
                    currentLines: current,
                    incomingLines: incoming,
                    currentLabel: currentLabel,
                    incomingLabel: incomingLabel
                ))
                blockID += 1
                i = j + 1
            } else {
                i += 1
            }
        }
        return blocks
    }

    /// 以指定方式解决一个冲突块，返回替换后的完整文本。
    public static func resolve(_ text: String, block: ConflictBlock, with resolution: ConflictBlock.Resolution) -> String {
        var lines = text.components(separatedBy: "\n")
        guard block.startLine < lines.count, block.endLine < lines.count else { return text }

        let replacement: [String]
        switch resolution {
        case .current: replacement = block.currentLines
        case .incoming: replacement = block.incomingLines
        case .both: replacement = block.currentLines + block.incomingLines
        }
        lines.replaceSubrange(block.startLine...block.endLine, with: replacement)
        return lines.joined(separator: "\n")
    }
}
