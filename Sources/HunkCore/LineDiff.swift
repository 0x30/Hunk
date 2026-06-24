import Foundation

/// 编辑器「改动标记」用的行级 diff：把基线（HEAD 版本）与当前文本比对，
/// 归并成若干 hunk，每个 hunk 标注 新增 / 修改 / 删除，并保留旧/新行文本供悬浮卡展示。
public enum LineDiff {

    public struct Hunk: Sendable, Equatable {
        public enum Kind: Sendable { case added, modified, deleted }
        public let kind: Kind
        /// 新文本中的起始行（0 基）。
        public let newStart: Int
        /// 新文本中覆盖的行数（纯删除为 0）。
        public let newCount: Int
        /// 被替换/删除的旧行文本（修改、删除时非空）。
        public let oldLines: [String]
        /// 新增/修改后的新行文本（删除时为空）。
        public let newLines: [String]

        public init(kind: Kind, newStart: Int, newCount: Int, oldLines: [String], newLines: [String]) {
            self.kind = kind
            self.newStart = newStart
            self.newCount = newCount
            self.oldLines = oldLines
            self.newLines = newLines
        }
    }

    /// 行数超过此阈值的文件跳过计算（Myers diff 是 O(ND)，超大文件不值当）。
    public static let maxLines = 50_000

    /// 计算基线 → 当前文本的改动 hunk 列表。无改动 / 文件过大返回空。
    public static func hunks(old: String, new: String) -> [Hunk] {
        // 按 "\n" 切分，保留尾随空行——与编辑器行号（换行数 + 1）一致。
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        guard oldLines != newLines else { return [] }
        guard oldLines.count <= maxLines, newLines.count <= maxLines else { return [] }

        // 标准库 Myers diff：得到旧侧被删行下标、新侧新增行下标。
        let diff = newLines.difference(from: oldLines)
        var removedOld = Set<Int>()
        var insertedNew = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedOld.insert(offset)
            case .insert(let offset, _, _): insertedNew.insert(offset)
            }
        }
        guard !removedOld.isEmpty || !insertedNew.isEmpty else { return [] }

        // 双指针沿公共子序列对齐：非删非增的行是锚点，两侧同步前进；
        // 遇到改动块就把连续的删除（旧侧）与新增（新侧）各自吃掉，归并成一个 hunk。
        var hunks: [Hunk] = []
        var oldIdx = 0, newIdx = 0
        let oldN = oldLines.count, newN = newLines.count
        while oldIdx < oldN || newIdx < newN {
            let oldRemoved = oldIdx < oldN && removedOld.contains(oldIdx)
            let newInserted = newIdx < newN && insertedNew.contains(newIdx)
            if !oldRemoved && !newInserted {
                oldIdx += 1; newIdx += 1
                continue
            }
            let hunkNewStart = newIdx
            let hunkOldStart = oldIdx
            while oldIdx < oldN && removedOld.contains(oldIdx) { oldIdx += 1 }
            while newIdx < newN && insertedNew.contains(newIdx) { newIdx += 1 }
            let oldSlice = Array(oldLines[hunkOldStart..<oldIdx])
            let newSlice = Array(newLines[hunkNewStart..<newIdx])
            let kind: Hunk.Kind
            if oldSlice.isEmpty { kind = .added }
            else if newSlice.isEmpty { kind = .deleted }
            else { kind = .modified }
            hunks.append(Hunk(
                kind: kind,
                newStart: hunkNewStart,
                newCount: newSlice.count,
                oldLines: oldSlice,
                newLines: newSlice
            ))
        }
        return hunks
    }
}
