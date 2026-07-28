import XCTest
@testable import HunkCore

final class MarkdownSmartNewlineTests: XCTestCase {
    func testOrderedListIncrementsDotAndParenthesis() {
        assertEdit("1. first", caret: 8, expected: "1. first\n2. ")
        assertEdit("  9) item", caret: 9, expected: "  9) item\n  10) ")
    }

    func testOrderedListSupportsLargeNumbersAndLeadingZeroes() {
        assertEdit(
            "999999999999999999999. item",
            caret: 27,
            expected: "999999999999999999999. item\n1000000000000000000000. "
        )
        assertEdit("009. item", caret: 9, expected: "009. item\n010. ")
    }

    func testUnorderedListPreservesBulletSpacingAndIndentation() {
        assertEdit("- item", caret: 6, expected: "- item\n- ")
        assertEdit("\t*  item", caret: 8, expected: "\t*  item\n\t*  ")
        assertEdit("    + nested", caret: 12, expected: "    + nested\n    + ")
    }

    func testTaskListAlwaysContinuesUnchecked() {
        assertEdit("- [ ] todo", caret: 10, expected: "- [ ] todo\n- [ ] ")
        assertEdit("  * [x] done", caret: 12, expected: "  * [x] done\n  * [ ] ")
        assertEdit("+ [X] done", caret: 10, expected: "+ [X] done\n+ [ ] ")
    }

    func testEmptyItemExitsListWithoutConsumingExistingNewline() {
        assertEdit("- ", caret: 2, expected: "")
        assertEdit("before\n  3)   \nafter", caret: 14, expected: "before\n\nafter")
        assertEdit("- [x]   \nnext", caret: 8, expected: "\nnext")
    }

    func testDoesNotContinueInsideFencedCode() {
        XCTAssertNil(edit("```markdown\n1. code", caret: 19))
        XCTAssertNil(edit("~~~\n- code", caret: 10))

        assertEdit(
            "```\n1. code\n```\n1. real",
            caret: 23,
            expected: "```\n1. code\n```\n1. real\n2. "
        )
    }

    func testCursorInMiddleMovesSuffixToContinuedItem() {
        XCTAssertNil(edit("🙂 1. hello world", caret: 11))
        assertEdit(
            "1. hello🙂world",
            caret: 8,
            expected: "1. hello\n2. 🙂world"
        )
    }

    func testCursorInsideMarkerAndNonEmptySelectionUseNativeBehavior() {
        XCTAssertNil(edit("12. item", caret: 1))
        XCTAssertNil(MarkdownSmartNewline.edit(
            in: "1. selected",
            selectedRange: NSRange(location: 3, length: 8)
        ))
    }

    func testUsesUTF16RangesForEmojiAndNonASCIIText() {
        let text = "前文🙂\n  1. 内容🙂尾巴"
        let caret = ("前文🙂\n  1. 内容" as NSString).length
        let result = MarkdownSmartNewline.edit(
            in: text,
            selectedRange: NSRange(location: caret, length: 0)
        )

        XCTAssertEqual(result?.range, NSRange(location: caret, length: 0))
        XCTAssertEqual(result?.replacement, "\n  2. ")
        XCTAssertEqual(result?.selectedRange.location, caret + ("\n  2. " as NSString).length)
        XCTAssertEqual(apply(result, to: text), "前文🙂\n  1. 内容\n  2. 🙂尾巴")
    }

    func testPlainTextAndInvalidRangesAreNotHandled() {
        XCTAssertNil(edit("plain text", caret: 10))
        XCTAssertNil(MarkdownSmartNewline.edit(
            in: "- item",
            selectedRange: NSRange(location: 99, length: 0)
        ))
    }

    private func edit(_ text: String, caret: Int) -> MarkdownNewlineEdit? {
        MarkdownSmartNewline.edit(
            in: text,
            selectedRange: NSRange(location: caret, length: 0)
        )
    }

    private func assertEdit(
        _ text: String,
        caret: Int,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = edit(text, caret: caret)
        XCTAssertNotNil(result, file: file, line: line)
        XCTAssertEqual(apply(result, to: text), expected, file: file, line: line)
        if let result {
            XCTAssertEqual(
                result.selectedRange.location,
                result.range.location + (result.replacement as NSString).length,
                file: file,
                line: line
            )
            XCTAssertEqual(result.selectedRange.length, 0, file: file, line: line)
        }
    }

    private func apply(_ edit: MarkdownNewlineEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
}
