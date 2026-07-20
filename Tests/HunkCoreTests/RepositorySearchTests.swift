import XCTest
@testable import HunkCore

final class RepositorySearchTests: XCTestCase {
    func testSearchPathspecsUseRepositoryWhenIncludesAreEmpty() {
        XCTAssertEqual(
            Repository.searchPathspecs(include: [], exclude: [".build/**", "*.generated.swift"]),
            [".", ":(exclude).build/**", ":(exclude)*.generated.swift"]
        )
    }

    func testSearchPathspecsKeepMultipleIncludes() {
        XCTAssertEqual(
            Repository.searchPathspecs(include: ["*.ts", "*.js"], exclude: ["dist/**"]),
            ["*.ts", "*.js", ":(exclude)dist/**"]
        )
    }
}
