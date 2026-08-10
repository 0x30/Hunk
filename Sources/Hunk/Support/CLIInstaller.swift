import Foundation
import AppKit

/// 安装 `hunk` 命令行工具到 /usr/local/bin（VS Code 式：菜单点击安装，一次管理员授权）。
enum CLIInstaller {
    static let installPath = "/usr/local/bin/hunk"

    private static let script = """
    #!/bin/sh
    # Hunk 命令行启动器
    # 用法：hunk            在 Hunk 中打开当前目录
    #       hunk <path>     在 Hunk 中打开指定目录或文件
    TARGET="${1:-.}"
    if [ -d "$TARGET" ]; then
        TARGET="$(cd "$TARGET" && pwd)"
    elif [ -f "$TARGET" ]; then
        DIR="$(cd "$(dirname "$TARGET")" && pwd)"
        TARGET="$DIR/$(basename "$TARGET")"
    else
        echo "hunk: 路径不存在: $TARGET" >&2
        exit 1
    fi
    # 走轻量通道送路径，再普通激活/启动应用。open 不带文件参数：带文件会走系统 odoc
    # 打开事件，冷启动时 SwiftUI 不建窗口、路径无处落地（且每次触发 LaunchServices
    # 整库拷贝的内存尖峰）。先写隐藏临时文件再原子改名，避免应用读到半截路径；
    # 每次请求使用独立文件，连续调用也不会互相覆盖。
    CHANNEL_DIR="$HOME/Library/Application Support/Hunk"
    /bin/mkdir -p "$CHANNEL_DIR"
    TEMP=$(/usr/bin/mktemp "$CHANNEL_DIR/.cli-open.XXXXXX") || exit 1
    if ! printf '%s' "$TARGET" > "$TEMP"; then
        /bin/rm -f "$TEMP"
        exit 1
    fi
    REQUEST="$CHANNEL_DIR/cli-open.$(/bin/date +%s).$$"
    /bin/mv "$TEMP" "$REQUEST" || exit 1
    /usr/bin/notifyutil -p "app.hunk.cli.open" >/dev/null 2>&1 || true
    exec /usr/bin/open -a "Hunk"
    """

    /// 写临时文件后以管理员权限拷入 /usr/local/bin。
    static func install() -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hunk-cli")
        do {
            try script.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            return tr("安装失败：", "Install failed: ") + error.localizedDescription
        }

        let shell = "mkdir -p /usr/local/bin && cp '\(temp.path)' '\(installPath)' && chmod 755 '\(installPath)'"
        let appleScript = "do shell script \"\(shell)\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo)
        try? FileManager.default.removeItem(at: temp)

        if let errorInfo, let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return tr("安装失败：", "Install failed: ") + message
        }
        return tr(
            "已安装 hunk 命令到 \(installPath)。\n\n用法：\nhunk          打开当前目录\nhunk <path>   打开指定目录或文件",
            "Installed hunk to \(installPath).\n\nUsage:\nhunk          open current directory\nhunk <path>   open a directory or file"
        )
    }
}
