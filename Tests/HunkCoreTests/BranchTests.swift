import XCTest
@testable import HunkCore

/// 用真实临时仓库验证分支合并标记与已合并分支清理。
final class BranchIntegrationTests: XCTestCase {
    var dir: URL!
    var git: GitClient!
    var repo: Repository!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunk-branch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        git = GitClient(workDirectory: dir)
        try await git.run(["init", "-b", "main"])
        repo = Repository(root: dir)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func write(_ name: String, _ content: String) throws {
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commitAll(_ message: String) async throws {
        try await git.run(["add", "--all"])
        try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", message])
    }

    /// merged 分支已并入 main，unmerged 分支有独立提交。
    private func makeBranches() async throws {
        try write("a.txt", "1\n")
        try await commitAll("init")

        // 已合并的分支：在其上提交后并回 main
        try await git.run(["checkout", "-q", "-b", "merged"])
        try write("b.txt", "2\n")
        try await commitAll("merged work")
        try await git.run(["checkout", "-q", "main"])
        try await git.run(["merge", "-q", "--no-edit", "merged"])

        // 未合并的分支：有 main 不可达的提交
        try await git.run(["checkout", "-q", "-b", "unmerged"])
        try write("c.txt", "3\n")
        try await commitAll("unmerged work")
        try await git.run(["checkout", "-q", "main"])
    }

    func testBranchesCarryMergedFlag() async throws {
        try await makeBranches()
        let branches = try await repo.branches()
        let byName = Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0) })

        XCTAssertEqual(byName["merged"]?.isMerged, true)
        XCTAssertEqual(byName["unmerged"]?.isMerged, false)
        XCTAssertEqual(byName["main"]?.isCurrent, true)
    }

    func testMergedBranchesExcludesCurrentAndProtected() async throws {
        try await makeBranches()
        let merged = try await repo.mergedBranches()
        // main 是当前分支且受保护，不应出现；unmerged 未合并
        XCTAssertEqual(merged, ["merged"])
    }

    func testDeleteBranchRemovesMergedOnly() async throws {
        try await makeBranches()
        try await repo.deleteBranch("merged")
        let names = try await repo.branches().map(\.name)
        XCTAssertFalse(names.contains("merged"))

        // 未合并的分支 -d 删除应失败（git 拒绝）
        do {
            try await repo.deleteBranch("unmerged")
            XCTFail("未合并分支不应能用 -d 删除")
        } catch {
            // 预期失败
        }
        let remaining = try await repo.branches().map(\.name)
        XCTAssertTrue(remaining.contains("unmerged"))
    }
}
