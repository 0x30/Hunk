import XCTest
@testable import HunkCore

final class StatusParserTests: XCTestCase {

    private func data(_ tokens: [String]) -> Data {
        Data(tokens.joined(separator: "\0").utf8) + Data([0])
    }

    func testBasicStatuses() {
        let input = data([
            "M  staged-modified.txt",
            " M worktree-modified.txt",
            "MM both.txt",
            "A  new-staged.txt",
            " D deleted-worktree.txt",
            "?? untracked.txt",
        ])
        let changes = StatusParser.parse(input)
        XCTAssertEqual(changes.count, 6)

        XCTAssertEqual(changes[0].staged, .modified)
        XCTAssertNil(changes[0].unstaged)

        XCTAssertNil(changes[1].staged)
        XCTAssertEqual(changes[1].unstaged, .modified)

        XCTAssertEqual(changes[2].staged, .modified)
        XCTAssertEqual(changes[2].unstaged, .modified)

        XCTAssertEqual(changes[3].staged, .added)
        XCTAssertEqual(changes[4].unstaged, .deleted)

        XCTAssertEqual(changes[5].path, "untracked.txt")
        XCTAssertEqual(changes[5].unstaged, .untracked)
        XCTAssertNil(changes[5].staged)
    }

    func testRenameConsumesOldPath() {
        let input = data([
            "R  new-name.txt",
            "old-name.txt",
            " M after.txt",
        ])
        let changes = StatusParser.parse(input)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].path, "new-name.txt")
        XCTAssertEqual(changes[0].oldPath, "old-name.txt")
        XCTAssertEqual(changes[0].staged, .renamed)
        XCTAssertEqual(changes[1].path, "after.txt")
    }

    func testConflict() {
        let input = data(["UU conflicted.txt", "AA both-added.txt"])
        let changes = StatusParser.parse(input)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.allSatisfy { $0.unstaged == .conflicted })
        XCTAssertTrue(changes.allSatisfy { $0.staged == nil })
    }

    func testPathWithSpaces() {
        let input = data([" M dir with space/file name.txt"])
        let changes = StatusParser.parse(input)
        XCTAssertEqual(changes.first?.path, "dir with space/file name.txt")
    }
}
