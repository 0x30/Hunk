import Foundation
import AppKit

/// open-vsx.org 扩展安装管理：下载 vsix（本质是 zip），解压后只消费
/// 其中的声明式资产（图标主题 / 颜色主题 JSON 与 SVG），不运行任何扩展代码。
final class ExtensionStore: ObservableObject {
    static let shared = ExtensionStore()

    struct ThemeRef: Identifiable, Hashable {
        let extensionID: String
        let label: String
        let manifestPath: String  // 相对 extension 目录
        var id: String { "\(extensionID)/\(label)" }
    }

    struct InstalledExtension: Identifiable {
        let id: String          // namespace.name
        let displayName: String
        let directory: URL      // …/extensions/<id>/extension
        let iconThemes: [ThemeRef]
        let colorThemes: [ThemeRef]
    }

    @Published private(set) var installed: [InstalledExtension] = []
    @Published private(set) var busyInstalling: String?
    @Published var lastError: String?

    let rootDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Hunk/extensions", isDirectory: true)
    }()

    private init() {
        loadInstalled()
    }

    // MARK: - 已安装扫描

    func loadInstalled() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else {
            installed = []
            return
        }
        var result: [InstalledExtension] = []
        for entry in entries {
            let extensionDir = entry.appendingPathComponent("extension", isDirectory: true)
            if let ext = Self.parseExtension(id: entry.lastPathComponent, directory: extensionDir) {
                result.append(ext)
            }
        }
        installed = result.sorted { $0.id < $1.id }
    }

    private struct PackageManifest: Decodable {
        struct Contributes: Decodable {
            struct ThemeEntry: Decodable {
                let label: String?
                let id: String?
                let path: String
            }
            let iconThemes: [ThemeEntry]?
            let themes: [ThemeEntry]?
        }
        let name: String?
        let displayName: String?
        let contributes: Contributes?
    }

    private static func parseExtension(id: String, directory: URL) -> InstalledExtension? {
        let packageURL = directory.appendingPathComponent("package.json")
        guard let manifest = try? JSONC.decode(PackageManifest.self, from: packageURL) else { return nil }
        // displayName 可能是 "%ext.displayName%" 这类占位符，直接退回扩展名
        var displayName = manifest.displayName ?? manifest.name ?? id
        if displayName.hasPrefix("%") { displayName = manifest.name ?? id }

        func refs(_ entries: [PackageManifest.Contributes.ThemeEntry]?) -> [ThemeRef] {
            (entries ?? []).map {
                ThemeRef(extensionID: id, label: $0.label ?? $0.id ?? id, manifestPath: $0.path)
            }
        }
        return InstalledExtension(
            id: id,
            displayName: displayName,
            directory: directory,
            iconThemes: refs(manifest.contributes?.iconThemes),
            colorThemes: refs(manifest.contributes?.themes)
        )
    }

    func extensionDirectory(for extensionID: String) -> URL {
        rootDirectory.appendingPathComponent(extensionID).appendingPathComponent("extension", isDirectory: true)
    }

    // MARK: - 安装 / 卸载

    /// 安装扩展，`reference` 形如 "PKief.material-icon-theme"。
    @discardableResult
    func install(_ reference: String) async -> InstalledExtension? {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            await setError(tr("扩展标识格式应为 namespace.name", "Extension reference should be namespace.name"))
            return nil
        }
        let (namespace, name) = (parts[0], parts[1])
        let id = "\(namespace).\(name)"

        await MainActor.run { busyInstalling = id }
        defer { Task { @MainActor in self.busyInstalling = nil } }

        do {
            // 1. 元数据
            let apiURL = URL(string: "https://open-vsx.org/api/\(namespace)/\(name)")!
            let (metaData, metaResponse) = try await URLSession.shared.data(from: apiURL)
            guard (metaResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            struct Metadata: Decodable {
                let files: [String: String]
            }
            let metadata = try JSONDecoder().decode(Metadata.self, from: metaData)
            guard let download = metadata.files["download"], let downloadURL = URL(string: download) else {
                throw URLError(.badURL)
            }

            // 2. 下载 vsix
            let (vsixURL, _) = try await URLSession.shared.download(from: downloadURL)

            // 3. 解压（vsix 即 zip）
            let targetDir = rootDirectory.appendingPathComponent(id, isDirectory: true)
            let fm = FileManager.default
            try? fm.removeItem(at: targetDir)
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            try await Self.unzip(vsixURL, to: targetDir)
            try? fm.removeItem(at: vsixURL)

            let parsed = Self.parseExtension(id: id, directory: targetDir.appendingPathComponent("extension"))
            await MainActor.run {
                self.loadInstalled()
                self.lastError = nil
            }
            return parsed
        } catch {
            await setError(tr("下载失败：", "Download failed: ") + error.localizedDescription)
            return nil
        }
    }

    func uninstall(_ extensionID: String) {
        try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(extensionID))
        loadInstalled()
    }

    @MainActor
    private func setError(_ message: String) {
        lastError = message
    }

    private static func unzip(_ archive: URL, to directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", "-q", archive.path, "-d", directory.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    // unzip 对 vsix 常见的轻微告警返回 1，仍算成功
                    if process.terminationStatus <= 1 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: GitProcessError.unzipFailed(process.terminationStatus))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    enum GitProcessError: Error, LocalizedError {
        case unzipFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .unzipFailed(let code):
                return tr("解压 vsix 失败（退出码 \(code)）", "Failed to unzip vsix (exit code \(code))")
            }
        }
    }
}
