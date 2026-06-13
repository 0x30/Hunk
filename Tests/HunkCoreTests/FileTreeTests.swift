import XCTest
@testable import HunkCore

final class FileTreeTests: XCTestCase {
    /// 单子目录链合并 + 全展开拍平：目录在前、深度正确。
    func testFlattenMergesSingleChildChains() {
        let nodes = FileTreeBuilder.build(paths: [
            "a/b/c/file1.txt",
            "a/b/c/file2.txt",
            "top.txt",
        ])
        let rows = FileTreeBuilder.flattenMergingChains(nodes)

        XCTAssertEqual(rows.map(\.displayName), ["a/b/c", "file1.txt", "file2.txt", "top.txt"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertTrue(rows[0].node.isDirectory)
    }

    /// 折叠目录后跳过其子树，目录行本身保留。
    func testFlattenSkipsCollapsedSubtrees() {
        let nodes = FileTreeBuilder.build(paths: [
            "a/b/c/file1.txt",
            "a/b/c/file2.txt",
            "top.txt",
        ])
        let rows = FileTreeBuilder.flattenMergingChains(nodes, collapsed: ["a/b/c"])

        XCTAssertEqual(rows.map(\.displayName), ["a/b/c", "top.txt"])
    }

    /// 多子项的目录不合并链。
    func testFlattenKeepsBranchingDirectories() {
        let nodes = FileTreeBuilder.build(paths: [
            "src/a.swift",
            "src/sub/b.swift",
        ])
        let rows = FileTreeBuilder.flattenMergingChains(nodes)

        // src 下既有目录又有文件：目录在前
        XCTAssertEqual(rows.map(\.displayName), ["src", "sub", "b.swift", "a.swift"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1])
    }
}
