import XCTest
@testable import HunkCore

final class GraphBuilderTests: XCTestCase {

    private func commit(_ hash: String, parents: [String], refs: [String] = []) -> GraphCommit {
        GraphCommit(hash: hash, shortHash: String(hash.prefix(7)), parents: parents,
                    author: "T", subject: hash, date: Date(timeIntervalSince1970: 0), refs: refs)
    }

    /// 线性历史：全部在第 0 列，首尾 stub 正确。
    func testLinearHistory() {
        let result = GraphBuilder.rows(from: [
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(result.maxColumns, 1)
        XCTAssertEqual(result.rows.map(\.column), [0, 0, 0])
        XCTAssertFalse(result.rows[0].hasTopStub)
        XCTAssertTrue(result.rows[0].hasBottomStub)
        XCTAssertTrue(result.rows[1].hasTopStub)
        XCTAssertTrue(result.rows[2].hasTopStub)
        XCTAssertFalse(result.rows[2].hasBottomStub)
        XCTAssertTrue(result.rows.allSatisfy { $0.joinColumns.isEmpty && $0.forkColumns.isEmpty })
    }

    /// 合并提交：m 的第二父开新列，f 在第 1 列，最终汇回第 0 列。
    func testMergeOpensSecondLane() {
        // 历史（新→旧）：m 合并 f；m 的父 = [b, f]，f 的父 = [a]，b 的父 = [a]
        let result = GraphBuilder.rows(from: [
            commit("m", parents: ["b", "f"]),
            commit("f", parents: ["a"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(result.maxColumns, 2)

        let m = result.rows[0]
        XCTAssertEqual(m.column, 0)
        XCTAssertEqual(m.forkColumns, [1], "第二父应分到第 1 列")

        let f = result.rows[1]
        XCTAssertEqual(f.column, 1)

        // b 的首父 a 已被 f 的泳道（第 1 列）等待：b 汇入该列，自身泳道结束
        let b = result.rows[2]
        XCTAssertEqual(b.column, 0)
        XCTAssertEqual(b.forkColumns, [1])
        XCTAssertFalse(b.hasBottomStub)

        // a 落在存续的第 1 列，上方有延续线
        let a = result.rows[3]
        XCTAssertEqual(a.column, 1)
        XCTAssertTrue(a.hasTopStub)
        XCTAssertFalse(a.hasBottomStub)
    }

    /// 单文件历史（人工串链）：单列直线。
    func testChainedSingleLane() {
        let result = GraphBuilder.rows(from: [
            commit("y", parents: ["x"]),
            commit("x", parents: []),
        ])
        XCTAssertEqual(result.maxColumns, 1)
        XCTAssertEqual(result.rows.map(\.column), [0, 0])
    }
}
