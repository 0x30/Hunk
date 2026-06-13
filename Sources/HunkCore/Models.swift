import Foundation

/// 一处文件变更的种类（暂存区或工作区维度）。
public enum ChangeKind: String, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted

    /// 列表行尾的单字母徽标，与 VS Code 一致。
    public var badge: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    public var displayName: String {
        switch self {
        case .added: return "已添加"
        case .modified: return "已修改"
        case .deleted: return "已删除"
        case .renamed: return "已重命名"
        case .copied: return "已复制"
        case .typeChanged: return "类型变更"
        case .untracked: return "未跟踪"
        case .conflicted: return "冲突"
        }
    }
}

/// `git status` 中的一个条目。staged / unstaged 两个维度独立，
/// 同一文件可同时出现在两个区域（部分暂存）。
public struct FileChange: Identifiable, Hashable, Sendable {
    public let path: String      // 当前路径（重命名后的新路径）
    public let oldPath: String?  // 重命名/复制前的旧路径
    public let staged: ChangeKind?
    public let unstaged: ChangeKind?

    public init(path: String, oldPath: String? = nil, staged: ChangeKind?, unstaged: ChangeKind?) {
        self.path = path
        self.oldPath = oldPath
        self.staged = staged
        self.unstaged = unstaged
    }

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
    public var isConflicted: Bool { unstaged == .conflicted }
}

public struct Branch: Identifiable, Hashable, Sendable {
    public let name: String
    public let isCurrent: Bool
    /// 是否已合并进当前分支（HEAD 可达）
    public let isMerged: Bool

    public init(name: String, isCurrent: Bool, isMerged: Bool = false) {
        self.name = name
        self.isCurrent = isCurrent
        self.isMerged = isMerged
    }

    public var id: String { name }
}

public struct Stash: Identifiable, Hashable, Sendable {
    public let index: Int
    public let message: String

    public init(index: Int, message: String) {
        self.index = index
        self.message = message
    }

    public var id: Int { index }
    public var ref: String { "stash@{\(index)}" }
}

/// 当前分支相对上游的同步状态。
public struct SyncStatus: Hashable, Sendable {
    public let upstream: String?  // 如 origin/main；nil 表示没有上游
    public let ahead: Int         // 待推送
    public let behind: Int        // 待拉取

    public init(upstream: String?, ahead: Int, behind: Int) {
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}
