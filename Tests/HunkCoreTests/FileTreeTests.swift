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

    /// 有直接文件变化的目录正常成行，子目录嵌套其下。
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

    /// 没有直接文件变化的中间层不成行：src 只含 core/views 两个子目录时,
    /// 行直接是 "src/core" 与 "src/views"，没有单独的 src 层。
    func testFlattenDropsIntermediateDirsWithoutDirectFiles() {
        let nodes = FileTreeBuilder.build(paths: [
            "src/core/util.txt",
            "src/views/page.txt",
        ])
        let rows = FileTreeBuilder.flattenMergingChains(nodes)

        XCTAssertEqual(rows.map(\.displayName), ["src/core", "util.txt", "src/views", "page.txt"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 1])
    }
}
