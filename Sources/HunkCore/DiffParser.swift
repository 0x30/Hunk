import Foundation

/// 解析 unified diff（`git diff` 输出），支持一次输出多个文件。
public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var diffs: [FileDiff] = []
        var current: FileDiff?
        var hunks: [DiffHunk] = []
        var hunkLines: [DiffLine] = []
        var hunkMeta: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)?
        var lineID = 0
        var hunkID = 0
        var oldNumber = 0
        var newNumber = 0

        func flushHunk() {
            guard let meta = hunkMeta else { return }
            hunks.append(DiffHunk(
                id: hunkID,
                oldStart: meta.oldStart, oldCount: meta.oldCount,
                newStart: meta.newStart, newCount: meta.newCount,
                sectionHeading: meta.heading,
                lines: hunkLines
            ))
            hunkID += 1
            hunkLines = []
            hunkMeta = nil
        }

        func flushFile() {
            flushHunk()
            if var file = current {
                file.hunks = hunks
                diffs.append(file)
            }
            current = nil
            hunks = []
            hunkID = 0
            lineID = 0
        }

        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if rawLines.last == "" { rawLines.removeLast() }

        for raw in rawLines {
            if raw.hasPrefix("diff --git ") {
                flushFile()
                var file = FileDiff()
                // 从 "diff --git a/X b/Y" 提取路径；--- / +++ 行会再覆盖一次
                let rest = raw.dropFirst("diff --git ".count)
                if let range = rest.range(of: " b/", options: .backwards) {
                    var old = String(rest[..<range.lowerBound])
                    if old.hasPrefix("a/") { old.removeFirst(2) }
                    file.oldPath = old
                    file.newPath = String(rest[range.upperBound...])
                }
                current = file
                continue
            }

            guard current != nil else { continue }

            if hunkMeta == nil {
                // 文件头部区域
                if raw.hasPrefix("new file mode") {
                    current?.isNew = true
                } else if raw.hasPrefix("deleted file mode") {
                    current?.isDeleted = true
                } else if raw.hasPrefix("rename from ") {
                    current?.oldPath = String(raw.dropFirst("rename from ".count))
                } else if raw.hasPrefix("rename to ") {
                    current?.newPath = String(raw.dropFirst("rename to ".count))
                } else if raw.hasPrefix("Binary files ") || raw.hasPrefix("GIT binary patch") {
                    current?.isBinary = true
                } else if raw.hasPrefix("--- ") {
                    current?.oldPath = parsePath(String(raw.dropFirst(4)), stripping: "a/")
                } else if raw.hasPrefix("+++ ") {
                    current?.newPath = parsePath(String(raw.dropFirst(4)), stripping: "b/")
                }
            }

            if raw.hasPrefix("@@") {
                flushHunk()
                guard let meta = parseHunkHeader(raw) else { continue }
                hunkMeta = meta
                oldNumber = meta.oldStart
                newNumber = meta.newStart
                continue
            }

            guard hunkMeta != nil else { continue }

            if raw.hasPrefix("+") {
                hunkLines.append(DiffLine(id: lineID, kind: .addition, text: String(raw.dropFirst()), oldNumber: nil, newNumber: newNumber))
                lineID += 1
                newNumber += 1
            } else if raw.hasPrefix("-") {
                hunkLines.append(DiffLine(id: lineID, kind: .deletion, text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: nil))
                lineID += 1
                oldNumber += 1
            } else if raw.hasPrefix(" ") || raw.isEmpty {
                hunkLines.append(DiffLine(id: lineID, kind: .context, text: raw.isEmpty ? "" : String(raw.dropFirst()), oldNumber: oldNumber, newNumber: newNumber))
                lineID += 1
                oldNumber += 1
                newNumber += 1
            } else if raw.hasPrefix("\\") {
                // "\ No newline at end of file"
                if let last = hunkLines.indices.last {
                    hunkLines[last].noNewline = true
                }
            }
        }
        flushFile()
        return diffs
    }

    private static func parsePath(_ raw: String, stripping prefix: String) -> String? {
        var path = raw
        // "--- a/path\t" 可能带制表符尾注
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        if path == "/dev/null" { return nil }
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        return path
    }

    private static func parseHunkHeader(_ raw: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)? {
        let pattern = #/^@@+ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@+ ?(.*)$/#
        guard let match = raw.wholeMatch(of: pattern) else { return nil }
        let oldStart = Int(match.1) ?? 0
        let oldCount = match.2.flatMap { Int($0) } ?? 1
        let newStart = Int(match.3) ?? 0
        let newCount = match.4.flatMap { Int($0) } ?? 1
        return (oldStart, oldCount, newStart, newCount, String(match.5))
    }
}
