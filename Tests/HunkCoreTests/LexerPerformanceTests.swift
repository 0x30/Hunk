import XCTest
@testable import HunkCore

final class LexerPerformanceTests: XCTestCase {
    func testLargeTypeScriptSourceProducesBoundedValidRanges() throws {
        let language = try XCTUnwrap(Lexer.language(forFileExtension: "ts"))
        let line = "export const value: Record<string, number> = { key: 0x1f } // comment\n"
        let source = String(repeating: line, count: 5_000)
        let utf16Length = (source as NSString).length

        let tokens = Lexer.tokenize(source, language: language)

        XCTAssertEqual(tokens.count, 35_000)
        XCTAssertTrue(tokens.allSatisfy {
            $0.range.length > 0 && $0.range.location >= 0 && NSMaxRange($0.range) <= utf16Length
        })
    }

    func testTokenRangesUseUTF16Coordinates() throws {
        let language = try XCTUnwrap(Lexer.language(forFileExtension: "swift"))
        let source = "/* cafe\u{301} 🚀 */ let answer = 42"

        let tokens = Lexer.tokenize(source, language: language)
        let nsSource = source as NSString

        XCTAssertEqual(tokens.map { nsSource.substring(with: $0.range) }, [
            "/* cafe\u{301} 🚀 */", "let", "42",
        ])
    }
}
