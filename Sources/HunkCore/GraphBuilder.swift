import Foundation

/// 历史图中的一个提交（含父指针，供泳道布局）。
public struct GraphCommit: Identifiable, Hashable, Sendable {
    public let hash: String
    public let shortHash: String
    public let parents: [String]
    public let author: String
    public let subject: String
    public let date: Date
    public let refs: [String]
    public var id: String { hash }

    public init(hash: String, shortHash: String, parents: [String], author: String,
                subject: String, date: Date, refs: [String]) {
        self.hash = hash
        self.shortHash = shortHash
        self.parents = parents
        self.author = author
        self.subject = subject
        self.date = date
        self.refs = refs
    }
}

/// 一行的图形布局：提交点所在列 + 各类连线。
/// 行高对半划分：上半段连「上一行底缘」，下半段连「下一行顶缘」。
public struct GraphRow: Identifiable, Hashable, Sendable {
    public let commit: GraphCommit
    /// 提交圆点所在列
    public let column: Int
    /// 整行贯穿的竖线列（上下都有延续、与本提交无关）
    public let throughColumns: [Int]
    /// 上半段并入圆点的列（这些分支的下一个提交就是本提交）
    public let joinColumns: [Int]
    /// 下半段从圆点分出的列（合并提交的其他父、或汇入既有分支）
    public let forkColumns: [Int]
    /// 圆点上方是否有竖线（不是分支 tip）
    public let hasTopStub: Bool
    /// 圆点下方是否有竖线（第一父在同列延续）
    public let hasBottomStub: Bool
    public var id: String { commit.hash }
}

/// 经典泳道分配：自上而下扫描，每列记录「正在等待的提交」。
public enum GraphBuilder {

    public static func rows(from commits: [GraphCommit]) -> (rows: [GraphRow], maxColumns: Int) {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        var maxColumns = 1

        for commit in commits {
            let snapshot = lanes

            // 1. 等待本提交的列：第一个作为圆点列，其余并入
            let waiting = lanes.indices.filter { lanes[$0] == commit.hash }
            let column: Int
            if let first = waiting.first {
                column = first
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                column = free
            } else {
                column = lanes.count
                lanes.append(nil)
            }
            let joins = Array(waiting.dropFirst())
            for index in joins { lanes[index] = nil }

            // 2. 分配父提交
            var forks: [Int] = []
            var hasBottomStub = false
            var parents = commit.parents
            if parents.isEmpty {
                lanes[column] = nil
            } else {
                let firstParent = parents.removeFirst()
                if let existing = lanes.indices.first(where: { $0 != column && lanes[$0] == firstParent }) {
                    // 第一父已有列在等（汇入既有分支）：本列到此为止
                    forks.append(existing)
                    lanes[column] = nil
                } else {
                    lanes[column] = firstParent
                    hasBottomStub = true
                }
                for parent in parents {
                    if let existing = lanes.indices.first(where: { lanes[$0] == parent }) {
                        if existing != column { forks.append(existing) }
                    } else if let free = lanes.indices.first(where: { lanes[$0] == nil && $0 != column }) {
                        lanes[free] = parent
                        forks.append(free)
                    } else {
                        lanes.append(parent)
                        forks.append(lanes.count - 1)
                    }
                }
            }

            // 3. 贯穿竖线：上半段有线（snapshot 非空）且下半段仍延续，且与本行事件无关
            func topActive(_ index: Int) -> Bool {
                index < snapshot.count && snapshot[index] != nil
            }
            let involved = Set([column] + joins + forks)
            let through = lanes.indices.filter {
                topActive($0) && lanes[$0] != nil && !involved.contains($0)
            }
            // fork 汇入既有列时，该列自身的竖线仍贯穿
            let forkExistingThrough = forks.filter { topActive($0) && lanes[$0] != nil }

            rows.append(GraphRow(
                commit: commit,
                column: column,
                throughColumns: through + forkExistingThrough,
                joinColumns: joins,
                forkColumns: forks,
                hasTopStub: topActive(column),
                hasBottomStub: hasBottomStub
            ))
            maxColumns = max(maxColumns, lanes.count, snapshot.count, column + 1)
        }
        return (rows, maxColumns)
    }
}
