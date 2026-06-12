import Foundation

public enum DiffLineKind: Hashable, Sendable {
    case context
    case addition
    case deletion
}

public struct DiffLine: Identifiable, Hashable, Sendable {
    /// 在整个 FileDiff 内的序号，行级暂存用它标识选中行。
    public let id: Int
    public let kind: DiffLineKind
    /// 不含 +/-/空格前缀的行内容。
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    public var noNewline: Bool

    public init(id: Int, kind: DiffLineKind, text: String, oldNumber: Int?, newNumber: Int?, noNewline: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.noNewline = noNewline
    }
}

public struct DiffHunk: Identifiable, Hashable, Sendable {
    public let id: Int
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// `@@ ... @@` 之后的上下文提示（函数名等）。
    public let sectionHeading: String
    public var lines: [DiffLine]

    public init(id: Int, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, sectionHeading: String, lines: [DiffLine] = []) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionHeading = sectionHeading
        self.lines = lines
    }

    public var changedLineIDs: [Int] {
        lines.filter { $0.kind != .context }.map(\.id)
    }
}

public struct FileDiff: Hashable, Sendable {
    public var oldPath: String?
    public var newPath: String?
    public var isNew = false
    public var isDeleted = false
    public var isBinary = false
    public var hunks: [DiffHunk] = []

    public init() {}

    public var path: String { newPath ?? oldPath ?? "" }
    public var isRename: Bool {
        if let o = oldPath, let n = newPath { return o != n }
        return false
    }

    public var changedLineIDs: [Int] {
        hunks.flatMap(\.changedLineIDs)
    }

    public var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
    }
}

/// 分栏视图中的一行：左侧（旧）与右侧（新）配对。
public struct SplitRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let left: DiffLine?
    public let right: DiffLine?

    public init(id: Int, left: DiffLine?, right: DiffLine?) {
        self.id = id
        self.left = left
        self.right = right
    }
}

extension DiffHunk {
    /// 把 hunk 内连续的删除串与新增串逐行配对，供左右分栏渲染。
    public var splitRows: [SplitRow] {
        var rows: [SplitRow] = []
        var rowID = 0
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []

        func flushPairs() {
            let count = max(deletions.count, additions.count)
            for k in 0..<count {
                rows.append(SplitRow(
                    id: rowID,
                    left: k < deletions.count ? deletions[k] : nil,
                    right: k < additions.count ? additions[k] : nil
                ))
                rowID += 1
            }
            deletions.removeAll()
            additions.removeAll()
        }

        for line in lines {
            switch line.kind {
            case .deletion:
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .context:
                flushPairs()
                rows.append(SplitRow(id: rowID, left: line, right: line))
                rowID += 1
            }
        }
        flushPairs()
        return rows
    }
}
