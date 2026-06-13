import AppKit

/// AppKit 接管「文件 → 最近打开」子菜单：每项用 attributedTitle 做两行
/// （项目名在上、灰色父路径在下），SwiftUI 的 Commands 菜单做不到多行。
///
/// SwiftUI 拥有文件菜单，会在 menuNeedsUpdate 时重建它、挤掉第三方插入的项。
/// 这里用 delegate 代理：接管文件菜单的 delegate，先转发给 SwiftUI 原 delegate
/// 让它更新自己的项，再把「最近打开」补回正确位置——稳赢这个时序竞争。
@MainActor
final class RecentMenuController: NSObject, NSMenuDelegate {
    static let shared = RecentMenuController()

    private let recentItem = NSMenuItem()
    private weak var originalFileDelegate: NSMenuDelegate?

    override init() {
        super.init()
        let submenu = NSMenu()
        submenu.delegate = self
        recentItem.submenu = submenu
    }

    /// 接管文件菜单的 delegate 并插入「最近打开」；幂等，可重复调用。
    /// SwiftUI 若整体替换了文件菜单实例，会在这里重新接管。
    func install() {
        guard let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu else { return }
        recentItem.title = tr("最近打开", "Open Recent")
        if fileMenu.delegate !== self {
            originalFileDelegate = fileMenu.delegate
            fileMenu.delegate = self
        }
        ensureInserted(in: fileMenu)
    }

    /// 把「最近打开」放到「打开仓库…」（⌘O）之后。
    private func ensureInserted(in fileMenu: NSMenu) {
        guard recentItem.menu !== fileMenu else { return }
        if let idx = fileMenu.items.firstIndex(where: {
            $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == .command
        }) {
            fileMenu.insertItem(recentItem, at: idx + 1)
        } else {
            fileMenu.addItem(recentItem)
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentItem.submenu {
            rebuildRecentItems(menu)
            return
        }
        // 文件菜单：先让 SwiftUI 更新它管理的项（可能 removeAll 重建），再补回「最近打开」
        originalFileDelegate?.menuNeedsUpdate?(menu)
        ensureInserted(in: menu)
    }

    private func rebuildRecentItems(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = (UserDefaults.standard.stringArray(forKey: "recentRepos") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }

        guard !recents.isEmpty else {
            let empty = NSMenuItem(title: tr("暂无最近记录", "No Recent Items"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for path in recents {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.attributedTitle = Self.twoLineTitle(path: path)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: tr("清除菜单", "Clear Menu"),
                               action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// 两行标题：项目名（正常字号）+ 换行 + 父路径（小字灰色，home 缩成 ~）。
    private static func twoLineTitle(path: String) -> NSAttributedString {
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let result = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: para,
            ]
        )
        result.append(NSAttributedString(
            string: "\n" + parent,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ]
        ))
        return result
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        CLIOpenRouter.route(path)  // 复用命令行路由：已开则聚焦，否则新窗口
    }

    @objc private func clearRecent() {
        UserDefaults.standard.removeObject(forKey: "recentRepos")
    }
}
