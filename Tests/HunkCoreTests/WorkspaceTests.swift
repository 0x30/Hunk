import Foundation
import XCTest
@testable import HunkCore

final class WorkspaceTests: XCTestCase {
    func testTypedIDsRoundTripAsSingleUUIDValues() throws {
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let workspaceID = WorkspaceID(rawValue: uuid)
        let folderID = WorkspaceFolderID(rawValue: uuid)
        let repositoryID = RepositoryID(rawValue: uuid)

        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkspaceID.self,
                from: JSONEncoder().encode(workspaceID)
            ),
            workspaceID
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkspaceFolderID.self,
                from: JSONEncoder().encode(folderID)
            ),
            folderID
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RepositoryID.self,
                from: JSONEncoder().encode(repositoryID)
            ),
            repositoryID
        )
    }

    func testWorkspaceFileIDNamespacesAndNormalizesRelativePath() {
        let firstFolderID = WorkspaceFolderID()
        let secondFolderID = WorkspaceFolderID()

        let first = WorkspaceFileID(
            folderID: firstFolderID,
            relativePath: "docs/./guide/../README.md"
        )
        let same = WorkspaceFileID(
            folderID: firstFolderID,
            relativePath: "docs/README.md"
        )
        let otherFolder = WorkspaceFileID(
            folderID: secondFolderID,
            relativePath: "docs/README.md"
        )

        XCTAssertEqual(first.relativePath, "docs/README.md")
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherFolder)
    }

    func testCanonicalPathStandardizesRelativeComponents() {
        let base = URL(fileURLWithPath: "/tmp/acme/workspace", isDirectory: true)

        XCTAssertEqual(
            WorkspacePath.canonicalPath("../front/./Sources/", relativeTo: base),
            "/tmp/acme/front/Sources"
        )
    }

    func testCanonicalPathResolvesSymlinks() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realRoot = temporaryRoot.appendingPathComponent("real", isDirectory: true)
        let linkRoot = temporaryRoot.appendingPathComponent("link", isDirectory: true)
        try fileManager.createDirectory(
            at: realRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            atPath: linkRoot.path,
            withDestinationPath: realRoot.path
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        XCTAssertEqual(
            WorkspacePath.canonicalURL(linkRoot).path,
            WorkspacePath.canonicalURL(realRoot).path
        )
    }

    func testLongestPrefixOwnershipUsesPathBoundaries() {
        let root = FolderDescriptor(
            displayName: "root",
            path: "/projects/acme",
            order: 0
        )
        let nested = FolderDescriptor(
            displayName: "front",
            path: "/projects/acme/front",
            order: 1
        )
        let workspace = WorkspaceDescriptor(
            name: "Acme",
            folders: [root, nested]
        )

        XCTAssertEqual(
            workspace.folder(
                containing: URL(fileURLWithPath: "/projects/acme/front/src/App.swift")
            )?.id,
            nested.id
        )
        XCTAssertEqual(
            workspace.folder(
                containing: URL(fileURLWithPath: "/projects/acme/back/main.go")
            )?.id,
            root.id
        )
        XCTAssertNil(
            workspace.folder(
                containing: URL(fileURLWithPath: "/projects/acme-other/file.txt")
            )
        )
    }

    func testWorkspaceFileIDAndURLRoundTrip() {
        let front = FolderDescriptor(
            displayName: "front",
            path: "/projects/acme/front",
            order: 0
        )
        let workspace = WorkspaceDescriptor(name: "Acme", folders: [front])
        let fileURL = URL(fileURLWithPath: "/projects/acme/front/src/App.swift")

        let fileID = workspace.fileID(for: fileURL)

        XCTAssertEqual(fileID?.folderID, front.id)
        XCTAssertEqual(fileID?.relativePath, "src/App.swift")
        XCTAssertEqual(workspace.url(for: fileID!)?.path, fileURL.path)
        XCTAssertNil(
            workspace.fileID(
                for: URL(fileURLWithPath: "/projects/acme/front-other/App.swift")
            )
        )
        XCTAssertNil(
            workspace.url(
                for: WorkspaceFileID(
                    folderID: front.id,
                    relativePath: "../../outside.txt"
                )
            )
        )
    }

    func testAddingEquivalentRootDetectsDuplicate() {
        let folder = FolderDescriptor(
            displayName: "front",
            path: "/projects/acme/front",
            order: 0
        )
        let workspace = WorkspaceDescriptor(name: "Acme", folders: [folder])

        XCTAssertEqual(
            workspace.conflicts(
                adding: URL(fileURLWithPath: "/projects/acme/./front/")
            ),
            [
                WorkspaceFolderConflict(
                    kind: .duplicate,
                    existingFolderID: folder.id
                ),
            ]
        )
    }

    func testAddingNestedAndContainingRootsDetectsDirection() {
        let front = FolderDescriptor(
            displayName: "front",
            path: "/projects/acme/front",
            order: 0
        )
        let workspace = WorkspaceDescriptor(name: "Acme", folders: [front])

        XCTAssertEqual(
            workspace.conflicts(
                adding: URL(fileURLWithPath: "/projects/acme/front/packages/ui")
            ).first?.kind,
            .nestedUnderExisting
        )
        XCTAssertEqual(
            workspace.conflicts(
                adding: URL(fileURLWithPath: "/projects/acme")
            ).first?.kind,
            .containsExisting
        )
        XCTAssertTrue(
            workspace.conflicts(
                adding: URL(fileURLWithPath: "/projects/acme/back")
            ).isEmpty
        )
    }

    func testExistingRootConflictDetectionChecksEveryPair() {
        let parent = FolderDescriptor(
            displayName: "Acme",
            path: "/projects/acme",
            order: 0
        )
        let child = FolderDescriptor(
            displayName: "front",
            path: "/projects/acme/front",
            order: 1
        )
        let unrelated = FolderDescriptor(
            displayName: "tools",
            path: "/projects/tools",
            order: 2
        )
        let workspace = WorkspaceDescriptor(
            name: "Acme",
            folders: [parent, unrelated, child]
        )

        XCTAssertEqual(
            workspace.folderRootConflicts(),
            [
                WorkspaceFolderPairConflict(
                    firstFolderID: parent.id,
                    secondFolderID: child.id,
                    kind: .nestedUnderExisting
                ),
            ]
        )
    }

    func testOrderedFoldersUsesArrayPositionForEqualOrders() {
        let front = FolderDescriptor(
            displayName: "front",
            path: "/projects/front",
            order: 1
        )
        let back = FolderDescriptor(
            displayName: "back",
            path: "/projects/back",
            order: 0
        )
        let tools = FolderDescriptor(
            displayName: "tools",
            path: "/projects/tools",
            order: 1
        )
        let workspace = WorkspaceDescriptor(
            name: "Acme",
            folders: [front, back, tools]
        )

        XCTAssertEqual(
            workspace.orderedFolders.map(\.id),
            [back.id, front.id, tools.id]
        )
    }

    func testPersistenceRoundTripPreservesStableIdentities() throws {
        let front = FolderDescriptor(
            id: WorkspaceFolderID(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            displayName: "front",
            path: "/projects/acme/front",
            order: 0
        )
        let workspace = WorkspaceDescriptor(
            id: WorkspaceID(
                rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            name: "Acme",
            folders: [front],
            activeFolderID: front.id,
            activeRepositoryID: RepositoryID(
                rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
            )
        )

        let data = try WorkspacePersistence.encode(workspace)
        let decoded = try WorkspacePersistence.decode(data)

        XCTAssertEqual(decoded, workspace)
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self)
                .contains("\"schemaVersion\":1")
        )
    }

    func testPersistenceRejectsUnsupportedSchema() {
        let data = Data(
            """
            {
              "schemaVersion": 99,
              "workspace": {
                "id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                "name": "Acme",
                "folders": [],
                "activeFolderID": null,
                "activeRepositoryID": null
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try WorkspacePersistence.decode(data)) { error in
            XCTAssertEqual(
                error as? WorkspacePersistence.PersistenceError,
                .unsupportedSchemaVersion(99)
            )
        }
    }

    func testPersistenceRejectsOverlappingFolderRoots() throws {
        let parent = FolderDescriptor(
            displayName: "Acme",
            path: "/projects/acme",
            order: 0
        )
        let child = FolderDescriptor(
            displayName: "front",
            path: "/projects/acme/front",
            order: 1
        )
        let workspace = WorkspaceDescriptor(
            name: "Invalid",
            folders: [parent, child]
        )
        let data = try WorkspacePersistence.encode(workspace)

        XCTAssertThrowsError(try WorkspacePersistence.decode(data)) { error in
            guard case let WorkspacePersistence.PersistenceError.invalidFolderRoots(conflicts) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(conflicts.count, 1)
            XCTAssertEqual(conflicts[0].kind, .nestedUnderExisting)
        }
    }
}
