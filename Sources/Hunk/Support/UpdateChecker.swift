import SwiftUI
import AppKit

/// 检查 GitHub Releases 上的新版本。
/// CI 给每个 Release 打 `build-N` 标签并把 N 写进 CFBundleVersion，
/// 这里比对构建号决定是否提醒。
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "0x30/Hunk"

    struct ReleaseInfo {
        let build: Int
        let name: String
        let url: URL
    }

    /// 有比当前更新的版本时非空（驱动提醒弹窗）
    @Published var available: ReleaseInfo?
    /// 手动检查的结果提示（已最新 / 出错）
    @Published var checkResultMessage: String?

    private var checkedThisLaunch = false

    /// 当前构建号；开发构建（"dev"）为 nil。
    var currentBuild: Int? {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    /// 启动时静默检查一次（开发构建不打扰）。
    func checkAutomatically() {
        guard !checkedThisLaunch, currentBuild != nil else { return }
        checkedThisLaunch = true
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        struct GitHubRelease: Decodable {
            let tag_name: String
            let name: String?
            let html_url: String
        }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let latest = Int(release.tag_name.replacingOccurrences(of: "build-", with: "")),
                  let pageURL = URL(string: release.html_url)
            else { throw URLError(.cannotParseResponse) }

            let info = ReleaseInfo(build: latest, name: release.name ?? release.tag_name, url: pageURL)
            let skipped = UserDefaults.standard.integer(forKey: "skippedUpdateBuild")

            await MainActor.run {
                if let current = currentBuild {
                    if latest > current, userInitiated || latest != skipped {
                        available = info
                    } else if userInitiated {
                        checkResultMessage = tr("已是最新版本（构建 \(current)）", "You're up to date (build \(current))")
                    }
                } else if userInitiated {
                    // 开发构建：手动检查时直接给出最新版入口
                    available = info
                }
            }
        } catch {
            if userInitiated {
                await MainActor.run {
                    checkResultMessage = tr("检查更新失败：", "Update check failed: ") + error.localizedDescription
                }
            }
        }
    }

    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.build, forKey: "skippedUpdateBuild")
        available = nil
    }

    func openDownloadPage(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.url)
        available = nil
    }
}
