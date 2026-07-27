import XCTest
@testable import HunkCore

final class OpenPathResolverTests: XCTestCase {
    private let currentDirectory = URL(fileURLWithPath: "/tmp/work/project")
    private let homeDirectory = URL(fileURLWithPath: "/Users/example")

    func testResolvesRelativeCurrentDirectory() {
        let url = OpenPathResolver.resolve(
            "./",
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(url?.path, "/tmp/work/project")
    }

    func testResolvesRelativeChildDirectory() {
        let url = OpenPathResolver.resolve(
            "../another/./repo",
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(url?.path, "/tmp/work/another/repo")
    }

    func testExpandsHomeDirectory() {
        let url = OpenPathResolver.resolve(
            "~/Documents/web/repo",
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(url?.path, "/Users/example/Documents/web/repo")
    }

    func testStandardizesAbsolutePath() {
        let url = OpenPathResolver.resolve(
            "/Users/example/Documents/../Desktop/repo/",
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(url?.path, "/Users/example/Desktop/repo")
    }

    func testRejectsEmptyPath() {
        XCTAssertNil(OpenPathResolver.resolve(""))
    }
}
