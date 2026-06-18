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
        case .added: return ctr("已添加", "Added")
        case .modified: return ctr("已修改", "Modified")
        case .deleted: return ctr("已删除", "Deleted")
        case .renamed: return ctr("已重命名", "Renamed")
        case .copied: return ctr("已复制", "Copied")
        case .typeChanged: return ctr("类型变更", "Type changed")
        case .untracked: return ctr("未跟踪", "Untracked")
        case .conflicted: return ctr("冲突", "Conflicted")
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

/// 一个 git 工作树（git worktree）。主工作树 + 若干链接工作树。
public struct Worktree: Identifiable, Hashable, Sendable {
    public let path: String          // 工作树绝对路径
    public let branch: String?       // 检出的分支短名；分离 HEAD 时为 nil
    public let head: String          // HEAD 短 hash（分离 HEAD 也有值）
    public let isMain: Bool          // 是否主工作树（git worktree list 第一条）
    public let isCurrent: Bool       // 是否当前窗口打开的这个
    public let isLocked: Bool        // 是否被锁定
    public let isPrunable: Bool      // 孤立、可被 prune

    public init(path: String, branch: String?, head: String, isMain: Bool,
                isCurrent: Bool, isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isCurrent = isCurrent
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// 分支名，分离 HEAD 时退回短 hash。
    public var refName: String { branch ?? head }
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

/// 一个 git 标签。`isAnnotated` 区分附注标签(-a，有 tagger/消息)与轻量标签。
public struct Tag: Identifiable, Hashable, Sendable {
    public let name: String
    public let target: String       // 指向的提交短 hash
    public let isAnnotated: Bool
    public let subject: String       // 附注标签的消息标题；轻量标签为目标提交标题

    public init(name: String, target: String, isAnnotated: Bool, subject: String) {
        self.name = name
        self.target = target
        self.isAnnotated = isAnnotated
        self.subject = subject
    }

    public var id: String { name }
}
