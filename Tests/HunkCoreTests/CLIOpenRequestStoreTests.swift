import XCTest
@testable import HunkCore

final class CLIOpenRequestStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hunk-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testConsumePreservesWhitespaceInPath() throws {
        let path = " /tmp/project with spaces/ "
        try path.write(to: directory.appendingPathComponent("cli-open"), atomically: true, encoding: .utf8)

        XCTAssertTrue(CLIOpenRequestStore.hasPendingRequest(in: directory))
        XCTAssertEqual(CLIOpenRequestStore.consume(in: directory), [path])
        XCTAssertFalse(CLIOpenRequestStore.hasPendingRequest(in: directory))
    }

    func testEmptyRequestIsRetainedUntilComplete() throws {
        let url = directory.appendingPathComponent("cli-open.123")
        try Data().write(to: url)

        XCTAssertTrue(CLIOpenRequestStore.hasPendingRequest(in: directory))
        XCTAssertTrue(CLIOpenRequestStore.consume(in: directory).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try "/tmp/ready".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(CLIOpenRequestStore.consume(in: directory), ["/tmp/ready"])
    }
}
