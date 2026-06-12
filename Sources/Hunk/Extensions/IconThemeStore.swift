import Foundation
import AppKit

/// 文件图标主题：解析 VS Code 图标主题清单（如 Material Icon Theme），
/// 按文件名/扩展名/目录名查 SVG，用 NSImage（CoreSVG）原生渲染。
final class IconThemeStore: ObservableObject {
    static let shared = IconThemeStore()

    /// 当前激活主题的图标查找表；nil 表示用内置 SF Symbols。
    @Published private(set) var activeManifest: Manifest?
    @Published private(set) var autoInstallAttempted = false

    private var manifestDirectory: URL?
    private var imageCache = NSCache<NSString, NSImage>()

    struct Manifest: Decodable {
        struct Definition: Decodable {
            let iconPath: String?
        }
        let iconDefinitions: [String: Definition]
        let file: String?
        let folder: String?
        let folderExpanded: String?
        let fileExtensions: [String: String]?
        let fileNames: [String: String]?
        let folderNames: [String: String]?
        let folderNamesExpanded: [String: String]?
    }

    private init() {
        loadActive()
    }

    // MARK: - 激活与启动

    /// 依据 SettingsStore.iconThemeID 加载查找表：
    /// "" = 自动（取第一个已安装图标主题），"sf" = 内置，其余按 id 匹配。
    func loadActive() {
        let id = SettingsStore.shared.iconThemeID
        guard id != "sf" else {
            setManifest(nil, directory: nil)
            return
        }
        let available = ExtensionStore.shared.installed.flatMap(\.iconThemes)
        let ref = id.isEmpty ? available.first : available.first { $0.id == id }
        guard let ref else {
            setManifest(nil, directory: nil)
            return
        }
        let extensionDir = ExtensionStore.shared.extensionDirectory(for: ref.extensionID)
        let manifestURL = extensionDir.appendingPathComponent(ref.manifestPath).standardizedFileURL
        guard let manifest = try? JSONC.decode(Manifest.self, from: manifestURL) else {
            setManifest(nil, directory: nil)
            return
        }
        setManifest(manifest, directory: manifestURL.deletingLastPathComponent())
    }

    private func setManifest(_ manifest: Manifest?, directory: URL?) {
        let apply = {
            self.manifestDirectory = directory
            self.imageCache.removeAllObjects()
            self.activeManifest = manifest
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// 首次启动自动安装 Material Icon Theme（文件图标默认走 open-vsx）。
    /// 已安装则直接生效（"" 自动模式会选中它）；失败静默回退 SF Symbols，下次启动再试。
    func bootstrap() {
        guard !autoInstallAttempted else { return }
        autoInstallAttempted = true

        let hasIconTheme = ExtensionStore.shared.installed.contains { !$0.iconThemes.isEmpty }
        if hasIconTheme {
            loadActive()
            return
        }
        // 用户显式选择了内置图标时不再自动下载
        guard SettingsStore.shared.iconThemeID != "sf" else { return }
        Task {
            if await ExtensionStore.shared.install("PKief.material-icon-theme") != nil {
                self.loadActive()
            }
        }
    }

    // MARK: - 查找

    func icon(forFileName fileName: String, isDirectory: Bool, expanded: Bool) -> NSImage? {
        guard let manifest = activeManifest else { return nil }
        let key: String?
        if isDirectory {
            let lower = fileName.lowercased()
            if expanded {
                key = manifest.folderNamesExpanded?[lower]
                    ?? manifest.folderNames?[lower]
                    ?? manifest.folderExpanded
                    ?? manifest.folder
            } else {
                key = manifest.folderNames?[lower] ?? manifest.folder
            }
        } else {
            key = definitionKey(forFileName: fileName, manifest: manifest)
        }
        guard let key else { return nil }
        return image(forDefinition: key, manifest: manifest)
    }

    private func definitionKey(forFileName fileName: String, manifest: Manifest) -> String? {
        let lower = fileName.lowercased()
        if let key = manifest.fileNames?[lower] { return key }
        // 多段扩展名按最长后缀优先匹配："a.spec.ts" → "spec.ts" → "ts"
        let parts = lower.split(separator: ".").map(String.init)
        if parts.count > 1 {
            for index in 1..<parts.count {
                let suffix = parts[index...].joined(separator: ".")
                if let key = manifest.fileExtensions?[suffix] { return key }
            }
        }
        return manifest.file
    }

    private func image(forDefinition key: String, manifest: Manifest) -> NSImage? {
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached
        }
        guard let directory = manifestDirectory,
              let iconPath = manifest.iconDefinitions[key]?.iconPath
        else { return nil }
        let url = directory.appendingPathComponent(iconPath).standardizedFileURL
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        imageCache.setObject(image, forKey: key as NSString)
        return image
    }
}
