import XCTest
@testable import HunkCore

final class ConflictParserTests: XCTestCase {

    let sample = """
    line1
    <<<<<<< HEAD
    ours-a
    ours-b
    =======
    theirs-a
    >>>>>>> feature
    line2
    """

    func testParse() {
        let blocks = ConflictParser.parse(sample)
        XCTAssertEqual(blocks.count, 1)
        let block = blocks[0]
        XCTAssertEqual(block.startLine, 1)
        XCTAssertEqual(block.endLine, 6)
        XCTAssertEqual(block.currentLines, ["ours-a", "ours-b"])
        XCTAssertEqual(block.incomingLines, ["theirs-a"])
        XCTAssertEqual(block.currentLabel, "HEAD")
        XCTAssertEqual(block.incomingLabel, "feature")
    }

    func testResolveCurrent() {
        let block = ConflictParser.parse(sample)[0]
        let resolved = ConflictParser.resolve(sample, block: block, with: .current)
        XCTAssertEqual(resolved, "line1\nours-a\nours-b\nline2")
        XCTAssertTrue(ConflictParser.parse(resolved).isEmpty)
    }

    func testResolveIncoming() {
        let block = ConflictParser.parse(sample)[0]
        let resolved = ConflictParser.resolve(sample, block: block, with: .incoming)
        XCTAssertEqual(resolved, "line1\ntheirs-a\nline2")
    }

    func testResolveBoth() {
        let block = ConflictParser.parse(sample)[0]
        let resolved = ConflictParser.resolve(sample, block: block, with: .both)
        XCTAssertEqual(resolved, "line1\nours-a\nours-b\ntheirs-a\nline2")
    }

    func testDiff3StyleSkipsBase() {
        let text = """
        <<<<<<< HEAD
        ours
        ||||||| merged common ancestors
        base
        =======
        theirs
        >>>>>>> branch
        """
        let blocks = ConflictParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].currentLines, ["ours"])
        XCTAssertEqual(blocks[0].incomingLines, ["theirs"])
    }

    func testMultipleBlocks() {
        let text = """
        <<<<<<< HEAD
        a
        =======
        b
        >>>>>>> x
        mid
        <<<<<<< HEAD
        c
        =======
        d
        >>>>>>> x
        """
        XCTAssertEqual(ConflictParser.parse(text).count, 2)
    }

    func testNoConflict() {
        XCTAssertTrue(ConflictParser.parse("plain\ntext").isEmpty)
    }
}
