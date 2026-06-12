import SwiftUI

/// 内置文件图标：SF Symbols + 按文件类型着色。
/// （task 4 接入 open-vsx 图标主题后，此处作为默认与回退方案。）
enum FileIcon {

    struct Style {
        let symbol: String
        let color: Color
    }

    static func directory(expanded: Bool = false) -> Style {
        Style(symbol: expanded ? "folder" : "folder.fill", color: .accentColor.opacity(0.8))
    }

    static func style(forFileName name: String) -> Style {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension

        switch lower {
        case "dockerfile": return Style(symbol: "shippingbox", color: .blue)
        case "makefile": return Style(symbol: "hammer", color: .orange)
        case "license", "license.md", "license.txt": return Style(symbol: "text.justify.left", color: .secondary)
        case ".gitignore", ".gitattributes", ".gitmodules": return Style(symbol: "arrow.triangle.branch", color: .orange)
        case "package.swift": return Style(symbol: "swift", color: .orange)
        case "package.json", "package-lock.json": return Style(symbol: "cube.box", color: .green)
        default: break
        }

        switch ext {
        case "swift":
            return Style(symbol: "swift", color: .orange)
        case "js", "mjs", "cjs":
            return Style(symbol: "curlybraces", color: .yellow)
        case "jsx", "tsx":
            return Style(symbol: "atom", color: .cyan)
        case "ts":
            return Style(symbol: "curlybraces", color: .blue)
        case "py":
            return Style(symbol: "chevron.left.forwardslash.chevron.right", color: .blue)
        case "rb":
            return Style(symbol: "diamond", color: .red)
        case "go":
            return Style(symbol: "chevron.left.forwardslash.chevron.right", color: .cyan)
        case "rs":
            return Style(symbol: "gearshape.2", color: .orange)
        case "java", "kt", "kts", "scala", "groovy":
            return Style(symbol: "cup.and.saucer", color: .red)
        case "c", "h":
            return Style(symbol: "c.square", color: .blue)
        case "cpp", "cc", "cxx", "hpp", "hh":
            return Style(symbol: "plus.square", color: .blue)
        case "m", "mm":
            return Style(symbol: "chevron.left.forwardslash.chevron.right", color: .blue)
        case "cs":
            return Style(symbol: "number.square", color: .purple)
        case "php":
            return Style(symbol: "chevron.left.forwardslash.chevron.right", color: .indigo)
        case "sh", "bash", "zsh", "fish":
            return Style(symbol: "terminal", color: .green)
        case "html", "htm":
            return Style(symbol: "chevron.left.forwardslash.chevron.right", color: .orange)
        case "xml", "plist", "svg":
            return Style(symbol: "chevron.left.forwardslash.chevron.right", color: .teal)
        case "css", "scss", "less":
            return Style(symbol: "paintbrush", color: .blue)
        case "vue", "svelte":
            return Style(symbol: "v.square", color: .green)
        case "json", "jsonc":
            return Style(symbol: "curlybraces.square", color: .yellow)
        case "yaml", "yml", "toml", "ini", "conf":
            return Style(symbol: "gearshape", color: .secondary)
        case "md", "markdown", "rst":
            return Style(symbol: "text.document", color: .blue)
        case "txt", "log":
            return Style(symbol: "doc.text", color: .secondary)
        case "sql", "db", "sqlite":
            return Style(symbol: "cylinder.split.1x2", color: .teal)
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "ico", "icns", "heic", "tiff":
            return Style(symbol: "photo", color: .purple)
        case "pdf":
            return Style(symbol: "doc.richtext", color: .red)
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return Style(symbol: "archivebox", color: .brown)
        case "mp4", "mov", "avi", "mkv", "webm":
            return Style(symbol: "film", color: .pink)
        case "mp3", "wav", "flac", "aac", "ogg":
            return Style(symbol: "music.note", color: .pink)
        case "ttf", "otf", "woff", "woff2":
            return Style(symbol: "textformat", color: .secondary)
        case "lock":
            return Style(symbol: "lock", color: .secondary)
        case "xcodeproj", "xcworkspace":
            return Style(symbol: "hammer", color: .blue)
        default:
            return Style(symbol: "doc", color: .secondary)
        }
    }

    /// 是否可以用图片方式预览。
    static func isImage(_ name: String) -> Bool {
        let ext = ((name.lowercased()) as NSString).pathExtension
        return ["png", "jpg", "jpeg", "gif", "bmp", "webp", "ico", "icns", "heic", "tiff", "svg"].contains(ext)
    }
}

/// 变更种类的徽标颜色（与 VS Code 一致的语义色）。
import HunkCore

extension ChangeKind {
    var color: Color {
        switch self {
        case .added, .untracked: return .green
        case .modified, .renamed, .copied, .typeChanged: return .orange
        case .deleted: return .red
        case .conflicted: return .purple
        }
    }

    var localizedName: String {
        switch self {
        case .added: return tr("已添加", "Added")
        case .modified: return tr("已修改", "Modified")
        case .deleted: return tr("已删除", "Deleted")
        case .renamed: return tr("已重命名", "Renamed")
        case .copied: return tr("已复制", "Copied")
        case .typeChanged: return tr("类型变更", "Type Changed")
        case .untracked: return tr("未跟踪", "Untracked")
        case .conflicted: return tr("冲突", "Conflict")
        }
    }
}
