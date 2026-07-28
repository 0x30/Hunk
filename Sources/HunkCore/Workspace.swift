import Foundation

// MARK: - Stable identities

/// A stable identity for a workspace. The ID is independent of its name and folders.
public struct WorkspaceID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var id: WorkspaceID { self }
    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A stable identity for one root folder in a workspace.
public struct WorkspaceFolderID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var id: WorkspaceFolderID { self }
    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A stable identity for a Git repository in a workspace.
public struct RepositoryID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var id: RepositoryID { self }
    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A file identity namespaced by its workspace folder.
///
/// The same relative path in two roots therefore remains two different documents.
public struct WorkspaceFileID: Hashable, Codable, Sendable, Identifiable {
    public let folderID: WorkspaceFolderID
    public let relativePath: String

    public init(folderID: WorkspaceFolderID, relativePath: String) {
        self.folderID = folderID
        self.relativePath = WorkspacePath.normalizedRelativePath(relativePath)
    }

    public var id: WorkspaceFileID { self }
}

// MARK: - Persistent descriptors

/// The persisted description of one root folder.
public struct FolderDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: WorkspaceFolderID
    public var displayName: String
    public var path: String
    public var order: Int

    public init(
        id: WorkspaceFolderID = WorkspaceFolderID(),
        displayName: String,
        path: String,
        order: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.path = WorkspacePath.canonicalPath(path)
        self.order = order
    }

    public var rootURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// Backwards-compatible descriptive name used by the design document.
public typealias WorkspaceFolderDescriptor = FolderDescriptor

/// The persisted, UI-independent workspace model.
public struct WorkspaceDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: WorkspaceID
    public var name: String
    public var folders: [FolderDescriptor]
    public var activeFolderID: WorkspaceFolderID?
    public var activeRepositoryID: RepositoryID?

    public init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        folders: [FolderDescriptor] = [],
        activeFolderID: WorkspaceFolderID? = nil,
        activeRepositoryID: RepositoryID? = nil
    ) {
        self.id = id
        self.name = name
        self.folders = folders
        self.activeFolderID = activeFolderID
        self.activeRepositoryID = activeRepositoryID
    }

    /// Folders in the order shown by the workspace, with array position as a stable tie-breaker.
    public var orderedFolders: [FolderDescriptor] {
        folders.enumerated()
            .sorted {
                if $0.element.order != $1.element.order {
                    return $0.element.order < $1.element.order
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// Finds the most specific root containing `url`.
    ///
    /// Longest-prefix matching matters for old/restored workspaces that may contain nested
    /// roots even though adding new overlapping roots is rejected.
    public func folder(containing url: URL) -> FolderDescriptor? {
        WorkspacePath.longestContainingFolder(for: url, in: folders)
    }

    /// Produces a namespaced file identity if the URL belongs to this workspace.
    public func fileID(for url: URL) -> WorkspaceFileID? {
        guard let folder = folder(containing: url),
              let relativePath = WorkspacePath.relativePath(of: url, under: folder.rootURL),
              !relativePath.isEmpty
        else {
            return nil
        }
        return WorkspaceFileID(folderID: folder.id, relativePath: relativePath)
    }

    /// Resolves a namespaced file identity back to a URL, if its folder still exists.
    public func url(for fileID: WorkspaceFileID) -> URL? {
        guard let folder = folders.first(where: { $0.id == fileID.folderID }),
              WorkspacePath.isSafeRelativePath(fileID.relativePath)
        else {
            return nil
        }
        return folder.rootURL
            .appendingPathComponent(fileID.relativePath)
            .standardizedFileURL
    }

    /// Returns all duplicate or nested-root conflicts for a proposed folder.
    public func conflicts(adding url: URL) -> [WorkspaceFolderConflict] {
        WorkspacePath.conflicts(adding: url, to: folders)
    }

    /// Returns conflicts already present in the persisted descriptor.
    public func folderRootConflicts() -> [WorkspaceFolderPairConflict] {
        WorkspacePath.conflicts(in: folders)
    }
}

// MARK: - Path ownership and root validation

public enum WorkspaceFolderConflictKind: String, Hashable, Codable, Sendable {
    /// The proposed root resolves to an existing root.
    case duplicate
    /// The proposed root is inside an existing root.
    case nestedUnderExisting
    /// The proposed root contains an existing root.
    case containsExisting
}

public struct WorkspaceFolderConflict: Hashable, Codable, Sendable {
    public let kind: WorkspaceFolderConflictKind
    public let existingFolderID: WorkspaceFolderID

    public init(kind: WorkspaceFolderConflictKind, existingFolderID: WorkspaceFolderID) {
        self.kind = kind
        self.existingFolderID = existingFolderID
    }
}

/// A conflict between two roots already stored in a workspace.
public struct WorkspaceFolderPairConflict: Hashable, Codable, Sendable {
    public let firstFolderID: WorkspaceFolderID
    public let secondFolderID: WorkspaceFolderID
    public let kind: WorkspaceFolderConflictKind

    public init(
        firstFolderID: WorkspaceFolderID,
        secondFolderID: WorkspaceFolderID,
        kind: WorkspaceFolderConflictKind
    ) {
        self.firstFolderID = firstFolderID
        self.secondFolderID = secondFolderID
        self.kind = kind
    }
}

public enum WorkspacePath {
    /// Canonicalizes an absolute or relative path, resolving `.`/`..` and filesystem symlinks.
    public static func canonicalPath(
        _ path: String,
        relativeTo baseURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> String {
        canonicalURL(forPath: path, relativeTo: baseURL).path
    }

    public static func canonicalURL(
        forPath path: String,
        relativeTo baseURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> URL {
        let url: URL
        if (path as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            url = baseURL.appendingPathComponent(path, isDirectory: true)
        }
        return canonicalURL(url)
    }

    public static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    /// Returns true for the root itself and descendants, using a path-component boundary.
    public static func contains(_ candidateURL: URL, in rootURL: URL) -> Bool {
        let candidate = canonicalURL(candidateURL).path
        let root = canonicalURL(rootURL).path
        if candidate == root { return true }
        if root == "/" { return candidate.hasPrefix("/") }
        return candidate.hasPrefix(root + "/")
    }

    /// Returns a canonical path relative to `rootURL`, or nil when it is outside the root.
    public static func relativePath(of candidateURL: URL, under rootURL: URL) -> String? {
        let candidate = canonicalURL(candidateURL).path
        let root = canonicalURL(rootURL).path
        guard contains(
            URL(fileURLWithPath: candidate),
            in: URL(fileURLWithPath: root)
        ) else {
            return nil
        }
        if candidate == root { return "" }
        if root == "/" { return String(candidate.dropFirst()) }
        return String(candidate.dropFirst(root.count + 1))
    }

    /// Chooses the deepest matching folder root rather than the first match.
    public static func longestContainingFolder(
        for candidateURL: URL,
        in folders: [FolderDescriptor]
    ) -> FolderDescriptor? {
        folders
            .filter { contains(candidateURL, in: $0.rootURL) }
            .max {
                let leftDepth = canonicalURL($0.rootURL).pathComponents.count
                let rightDepth = canonicalURL($1.rootURL).pathComponents.count
                if leftDepth != rightDepth { return leftDepth < rightDepth }
                return canonicalURL($0.rootURL).path.count < canonicalURL($1.rootURL).path.count
            }
    }

    public static func conflicts(
        adding candidateURL: URL,
        to folders: [FolderDescriptor]
    ) -> [WorkspaceFolderConflict] {
        let candidate = canonicalURL(candidateURL)
        return folders.compactMap { folder in
            let existing = canonicalURL(folder.rootURL)
            let kind: WorkspaceFolderConflictKind?
            if candidate.path == existing.path {
                kind = .duplicate
            } else if contains(candidate, in: existing) {
                kind = .nestedUnderExisting
            } else if contains(existing, in: candidate) {
                kind = .containsExisting
            } else {
                kind = nil
            }
            return kind.map {
                WorkspaceFolderConflict(kind: $0, existingFolderID: folder.id)
            }
        }
    }

    public static func conflicts(in folders: [FolderDescriptor]) -> [WorkspaceFolderPairConflict] {
        guard folders.count > 1 else { return [] }
        var result: [WorkspaceFolderPairConflict] = []
        for firstIndex in folders.indices.dropLast() {
            for secondIndex in folders.indices where secondIndex > firstIndex {
                let first = folders[firstIndex]
                let second = folders[secondIndex]
                let conflicts = conflicts(adding: second.rootURL, to: [first])
                guard let conflict = conflicts.first else { continue }
                result.append(
                    WorkspaceFolderPairConflict(
                        firstFolderID: first.id,
                        secondFolderID: second.id,
                        kind: conflict.kind
                    )
                )
            }
        }
        return result
    }

    public static func normalizedRelativePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if components.last.map({ $0 != ".." }) == true {
                    components.removeLast()
                } else {
                    components.append(String(component))
                }
            default:
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !(path as NSString).isAbsolutePath else { return false }
        let normalized = normalizedRelativePath(path)
        return !normalized.isEmpty
            && normalized != ".."
            && !normalized.hasPrefix("../")
    }
}

// MARK: - Codable persistence

public enum WorkspacePersistence {
    public static let currentSchemaVersion = 1

    public enum PersistenceError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
        case invalidFolderRoots([WorkspaceFolderPairConflict])
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let workspace: WorkspaceDescriptor
    }

    /// Encodes a versioned workspace payload suitable for UserDefaults or Application Support.
    public static func encode(
        _ workspace: WorkspaceDescriptor,
        prettyPrinted: Bool = false
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        return try encoder.encode(
            Envelope(schemaVersion: currentSchemaVersion, workspace: workspace)
        )
    }

    /// Decodes and validates a versioned workspace payload.
    public static func decode(_ data: Data) throws -> WorkspaceDescriptor {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == currentSchemaVersion else {
            throw PersistenceError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        let conflicts = envelope.workspace.folderRootConflicts()
        guard conflicts.isEmpty else {
            throw PersistenceError.invalidFolderRoots(conflicts)
        }
        return envelope.workspace
    }
}
