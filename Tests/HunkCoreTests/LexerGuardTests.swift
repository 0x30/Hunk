import XCTest
@testable import HunkCore

/// tokenize 的死循环防御：无论语言规则多病态 / 输入多刁钻，扫描位置必须前进，
/// token 数受字符数约束——根治「i 不动 → 无限 append → [Token] 涨到数百 MB OOM」。
final class LexerGuardTests: XCTestCase {
    /// 病态语言：空块注释起始符会让旧代码 `i = k = i` 原地打转。
    /// 有前进保护后必须快速终止，token 数 ≤ 字符数。
    func testTerminatesOnPathologicalLanguage() {
        let pathological = LanguageDef(
            name: "X",
            keywords: [],
            blockCommentStart: "",
            blockCommentEnd: ""
        )
        let input = String(repeating: "/* abc */ def ", count: 64)
        let toks = Lexer.tokenize(input, language: pathological)
        XCTAssertLessThanOrEqual(toks.count, input.count)
    }

    /// 不变量：任意输入下，每个 token 至少吃掉一个字符 ⇒ token 数 ≤ 字符数。
    /// 覆盖触发本次崩溃的 .ts（含模板字符串 `${}`、泛型、行尾注释）。
    func testTokenCountBoundedByLength() throws {
        let ts = try XCTUnwrap(Lexer.language(forFileExtension: "ts"))
        let lines = [
            "const x: Record<string, number> = { a: 1, b: `tpl${y}` } // c",
            "/* unterminated block comment",
            "`template ${nested(`inner`)} tail",
            "0x1f.fe_3p+10 and 'a\\nb' and \"c\\\"d\"",
            String(repeating: "a/*b`c'd\"e", count: 100),
        ]
        for line in lines {
            let toks = Lexer.tokenize(line, language: ts)
            XCTAssertLessThanOrEqual(toks.count, line.count, "退化输入：\(line.prefix(30))")
        }
    }
}
