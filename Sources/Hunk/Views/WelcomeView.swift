import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Hunk")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(tr("轻量的 Git 预览编辑器", "A lightweight Git preview editor"))
                    .foregroundStyle(.secondary)
            }

            Button {
                vm.openRepoPanel()
            } label: {
                Label(tr("打开仓库…", "Open Repository…"), systemImage: "folder.badge.plus")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)

            if !vm.recentRepos.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("最近打开", "Recent"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    ForEach(vm.recentRepos, id: \.self) { path in
                        Button {
                            Task { await vm.open(URL(fileURLWithPath: path)) }
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text((path as NSString).lastPathComponent)
                                Text((path as NSString).deletingLastPathComponent)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
