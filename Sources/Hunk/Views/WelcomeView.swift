import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 真实应用图标
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

            VStack(spacing: 5) {
                Text("Hunk")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(tr("轻量的 Git 预览编辑器", "A lightweight Git preview editor"))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 14)

            Button {
                vm.openRepoPanel()
            } label: {
                Label(tr("打开仓库…", "Open Repository…"), systemImage: "folder.badge.plus")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .padding(.top, 22)

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
                .padding(.top, 26)
            }

            Spacer()

            // 拖拽提示（拖入由 ContentView 的 dropDestination 接住，欢迎页直接打开）
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                Text(tr("把仓库文件夹拖到这里直接打开", "Drop a repository folder here to open it"))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
