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
    if /usr/bin/pgrep -xq Hunk; then
        # 应用已在运行：走轻量通道直接送路径，
        # 绕开系统打开事件（每次会触发 LaunchServices 整库拷贝，内存尖峰数百 MB）
        CHANNEL_DIR="$HOME/Library/Application Support/Hunk"
        /bin/mkdir -p "$CHANNEL_DIR"
        printf '%s' "$TARGET" > "$CHANNEL_DIR/cli-open"
        /usr/bin/notifyutil -p app.hunk.cli.open
    else
        exec /usr/bin/open -a "Hunk" "$TARGET"
    fi
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
