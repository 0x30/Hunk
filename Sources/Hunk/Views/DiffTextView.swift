import SwiftUI
import AppKit
import HunkCore

// MARK: - 只读 diff 文本视图（统一视图）
//
// 用一个只读 NSTextView 渲染整块 unified diff —— 它「就是一个编辑器，只是不能编辑」：
// 原生选择 / 双击选词 / 拖选 / ⌘C 复制都白来。两个额外能力：
//   1. 复制时自动剥掉左侧行号槽（diffGutter 属性标记），只拷代码本身。
//   2. 选区覆盖到的「改动行」实时映射成 selectedLineIDs —— 拖选几行正好驱动
//      既有的「暂存这些行」逻辑（用户要的就是这个）。
// 行背景的整行 +/- 着色用自绘（boundingRect 撑满整行宽），不靠 per-row GeometryReader，
// 也就绕开了老拖选实现把内存撑爆的坑。

/// 标记左侧行号槽的字符：复制时据此剔除，只保留代码。
extension NSAttributedString.Key {
    static let diffGutter = NSAttributedString.Key("hunk.diffGutter")
}

/// 一行（视觉行）在文本里的范围 + 它对应的 diff 行身份。
private struct DiffLineSpan {
    let range: NSRange          // 行内容 + 行尾换行（分栏视图不再含行号槽）
    let lineID: Int?            // 改动行才有；上下文/块头为 nil
    let kind: DiffLineKind?
    var isFiller = false        // 分栏视图里某侧没有对应行的占位空行（画淡灰）
    var displayNumber: Int? = nil  // 分栏视图：该行要在固定行号槽（ruler）里画的号
}

private enum DiffSide { case left, right }

struct DiffTextView: NSViewRepresentable {
    let diff: FileDiff
    let filePath: String
    let fontSize: CGFloat
    let themeID: String
    /// 选区是否驱动行级暂存（未跟踪文件 = false：可复制但不参与暂存）
    let selectable: Bool
    @ObservedObject var settings: SettingsStore
    /// 选区覆盖到的改动行集合变化时回调（驱动「暂存这些行」）
    let onSelectChangedLines: (Set<Int>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        // 规范化的 NSTextView-in-scrollview 装配：显式 storage/layoutManager/container +
        // 初始 frame=contentSize，避免裸 init 的零 frame 导致不显示/不可选。
        let contentSize = scroll.contentSize
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: contentSize.width,
                                                              height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = SelectableDiffTextView(frame: NSRect(origin: .zero, size: contentSize),
                                              textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.allowsUndo = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.rebuildIfNeeded(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuildIfNeeded(self)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DiffTextView
        weak var textView: SelectableDiffTextView?
        private var contentKey: String = ""
        private var buildToken = 0

        init(_ parent: DiffTextView) { self.parent = parent }

        /// 内容签名变了才重建（diff/主题/字号）。
        func rebuildIfNeeded(_ p: DiffTextView) {
            let key = "\(p.filePath)|\(p.themeID)|\(p.fontSize)|\(p.diff.hashValue)"
            guard key != contentKey else { return }
            contentKey = key
            rebuild(p)
        }

        private func rebuild(_ p: DiffTextView) {
            guard let textView else { return }
            let font = NSFont.monospacedSystemFont(ofSize: max(9, p.fontSize), weight: .regular)
            // 主线程快照配色，后台只做纯计算
            let colors = Dictionary(uniqueKeysWithValues:
                TokenType.allCases.map { ($0, NSColor(p.settings.tokenColor(for: $0))) })
            buildToken += 1
            let token = buildToken
            let diff = p.diff
            let filePath = p.filePath
            DispatchQueue.global(qos: .userInitiated).async {
                let built = DiffTextBuilder.build(diff: diff, filePath: filePath, font: font, tokenColors: colors)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let textView = self.textView, token == self.buildToken else { return }
                    textView.applyBuilt(built, font: font)
                    // 重建后清掉旧选区映射
                    self.parent.onSelectChangedLines([])
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, parent.selectable else { return }
            let sel = textView.selectedRange()
            guard sel.length > 0 else { parent.onSelectChangedLines([]); return }
            var ids = Set<Int>()
            for span in textView.lineSpans where span.kind == .addition || span.kind == .deletion {
                if let id = span.lineID, NSIntersectionRange(span.range, sel).length > 0 {
                    ids.insert(id)
                }
            }
            parent.onSelectChangedLines(ids)
        }
    }
}

// MARK: - NSTextView 子类：剥行号槽复制 + 整行 +/- 自绘

final class SelectableDiffTextView: NSTextView {
    fileprivate var lineSpans: [DiffLineSpan] = []
    fileprivate var addColor = NSColor.systemGreen.withAlphaComponent(0.13)
    fileprivate var delColor = NSColor.systemRed.withAlphaComponent(0.13)
    fileprivate var fillerColor = NSColor.gray.withAlphaComponent(0.06)

    fileprivate func applyBuilt(_ built: DiffTextBuilder.Result, font: NSFont) {
        lineSpans = built.spans
        textStorage?.setAttributedString(built.attributed)
        self.font = font
        setSelectedRange(NSRange(location: 0, length: 0))
        needsDisplay = true
        // 行号槽宽度由分栏协调器统一设置（两列同宽），这里只触发重绘
        (enclosingScrollView?.verticalRulerView as? DiffGutterRuler)?.needsDisplay = true
    }

    /// 整行 +/- 底色：自绘撑满整行宽（背景属性只覆盖字形，不够整齐）。
    override func draw(_ dirtyRect: NSRect) {
        if let lm = layoutManager, let tc = textContainer, !lineSpans.isEmpty {
            let inset = textContainerInset
            for span in lineSpans {
                let color: NSColor
                switch span.kind {
                case .addition: color = addColor
                case .deletion: color = delColor
                default: color = span.isFiller ? fillerColor : .clear
                }
                if color == .clear { continue }
                let glyphRange = lm.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
                var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                rect.origin.x = 0
                rect.origin.y += inset.height
                rect.size.width = bounds.width
                guard rect.intersects(dirtyRect) else { continue }
                color.setFill()
                rect.fill()
            }
        }
        super.draw(dirtyRect)
    }

    /// ⌘C / 复制：跳过行号槽（diffGutter）字符，只拷代码本身。
    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0, let storage = textStorage else { super.copy(sender); return }
        let out = NSMutableString()
        storage.enumerateAttribute(.diffGutter, in: sel, options: []) { value, range, _ in
            if (value as? Bool) == true { return }     // 行号槽：跳过
            out.append(storage.attributedSubstring(from: range).string)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out as String, forType: .string)
    }
}

// MARK: - 构建 diff 富文本（后台线程，纯计算）

enum DiffTextBuilder {
    fileprivate struct Result {
        let attributed: NSAttributedString
        let spans: [DiffLineSpan]
    }

    /// 单行超过此长度不 tokenize（minified：慢且无收益）。
    private static let maxHighlightLength = 2000

    fileprivate static func build(diff: FileDiff, filePath: String, font: NSFont,
                                  tokenColors: [TokenType: NSColor]) -> Result {
        let storage = NSMutableAttributedString()
        var spans: [DiffLineSpan] = []
        let language = Lexer.language(forFileName: (filePath as NSString).lastPathComponent)

        // 行号槽宽度：按全 diff 最大行号对齐
        let allLines = diff.hunks.flatMap(\.lines)
        let maxOld = allLines.compactMap(\.oldNumber).max() ?? 0
        let maxNew = allLines.compactMap(\.newNumber).max() ?? 0
        let wOld = max(String(maxOld).count, 2)
        let wNew = max(String(maxNew).count, 2)

        let gutterColor = NSColor.tertiaryLabelColor
        let textColor = NSColor.labelColor
        let headerColor = NSColor.secondaryLabelColor

        func append(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            storage.append(NSAttributedString(string: s, attributes: attrs))
        }
        func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
        }

        for hunk in diff.hunks {
            // 块头：@@ -a,b +c,d @@ heading
            let lineStart = storage.length
            let headerText = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            let heading = hunk.sectionHeading.isEmpty ? "" : " \(hunk.sectionHeading)"
            // 行号槽占位（标记 gutter，复制时剥掉），保持与下方代码列对齐
            append(pad("", wOld) + " " + pad("", wNew) + "  ",
                   [.font: font, .diffGutter: true, .foregroundColor: gutterColor])
            append(headerText + heading + "\n",
                   [.font: font, .foregroundColor: headerColor])
            spans.append(DiffLineSpan(range: NSRange(location: lineStart, length: storage.length - lineStart),
                                      lineID: nil, kind: nil))

            for line in hunk.lines {
                let start = storage.length
                let marker: String
                let markerColor: NSColor
                switch line.kind {
                case .addition: marker = "+"; markerColor = .systemGreen
                case .deletion: marker = "-"; markerColor = .systemRed
                case .context:  marker = " "; markerColor = gutterColor
                }
                // 行号槽：旧号 新号 标记（整体标 gutter，复制时剥掉）
                append(pad(line.oldNumber.map(String.init) ?? "", wOld) + " "
                       + pad(line.newNumber.map(String.init) ?? "", wNew) + " ",
                       [.font: font, .diffGutter: true, .foregroundColor: gutterColor])
                append(marker + " ",
                       [.font: font, .diffGutter: true, .foregroundColor: markerColor])
                // 代码本体（语法高亮）
                appendCode(line.text, into: storage, font: font, baseColor: textColor,
                           language: language, tokenColors: tokenColors)
                append("\n", [.font: font, .foregroundColor: textColor])
                spans.append(DiffLineSpan(range: NSRange(location: start, length: storage.length - start),
                                          lineID: line.id, kind: line.kind))
            }
        }
        return Result(attributed: storage, spans: spans)
    }

    /// 构建分栏视图的某一列（左=旧/删除，右=新/新增）。两列行数一致（每个 SplitRow 一行，
    /// 缺失侧画占位空行），配同步滚动即左右对齐。
    /// 行号不进正文——交给固定的 DiffGutterRuler 画（横滑不动、不被选中）；也不画 +/-（靠红绿底色区分）。
    fileprivate static func buildSplit(diff: FileDiff, side: DiffSide, filePath: String,
                                       font: NSFont, tokenColors: [TokenType: NSColor]) -> Result {
        let storage = NSMutableAttributedString()
        var spans: [DiffLineSpan] = []
        let language = Lexer.language(forFileName: (filePath as NSString).lastPathComponent)

        let textColor = NSColor.labelColor
        let headerColor = NSColor.secondaryLabelColor

        func append(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            storage.append(NSAttributedString(string: s, attributes: attrs))
        }

        for hunk in diff.hunks {
            // 块头：左列显示 @@…，右列同高空行，保持两列对齐
            let hs = storage.length
            if side == .left {
                let heading = hunk.sectionHeading.isEmpty ? "" : " \(hunk.sectionHeading)"
                append("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(heading)\n",
                       [.font: font, .foregroundColor: headerColor])
            } else {
                append("\n", [.font: font, .foregroundColor: headerColor])
            }
            spans.append(DiffLineSpan(range: NSRange(location: hs, length: storage.length - hs), lineID: nil, kind: nil))

            for row in hunk.splitRows {
                let cell = side == .left ? row.left : row.right
                let start = storage.length
                if let line = cell {
                    let num = side == .left ? line.oldNumber : line.newNumber
                    appendCode(line.text, into: storage, font: font, baseColor: textColor,
                               language: language, tokenColors: tokenColors)
                    append("\n", [.font: font, .foregroundColor: textColor])
                    let staged = (side == .left && line.kind == .deletion) || (side == .right && line.kind == .addition)
                    spans.append(DiffLineSpan(range: NSRange(location: start, length: storage.length - start),
                                              lineID: staged ? line.id : nil, kind: line.kind, displayNumber: num))
                } else {
                    // 该侧无对应行：占位空行（画淡灰）
                    append("\n", [.font: font, .foregroundColor: textColor])
                    spans.append(DiffLineSpan(range: NSRange(location: start, length: storage.length - start),
                                              lineID: nil, kind: nil, isFiller: true))
                }
            }
        }
        return Result(attributed: storage, spans: spans)
    }

    private static func appendCode(_ text: String, into storage: NSMutableAttributedString,
                                   font: NSFont, baseColor: NSColor,
                                   language: LanguageDef?, tokenColors: [TokenType: NSColor]) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColor]
        guard let language, text.count <= maxHighlightLength, !text.isEmpty else {
            storage.append(NSAttributedString(string: text, attributes: attrs))
            return
        }
        let piece = NSMutableAttributedString(string: text, attributes: attrs)
        for token in Lexer.tokenize(text, language: language) {
            guard let color = tokenColors[token.type],
                  token.range.location >= 0,
                  token.range.location + token.range.length <= piece.length
            else { continue }
            piece.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        storage.append(piece)
    }
}

// MARK: - 分栏 diff 的固定行号槽

/// 分栏视图每列左侧的行号标尺：行号画在这里而不是正文里，
/// 因此横向滚动时不动、也不会被文本选区选中。底色与对应代码行的红/绿一致。
final class DiffGutterRuler: NSRulerView {
    private weak var diffTextView: SelectableDiffTextView?

    init(scrollView: NSScrollView, textView: SelectableDiffTextView) {
        self.diffTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() { needsDisplay = true }

    /// 行号用比代码略小、更淡的字，读作「槽」而非与代码抢戏。
    private var gutterFont: NSFont {
        let codeSize = diffTextView?.font?.pointSize ?? 11
        return NSFont.monospacedDigitSystemFont(ofSize: max(9, codeSize - 2), weight: .regular)
    }
    private var charWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: gutterFont]).width
    }

    /// 按给定最大行号定宽（两列传同一个值即可同宽，避免错位）。
    func refresh(maxLineNumber: Int) {
        let digits = max(2, String(max(0, maxLineNumber)).count)
        ruleThickness = CGFloat(digits) * charWidth + 14
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = diffTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }

        // 底色与代码区一致；不画分隔线
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let visibleRect = tv.visibleRect
        let inset = tv.textContainerInset
        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutterFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visibleGlyphs = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        for span in tv.lineSpans {
            if NSMaxRange(span.range) <= visibleChars.location { continue }
            if span.range.location >= NSMaxRange(visibleChars) { break }

            let glyphRange = lm.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            let fragRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let y = fragRect.minY + inset.height - visibleRect.minY

            // 行底色：与代码行的红/绿/占位灰对齐
            let tint: NSColor?
            switch span.kind {
            case .addition: tint = tv.addColor
            case .deletion: tint = tv.delColor
            default:        tint = span.isFiller ? tv.fillerColor : nil
            }
            if let tint {
                tint.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: fragRect.height).fill()
            }

            if let number = span.displayNumber {
                let text = "\(number)" as NSString
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: bounds.width - size.width - 5,
                                      y: y + (fragRect.height - size.height) / 2),
                          withAttributes: attrs)
            }
        }
    }
}

// MARK: - 分栏只读 diff（两列同步滚动，各自可选可复制）

struct SplitDiffTextView: NSViewRepresentable {
    let diff: FileDiff
    let filePath: String
    let fontSize: CGFloat
    let themeID: String
    let selectable: Bool
    @ObservedObject var settings: SettingsStore
    let onSelectChangedLines: (Set<Int>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let (leftScroll, leftTV) = Self.makeColumn(delegate: context.coordinator)
        let (rightScroll, rightTV) = Self.makeColumn(delegate: context.coordinator)
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = .separatorColor

        for v in [leftScroll, divider, rightScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            leftScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftScroll.topAnchor.constraint(equalTo: container.topAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rightScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightScroll.topAnchor.constraint(equalTo: container.topAnchor),
            rightScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rightScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightScroll.widthAnchor.constraint(equalTo: leftScroll.widthAnchor),
        ])

        let c = context.coordinator
        c.leftView = leftTV; c.rightView = rightTV
        c.leftScroll = leftScroll; c.rightScroll = rightScroll
        c.setupSync()
        c.rebuildIfNeeded(self)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuildIfNeeded(self)
    }

    /// 一列：不换行（保证两列逐行对齐）、可纵横滚动、只读可选。
    private static func makeColumn(delegate: NSTextViewDelegate) -> (NSScrollView, SelectableDiffTextView) {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // 短内容也给橡皮筋回弹（纵向）
        scroll.verticalScrollElasticity = .allowed
        let contentSize = scroll.contentSize
        let storage = NSTextStorage()
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = false
        lm.addTextContainer(tc)
        let tv = SelectableDiffTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: tc)
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = false
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.allowsUndo = false
        tv.delegate = delegate
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = []
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv

        // 固定行号槽：横滑不动、不在选区内
        let ruler = DiffGutterRuler(scrollView: scroll, textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return (scroll, tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SplitDiffTextView
        weak var leftView: SelectableDiffTextView?
        weak var rightView: SelectableDiffTextView?
        weak var leftScroll: NSScrollView?
        weak var rightScroll: NSScrollView?
        private var contentKey = ""
        private var buildToken = 0
        private var syncing = false
        private var leftSel = Set<Int>()
        private var rightSel = Set<Int>()

        init(_ parent: SplitDiffTextView) { self.parent = parent }

        func setupSync() {
            guard let l = leftScroll?.contentView, let r = rightScroll?.contentView else { return }
            l.postsBoundsChangedNotifications = true
            r.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(leftScrolled),
                                                   name: NSView.boundsDidChangeNotification, object: l)
            NotificationCenter.default.addObserver(self, selector: #selector(rightScrolled),
                                                   name: NSView.boundsDidChangeNotification, object: r)
        }

        @objc private func leftScrolled() { mirror(from: leftScroll, to: rightScroll) }
        @objc private func rightScrolled() { mirror(from: rightScroll, to: leftScroll) }

        /// 纵向 + 横向同步：把 from 的偏移镜像到 to（左右滑动两列一起动，行号槽固定不动）。
        private func mirror(from: NSScrollView?, to: NSScrollView?) {
            guard !syncing, let from, let to else { return }
            syncing = true
            let origin = from.contentView.bounds.origin
            let cur = to.contentView.bounds.origin
            if abs(cur.x - origin.x) > 0.5 || abs(cur.y - origin.y) > 0.5 {
                to.contentView.scroll(to: origin)
                to.reflectScrolledClipView(to.contentView)
            }
            syncing = false
        }

        func rebuildIfNeeded(_ p: SplitDiffTextView) {
            let key = "\(p.filePath)|\(p.themeID)|\(p.fontSize)|\(p.diff.hashValue)"
            guard key != contentKey else { return }
            contentKey = key
            rebuild(p)
        }

        private func rebuild(_ p: SplitDiffTextView) {
            guard let leftView, let rightView else { return }
            let font = NSFont.monospacedSystemFont(ofSize: max(9, p.fontSize), weight: .regular)
            let colors = Dictionary(uniqueKeysWithValues:
                TokenType.allCases.map { ($0, NSColor(p.settings.tokenColor(for: $0))) })
            buildToken += 1; let token = buildToken
            let diff = p.diff; let filePath = p.filePath
            leftSel = []; rightSel = []
            DispatchQueue.global(qos: .userInitiated).async {
                let l = DiffTextBuilder.buildSplit(diff: diff, side: .left, filePath: filePath,
                                                   font: font, tokenColors: colors)
                let r = DiffTextBuilder.buildSplit(diff: diff, side: .right, filePath: filePath,
                                                   font: font, tokenColors: colors)
                DispatchQueue.main.async { [weak self] in
                    guard let self, token == self.buildToken,
                          let lv = self.leftView, let rv = self.rightView else { return }
                    lv.applyBuilt(l, font: font)
                    rv.applyBuilt(r, font: font)
                    // 两列行号槽统一按全局最大行号定宽，避免左右槽宽不一造成错位
                    let maxNum = diff.hunks.flatMap(\.lines).reduce(0) {
                        max($0, max($1.oldNumber ?? 0, $1.newNumber ?? 0))
                    }
                    (self.leftScroll?.verticalRulerView as? DiffGutterRuler)?.refresh(maxLineNumber: maxNum)
                    (self.rightScroll?.verticalRulerView as? DiffGutterRuler)?.refresh(maxLineNumber: maxNum)
                    self.parent.onSelectChangedLines([])
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard parent.selectable, let tv = notification.object as? SelectableDiffTextView else { return }
            let ids = changedIDs(in: tv)
            if tv === leftView { leftSel = ids } else if tv === rightView { rightSel = ids }
            parent.onSelectChangedLines(leftSel.union(rightSel))
        }

        private func changedIDs(in tv: SelectableDiffTextView) -> Set<Int> {
            let sel = tv.selectedRange()
            guard sel.length > 0 else { return [] }
            var ids = Set<Int>()
            for span in tv.lineSpans where span.kind == .addition || span.kind == .deletion {
                if let id = span.lineID, NSIntersectionRange(span.range, sel).length > 0 { ids.insert(id) }
            }
            return ids
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
