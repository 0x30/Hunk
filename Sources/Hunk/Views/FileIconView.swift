import SwiftUI

/// 文件/目录图标统一入口：优先用 open-vsx 图标主题（如 Material Icon Theme），
/// 主题未安装或没有匹配时回退到 SF Symbols 映射。
struct FileIconView: View {
    let fileName: String
    var isDirectory = false
    var expanded = false

    @ObservedObject private var iconStore = IconThemeStore.shared

    var body: some View {
        if let image = iconStore.icon(forFileName: fileName, isDirectory: isDirectory, expanded: expanded) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            let style = isDirectory
                ? FileIcon.directory(expanded: expanded)
                : FileIcon.style(forFileName: fileName)
            Image(systemName: style.symbol)
                .font(.system(size: 12))
                .foregroundStyle(style.color)
                .frame(width: 16, height: 16)
        }
    }
}
