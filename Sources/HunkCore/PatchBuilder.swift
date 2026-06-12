import Foundation

/// 由「用户选中的若干行」构造可供 `git apply --cached` 使用的补丁，
/// 实现行级暂存 / 行级取消暂存。
public enum PatchBuilder {

    /// 暂存选中行。`diff` 是未暂存 diff（工作区 vs 暂存区）。
    /// 规则：未选中的 `-` 行降级为上下文（删除暂不生效），未选中的 `+` 行丢弃。
    /// 结果用 `git apply --cached` 应用。
    public static func stagePatch(diff: FileDiff, selectedLineIDs: Set<Int>) -> String? {
        build(diff: diff, selected: selectedLineIDs, demoteUnselected: .deletion)
    }

    /// 取消暂存选中行。`diff` 是已暂存 diff（暂存区 vs HEAD）。
    /// 规则：未选中的 `+` 行降级为上下文（保留在暂存区），未选中的 `-` 行丢弃。
    /// 结果用 `git apply --cached --reverse` 应用。
    public static func unstagePatch(diff: FileDiff, selectedLineIDs: Set<Int>) -> String? {
        build(diff: diff, selected: selectedLineIDs, demoteUnselected: .addition)
    }

    private static func build(diff: FileDiff, selected: Set<Int>, demoteUnselected: DiffLineKind) -> String? {
        guard !diff.isBinary, !selected.isEmpty else { return nil }
        let path = diff.path
        guard !path.isEmpty else { return nil }

        var body = ""
        var emittedHunks = 0
        var offset = 0  // 已输出 hunk 的累计行数偏移（新侧相对旧侧）

        for hunk in diff.hunks {
            guard hunk.lines.contains(where: { $0.kind != .context && selected.contains($0.id) }) else {
                continue
            }

            struct OutLine {
                let prefix: String
                let text: String
                let noNewline: Bool
            }
            var out: [OutLine] = []

            for line in hunk.lines {
                switch line.kind {
                case .context:
                    out.append(OutLine(prefix: " ", text: line.text, noNewline: line.noNewline))
                case .deletion:
                    if selected.contains(line.id) {
                        out.append(OutLine(prefix: "-", text: line.text, noNewline: line.noNewline))
                    } else if demoteUnselected == .deletion {
                        out.append(OutLine(prefix: " ", text: line.text, noNewline: line.noNewline))
                    }
                    // demoteUnselected == .addition 时（取消暂存）未选中的删除直接丢弃
                case .addition:
                    if selected.contains(line.id) {
                        out.append(OutLine(prefix: "+", text: line.text, noNewline: line.noNewline))
                    } else if demoteUnselected == .addition {
                        out.append(OutLine(prefix: " ", text: line.text, noNewline: line.noNewline))
                    }
                }
            }

            let oldCount = out.filter { $0.prefix != "+" }.count
            let newCount = out.filter { $0.prefix != "-" }.count
            let oldStart: Int
            let newStart: Int
            if demoteUnselected == .deletion {
                // 暂存方向：旧侧 = 暂存区当前内容，行号取原 hunk 的旧侧；
                // 新侧行号按已输出 hunk 的偏移推算。
                oldStart = oldCount == 0 ? hunk.oldStart - 1 : hunk.oldStart
                newStart = max(oldStart + offset, newCount == 0 ? 0 : 1)
            } else {
                // 取消暂存方向（reverse apply）：新侧 = 暂存区当前内容，行号真实可信；
                // 旧侧行号按偏移推算。
                newStart = newCount == 0 ? hunk.newStart - 1 : hunk.newStart
                oldStart = max(newStart - offset, oldCount == 0 ? 0 : 1)
            }
            offset += newCount - oldCount

            body += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for line in out {
                body += line.prefix + line.text + "\n"
                if line.noNewline {
                    body += "\\ No newline at end of file\n"
                }
            }
            emittedHunks += 1
        }

        guard emittedHunks > 0 else { return nil }

        let oldName = diff.oldPath ?? path
        var header = "diff --git a/\(oldName) b/\(path)\n"
        if diff.isNew {
            // 新增文件做部分取消暂存时文件仍留在暂存区，按普通修改处理；
            // 全选时调用方应直接走整文件 unstage。
            header += "--- a/\(path)\n"
        } else {
            header += "--- a/\(oldName)\n"
        }
        header += "+++ b/\(path)\n"
        return header + body
    }
}
