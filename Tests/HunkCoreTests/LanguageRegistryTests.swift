import XCTest
@testable import HunkCore

/// 验证语言表从 languages.json 正确加载（数据驱动重构后）。
final class LanguageRegistryTests: XCTestCase {
    func testCoreLanguagesLoaded() {
        for ext in ["swift", "ts", "go", "py", "rs", "java", "sql", "json", "css", "yaml"] {
            XCTAssertNotNil(Lexer.language(forFileExtension: ext), "缺语言: \(ext)")
        }
    }

    func testNewlyAddedAndFixedLanguages() {
        // 之前「凑合」复用的，现在是独立正确定义
        XCTAssertEqual(Lexer.language(forFileExtension: "toml")?.name, "TOML")
        XCTAssertEqual(Lexer.language(forFileExtension: "kt")?.name, "Kotlin")
        XCTAssertEqual(Lexer.language(forFileExtension: "dart")?.name, "Dart")
        XCTAssertEqual(Lexer.language(forFileExtension: "rst")?.name, "reStructuredText")
        // 新增语言
        for ext in ["lua", "jl", "hs", "ex", "erl", "clj", "ps1", "proto", "graphql", "r"] {
            XCTAssertNotNil(Lexer.language(forFileExtension: ext), "缺新增语言: \(ext)")
        }
    }

    func testFilenameMapping() {
        XCTAssertEqual(Lexer.language(forFileName: "Dockerfile")?.name, "Dockerfile")
        XCTAssertEqual(Lexer.language(forFileName: "Makefile")?.name, "Makefile")
        XCTAssertEqual(Lexer.language(forFileName: "Gemfile")?.name, "Ruby")
        XCTAssertNil(Lexer.language(forFileName: "unknown.xyz"))
    }

    func testFieldsDecodedCorrectly() {
        let ts = Lexer.language(forFileExtension: "ts")
        XCTAssertEqual(ts?.name, "JavaScript/TypeScript")
        XCTAssertTrue(ts?.keywords.contains("interface") ?? false)
        XCTAssertTrue(ts?.stringDelimiters.contains("`") ?? false)  // 模板字符串反引号
        XCTAssertEqual(ts?.blockCommentStart, "/*")
        XCTAssertEqual(ts?.blockCommentEnd, "*/")
        XCTAssertTrue(ts?.capitalizedTypes ?? false)

        // Python：行注释 #、无块注释（默认值正确生效）
        let py = Lexer.language(forFileExtension: "py")
        XCTAssertEqual(py?.lineComments, ["#"])
        XCTAssertNil(py?.blockCommentStart)
    }

    /// 实际高亮一行 .ts（回归：触发本次 OOM 的语言），确认能 tokenize 且不爆。
    func testTypeScriptTokenizes() throws {
        let ts = try XCTUnwrap(Lexer.language(forFileExtension: "ts"))
        let toks = Lexer.tokenize("export const n: number = 1 // ok", language: ts)
        XCTAssertFalse(toks.isEmpty)
        XCTAssertLessThanOrEqual(toks.count, 33)
    }
}
