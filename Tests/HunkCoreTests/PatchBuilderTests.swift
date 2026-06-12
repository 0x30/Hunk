import XCTest
@testable import HunkCore

/// 用真实临时仓库做行级暂存的端到端验证。
final class PatchBuilderIntegrationTests: XCTestCase {
    var dir: URL!
    var git: GitClient!
    var repo: Repository!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunk-test-\(UUID().uuidString)")
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

    private func cachedContent(_ name: String) async throws -> String {
        try await git.run(["show", ":\(name)"]).stdout
    }

    /// 两个 hunk 各改一行，只暂存第一个 hunk 的更改。
    func testStageSelectedHunk() async throws {
        let original = (1...15).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try write("file.txt", original)
        try await commitAll("init")

        var lines = (1...15).map { "line\($0)" }
        lines[1] = "line2-CHANGED"
        lines[12] = "line13-CHANGED"
        try write("file.txt", lines.joined(separator: "\n") + "\n")

        let diff = try await repo.diff(for: "file.txt", staged: false)
        let hunks = try XCTUnwrap(diff?.hunks)
        XCTAssertEqual(hunks.count, 2, "应当产生两个独立 hunk")

        // 只选第一个 hunk 的改动行
        let selected = Set(hunks[0].changedLineIDs)
        let patch = try XCTUnwrap(PatchBuilder.stagePatch(diff: diff!, selectedLineIDs: selected))
        try await repo.applyPatch(patch, reverse: false)

        let staged = try await repo.diff(for: "file.txt", staged: true)
        let stagedText = staged!.hunks.flatMap(\.lines).map(\.text).joined(separator: "\n")
        XCTAssertTrue(stagedText.contains("line2-CHANGED"))
        XCTAssertFalse(stagedText.contains("line13-CHANGED"))

        let unstaged = try await repo.diff(for: "file.txt", staged: false)
        let unstagedText = unstaged!.hunks.flatMap(\.lines).map(\.text).joined(separator: "\n")
        XCTAssertTrue(unstagedText.contains("line13-CHANGED"))
        XCTAssertFalse(unstagedText.contains("line2-CHANGED"))
    }

    /// 全部暂存后，按行取消暂存第二个 hunk。
    func testUnstageSelectedHunk() async throws {
        let original = (1...15).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try write("file.txt", original)
        try await commitAll("init")

        var lines = (1...15).map { "line\($0)" }
        lines[1] = "line2-CHANGED"
        lines[12] = "line13-CHANGED"
        try write("file.txt", lines.joined(separator: "\n") + "\n")
        try await git.run(["add", "--all"])

        let stagedDiff = try await repo.diff(for: "file.txt", staged: true)
        let staged = try XCTUnwrap(stagedDiff)
        XCTAssertEqual(staged.hunks.count, 2)

        let selected = Set(staged.hunks[1].changedLineIDs)
        let patch = try XCTUnwrap(PatchBuilder.unstagePatch(diff: staged, selectedLineIDs: selected))
        try await repo.applyPatch(patch, reverse: true)

        let cached = try await cachedContent("file.txt")
        XCTAssertTrue(cached.contains("line2-CHANGED"))
        XCTAssertFalse(cached.contains("line13-CHANGED"))

        // 工作区文件不受影响
        let worktree = try String(contentsOf: dir.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertTrue(worktree.contains("line13-CHANGED"))
    }

    /// 一个修改行 = 一删一增；只暂存新增行时，删除应保持未暂存。
    func testStageOnlyAdditionLine() async throws {
        try write("f.txt", "a\nb\nc\n")
        try await commitAll("init")
        try write("f.txt", "a\nB\nc\n")

        let diffOpt = try await repo.diff(for: "f.txt", staged: false)
        let diff = try XCTUnwrap(diffOpt)
        let addition = try XCTUnwrap(diff.hunks[0].lines.first { $0.kind == .addition })
        let patch = try XCTUnwrap(PatchBuilder.stagePatch(diff: diff, selectedLineIDs: [addition.id]))
        try await repo.applyPatch(patch, reverse: false)

        // 删除未暂存：暂存区同时有 b 和 B
        let cached = try await cachedContent("f.txt")
        XCTAssertEqual(cached, "a\nb\nB\nc\n")
    }

    /// 跨多个 hunk 同时选择。
    func testStageAcrossHunks() async throws {
        let original = (1...30).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try write("file.txt", original)
        try await commitAll("init")

        var lines = (1...30).map { "line\($0)" }
        lines[2] = "line3-X"
        lines[14] = "line15-X"
        lines[27] = "line28-X"
        try write("file.txt", lines.joined(separator: "\n") + "\n")

        let diffOpt = try await repo.diff(for: "file.txt", staged: false)
        let diff = try XCTUnwrap(diffOpt)
        XCTAssertEqual(diff.hunks.count, 3)

        // 选第 1、3 个 hunk
        let selected = Set(diff.hunks[0].changedLineIDs + diff.hunks[2].changedLineIDs)
        let patch = try XCTUnwrap(PatchBuilder.stagePatch(diff: diff, selectedLineIDs: selected))
        try await repo.applyPatch(patch, reverse: false)

        let cached = try await cachedContent("file.txt")
        XCTAssertTrue(cached.contains("line3-X"))
        XCTAssertFalse(cached.contains("line15-X"))
        XCTAssertTrue(cached.contains("line28-X"))
    }

    /// 文件末尾无换行符的场景。
    func testNoNewlineAtEOF() async throws {
        try write("f.txt", "a\nb")  // 无结尾换行
        try await commitAll("init")
        try write("f.txt", "a\nB")  // 仍无结尾换行

        let diffOpt = try await repo.diff(for: "f.txt", staged: false)
        let diff = try XCTUnwrap(diffOpt)
        let selected = Set(diff.changedLineIDs)
        let patch = try XCTUnwrap(PatchBuilder.stagePatch(diff: diff, selectedLineIDs: selected))
        try await repo.applyPatch(patch, reverse: false)

        let cached = try await cachedContent("f.txt")
        XCTAssertEqual(cached, "a\nB")
    }
}

final class PatchBuilderUnitTests: XCTestCase {

    private func makeDiff() -> FileDiff {
        let text = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1,4 +1,4 @@
         ctx1
        -old
        +new
         ctx2
        @@ -10,3 +10,4 @@
         a
        +b
         c
        """
        return DiffParser.parse(text)[0]
    }

    func testSkipsUnselectedHunk() {
        let diff = makeDiff()
        let selected = Set(diff.hunks[0].changedLineIDs)
        let patch = PatchBuilder.stagePatch(diff: diff, selectedLineIDs: selected)!
        XCTAssertTrue(patch.contains("-old"))
        XCTAssertTrue(patch.contains("+new"))
        XCTAssertFalse(patch.contains("+b"))
        XCTAssertTrue(patch.hasSuffix("\n"))
    }

    func testEmptySelectionReturnsNil() {
        XCTAssertNil(PatchBuilder.stagePatch(diff: makeDiff(), selectedLineIDs: []))
    }

    func testUnselectedDeletionBecomesContextWhenStaging() {
        let diff = makeDiff()
        let additionID = diff.hunks[0].lines.first { $0.kind == .addition }!.id
        let patch = PatchBuilder.stagePatch(diff: diff, selectedLineIDs: [additionID])!
        XCTAssertTrue(patch.contains("\n old\n"), "未选中的删除行应降级为上下文")
        XCTAssertTrue(patch.contains("\n+new\n"))
    }

    func testUnstagePatchDemotesUnselectedAddition() {
        let diff = makeDiff()
        let deletionID = diff.hunks[0].lines.first { $0.kind == .deletion }!.id
        let patch = PatchBuilder.unstagePatch(diff: diff, selectedLineIDs: [deletionID])!
        XCTAssertTrue(patch.contains("\n-old\n"))
        XCTAssertTrue(patch.contains("\n new\n"), "未选中的新增行应降级为上下文")
    }
}
