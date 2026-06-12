import XCTest
@testable import HunkCore

final class DiffParserTests: XCTestCase {

    func testModifiedFileWithTwoHunks() {
        let text = """
        diff --git a/file.txt b/file.txt
        index 83db48f..bf269f4 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,4 +1,4 @@ func foo()
         line1
        -line2
        +line2 changed
         line3
        @@ -10,2 +10,3 @@
         a
        +b
         c
        """
        let diffs = DiffParser.parse(text)
        XCTAssertEqual(diffs.count, 1)
        let diff = diffs[0]
        XCTAssertEqual(diff.oldPath, "file.txt")
        XCTAssertEqual(diff.newPath, "file.txt")
        XCTAssertFalse(diff.isNew)
        XCTAssertEqual(diff.hunks.count, 2)

        let h1 = diff.hunks[0]
        XCTAssertEqual(h1.oldStart, 1)
        XCTAssertEqual(h1.oldCount, 4)
        XCTAssertEqual(h1.sectionHeading, "func foo()")
        XCTAssertEqual(h1.lines.map(\.kind), [.context, .deletion, .addition, .context])
        XCTAssertEqual(h1.lines[1].text, "line2")
        XCTAssertEqual(h1.lines[1].oldNumber, 2)
        XCTAssertNil(h1.lines[1].newNumber)
        XCTAssertEqual(h1.lines[2].text, "line2 changed")
        XCTAssertEqual(h1.lines[2].newNumber, 2)
        XCTAssertNil(h1.lines[2].oldNumber)
        XCTAssertEqual(h1.lines[3].oldNumber, 3)
        XCTAssertEqual(h1.lines[3].newNumber, 3)

        let h2 = diff.hunks[1]
        XCTAssertEqual(h2.newStart, 10)
        XCTAssertEqual(h2.newCount, 3)
        XCTAssertEqual(h2.lines.map(\.kind), [.context, .addition, .context])

        // 行 id 全局唯一
        let ids = diff.hunks.flatMap { $0.lines.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)

        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
    }

    func testNewFile() {
        let text = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        index 0000000..1234567
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,2 @@
        +let a = 1
        +let b = 2
        """
        let diffs = DiffParser.parse(text)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertTrue(diffs[0].isNew)
        XCTAssertNil(diffs[0].oldPath)
        XCTAssertEqual(diffs[0].newPath, "new.swift")
        XCTAssertEqual(diffs[0].hunks[0].lines.count, 2)
        XCTAssertEqual(diffs[0].hunks[0].lines[1].newNumber, 2)
    }

    func testBinaryFile() {
        let text = """
        diff --git a/image.png b/image.png
        index 1234567..89abcde 100644
        Binary files a/image.png and b/image.png differ
        """
        let diffs = DiffParser.parse(text)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertTrue(diffs[0].isBinary)
        XCTAssertTrue(diffs[0].hunks.isEmpty)
    }

    func testNoNewlineAtEOF() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let diffs = DiffParser.parse(text)
        let lines = diffs[0].hunks[0].lines
        XCTAssertTrue(lines[0].noNewline)
        XCTAssertTrue(lines[1].noNewline)
    }

    func testMultipleFiles() {
        let text = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -x
        +y
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -p
        +q
        """
        let diffs = DiffParser.parse(text)
        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs[0].path, "a.txt")
        XCTAssertEqual(diffs[1].path, "b.txt")
    }

    func testSplitRowsPairing() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,4 +1,5 @@
         ctx1
        -del1
        -del2
        +add1
         ctx2
        +add2
        +add3
        """
        let rows = DiffParser.parse(text)[0].hunks[0].splitRows
        // ctx1 | (del1,add1) | (del2,nil) | ctx2 | (nil,add2) | (nil,add3)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].left?.text, "ctx1")
        XCTAssertEqual(rows[0].right?.text, "ctx1")
        XCTAssertEqual(rows[1].left?.text, "del1")
        XCTAssertEqual(rows[1].right?.text, "add1")
        XCTAssertEqual(rows[2].left?.text, "del2")
        XCTAssertNil(rows[2].right)
        XCTAssertNil(rows[4].left)
        XCTAssertEqual(rows[4].right?.text, "add2")
    }
}
