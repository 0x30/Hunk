import Foundation
import AppKit
import HunkCore

/// VS Code 颜色主题：解析主题 JSON 的 `colors` 与 `tokenColors`，
/// 把常用 TextMate scope 映射到内置词法器的 token 类型。
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    struct ActiveTheme {
        let name: String
        let isDark: Bool
        let editorBackground: NSColor?
        let editorForeground: NSColor?
        let tokenColors: [TokenType: NSColor]
    }

    @Published private(set) var active: ActiveTheme?

    private init() {
        loadActive()
    }

    // MARK: - 解析

    private struct ThemeFile: Decodable {
        struct TokenColor: Decodable {
            let scope: ScopeValue?
            let settings: Settings

            struct Settings: Decodable {
                let foreground: String?
            }

            enum ScopeValue: Decodable {
                case one(String)
                case many([String])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let single = try? container.decode(String.self) {
                        self = .one(single)
                    } else {
                        self = .many(try container.decode([String].self))
                    }
                }

                var scopes: [String] {
                    switch self {
                    case .one(let s): return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    case .many(let list): return list
                    }
                }
            }
        }

        let name: String?
        let type: String?
        let include: String?
        let colors: [String: String]?
        let tokenColors: [TokenColor]?
    }

    /// 依据 SettingsStore.themeID（"system" 或 "<extensionID>/<label>"）加载主题。
    func loadActive() {
        let id = SettingsStore.shared.themeID
        guard id != "system" else {
            publish(nil)
            return
        }
        guard let ref = ExtensionStore.shared.installed
            .flatMap(\.colorThemes)
            .first(where: { $0.id == id })
        else {
            publish(nil)
            return
        }
        let extensionDir = ExtensionStore.shared.extensionDirectory(for: ref.extensionID)
        let manifestURL = extensionDir.appendingPathComponent(ref.manifestPath).standardizedFileURL
        guard let theme = Self.load(url: manifestURL, depth: 0) else {
            publish(nil)
            return
        }

        let tokenColors = Self.mapTokenColors(theme.tokenColors ?? [])
        let active = ActiveTheme(
            name: theme.name ?? ref.label,
            isDark: (theme.type ?? "dark") == "dark",
            editorBackground: (theme.colors?["editor.background"]).flatMap(NSColor.fromHex),
            editorForeground: (theme.colors?["editor.foreground"]).flatMap(NSColor.fromHex),
            tokenColors: tokenColors
        )
        publish(active)
    }

    private func publish(_ theme: ActiveTheme?) {
        let apply = {
            self.active = theme
            // 整个应用的外观跟随主题明暗，避免深色编辑器配浅色窗口的割裂感
            if let theme {
                NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            } else {
                NSApp.appearance = nil  // 跟随系统
            }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// 处理主题文件的 include 链（被包含文件先加载，当前文件覆盖）。
    private static func load(url: URL, depth: Int) -> ThemeFile? {
        guard depth < 4, var theme = try? JSONC.decode(ThemeFile.self, from: url) else { return nil }
        if let include = theme.include {
            let includedURL = url.deletingLastPathComponent().appendingPathComponent(include).standardizedFileURL
            if let base = load(url: includedURL, depth: depth + 1) {
                var colors = base.colors ?? [:]
                for (key, value) in theme.colors ?? [:] { colors[key] = value }
                theme = ThemeFile(
                    name: theme.name ?? base.name,
                    type: theme.type ?? base.type,
                    include: nil,
                    colors: colors,
                    tokenColors: (base.tokenColors ?? []) + (theme.tokenColors ?? [])
                )
            }
        }
        return theme
    }

    /// 每个 token 类型在主题里找「最长 scope 前缀匹配」的颜色。
    private static func mapTokenColors(_ rules: [ThemeFile.TokenColor]) -> [TokenType: NSColor] {
        let desired: [TokenType: [String]] = [
            .comment: ["comment", "punctuation.definition.comment"],
            .string: ["string"],
            .keyword: ["keyword", "storage.type", "storage.modifier"],
            .number: ["constant.numeric", "constant.language"],
            .type: ["entity.name.type", "support.type", "support.class", "entity.name.class"],
        ]

        var best: [TokenType: (specificity: Int, color: NSColor)] = [:]
        for rule in rules {
            guard let foreground = rule.settings.foreground,
                  let color = NSColor.fromHex(foreground),
                  let scopes = rule.scope?.scopes
            else { continue }
            for ruleScope in scopes {
                for (tokenType, candidates) in desired {
                    for candidate in candidates {
                        let matches = candidate == ruleScope
                            || candidate.hasPrefix(ruleScope + ".")
                        guard matches else { continue }
                        let specificity = ruleScope.count
                        if specificity >= (best[tokenType]?.specificity ?? -1) {
                            best[tokenType] = (specificity, color)
                        }
                    }
                }
            }
        }
        return best.mapValues(\.color)
    }

    // MARK: - 查询

    func tokenNSColor(for type: TokenType) -> NSColor? {
        active?.tokenColors[type]
    }

    var editorBackground: NSColor? { active?.editorBackground }
    var editorForeground: NSColor? { active?.editorForeground }
}

extension NSColor {
    /// 解析 "#RGB" / "#RRGGBB" / "#RRGGBBAA"。
    static func fromHex(_ hex: String) -> NSColor? {
        var string = hex.trimmingCharacters(in: .whitespaces)
        guard string.hasPrefix("#") else { return nil }
        string.removeFirst()
        if string.count == 3 {
            string = string.map { "\($0)\($0)" }.joined()
        }
        guard string.count == 6 || string.count == 8,
              let value = UInt64(string, radix: 16)
        else { return nil }

        let r, g, b, a: CGFloat
        if string.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
