import Foundation

/// 解析 `git status --porcelain -z` 的输出。
public enum StatusParser {
    public static func parse(_ data: Data) -> [FileChange] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }

        var result: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let entry = tokens[i]
            i += 1
            guard entry.count >= 4 else { continue }

            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))

            // 重命名/复制条目后面跟一个旧路径 token
            var oldPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i < tokens.count {
                    oldPath = tokens[i]
                    i += 1
                }
            }

            if x == "?" && y == "?" {
                result.append(FileChange(path: path, staged: nil, unstaged: .untracked))
                continue
            }
            if x == "!" { continue }  // ignored

            if isConflict(x, y) {
                result.append(FileChange(path: path, oldPath: oldPath, staged: nil, unstaged: .conflicted))
                continue
            }

            let change = FileChange(path: path, oldPath: oldPath, staged: kind(x), unstaged: kind(y))
            if change.staged != nil || change.unstaged != nil {
                result.append(change)
            }
        }
        return result
    }

    private static func isConflict(_ x: Character, _ y: Character) -> Bool {
        switch (x, y) {
        case ("D", "D"), ("A", "U"), ("U", "D"), ("U", "A"), ("D", "U"), ("A", "A"), ("U", "U"):
            return true
        default:
            return false
        }
    }

    private static func kind(_ c: Character) -> ChangeKind? {
        switch c {
        case "M", "m": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return nil
        }
    }
}
