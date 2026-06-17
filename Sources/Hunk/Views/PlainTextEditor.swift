import SwiftUI
import AppKit
import HunkCore

/// NSTextView 桥接的纯文本编辑器：等宽字体、关闭所有自动替换、
/// 防抖语法高亮、冲突块背景标色。没有补全，没有诊断——刻意如此。
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fileName: String
    var conflicts: [ConflictBlock] = []
    @Binding var scrollToLine: Int?
    var blameText: String?
    /// 当前光标行所属提交 hash（committed 行才有）；行内注解悬浮/点击弹提交卡用。
    var blameHash: String?
    /// 取提交详情（喂给悬浮卡）。
    var commitDetailProvider: (String) async -> Repository.CommitDetail? = { _ in nil }
    /// 「查看此提交」：在历史详情打开。
    var onViewCommit: (Repository.CommitDetail) -> Void = { _ in }
    var onEdit: () -> Void
    var onCursorLineChange: (Int) -> Void = { _ in }
    /// 光标/选中变化：(行, 列, 选中行数)，喂给底部状态栏
    var onSelectionInfo: (Int, Int, Int) -> Void = { _, _, _ in }
    /// 高亮语言扩展名覆盖；nil = 按 fileName 推断（新建未保存文件可手动指定）
    var languageOverride: String?
    /// 为真时编辑器挂载后抢键盘焦点（⌘N 新建文件）；消费后回调清空。
    var requestFocus: Bool = false
    var onFocusHandled: () -> Void = {}

    /// 行高:按设置里的倍数(默认 1.3)。等宽字体默认行距偏紧,调大更透气。
    static func lineParagraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = SettingsStore.shared.editorLineHeight
        return p
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 自建滚动结构以使用 OverscrollTextView：
        // 文本视图自身把高度撑到「文本 + 0.6 屏」，底部留白属于文本视图，
        // 点击留白光标自然落到文末、指针保持 I-beam，无需任何手势转发。
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        let textView = OverscrollTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        // 不让系统按安全区自动加 inset（避免标尺画进顶部栏下方）
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.postsFrameChangedNotifications = true

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = SettingsStore.shared.editorNSFont
        textView.defaultParagraphStyle = PlainTextEditor.lineParagraphStyle()
        textView.typingAttributes[.paragraphStyle] = PlainTextEditor.lineParagraphStyle()
        textView.delegate = context.coordinator

        // 行号 gutter
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        // 光标行尾的 blame 注解（可悬浮/点击弹出提交卡）
        let blameLabel = BlameLabel()
        blameLabel.font = .systemFont(ofSize: 11)
        blameLabel.textColor = .tertiaryLabelColor
        blameLabel.drawsBackground = false
        blameLabel.isBezeled = false
        blameLabel.isEditable = false
        blameLabel.isSelectable = false
        blameLabel.isHidden = true
        textView.addSubview(blameLabel)
        context.coordinator.blameLabel = blameLabel

        // blame 提交卡浮窗控制器：悬浮预览 + 点击钉住
        let popover = CommitPopoverController()
        popover.fetch = { [weak coordinator = context.coordinator] hash in
            guard let coordinator else { return nil }
            return await coordinator.parent.commitDetailProvider(hash)
        }
        popover.onViewCommit = { [weak coordinator = context.coordinator] detail in
            coordinator?.parent.onViewCommit(detail)
        }
        context.coordinator.commitPopover = popover
        blameLabel.onHover = { [weak blameLabel, weak popover] inside in
            guard let blameLabel, let popover, let hash = blameLabel.commitHash else {
                popover?.hoverExited(); return
            }
            if inside { popover.hoverEntered(hash: hash, relativeTo: blameLabel.bounds, of: blameLabel) }
            else { popover.hoverExited() }
        }
        blameLabel.onClick = { [weak blameLabel, weak popover] in
            guard let blameLabel, let popover, let hash = blameLabel.commitHash else { return }
            popover.clicked(hash: hash, relativeTo: blameLabel.bounds, of: blameLabel)
        }

        context.coordinator.textView = textView
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        context.coordinator.updateOverscroll()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updateOverscroll()
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // 输入法合成期间（有 marked text）不重置 string，否则会打断中文/日文等输入法合成
        if textView.string != text, !textView.hasMarkedText() {
            let isNewDocument = coordinator.lastFileName != fileName
            coordinator.lastFileName = fileName
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: isNewDocument ? 0 : min(selected.location, length), length: 0))
            // 防抖高亮（与打字路径一致）：快速切文件时合并成一次，不再每次切换都
            // 在主线程同步整文件 tokenize+全量上色——那是「切换卡死」的主因之一。
            // 字体是等宽、已就位，延迟的只是语法配色，可读性不受影响。
            coordinator.scheduleHighlight()
            if isNewDocument {
                // 新文档从顶部开始（底部 overscroll inset 会把初始位置带偏）
                DispatchQueue.main.async {
                    textView.scroll(NSPoint(x: 0, y: -scrollView.contentInsets.top))
                }
            }
        }

        let font = SettingsStore.shared.editorNSFont
        if textView.font != font {
            textView.font = font
            coordinator.highlightNow()
        } else if coordinator.lastConflicts != conflicts {
            coordinator.highlightNow()
        } else if coordinator.lastThemeName != ThemeStore.shared.active?.name {
            // 颜色主题切换后重新着色
            coordinator.highlightNow()
        } else if coordinator.lastLanguageOverride != languageOverride {
            // 手动切换语言后重新着色
            coordinator.highlightNow()
        } else if coordinator.lastLineHeight != SettingsStore.shared.editorLineHeight {
            // 行高设置改变后重新应用段落样式
            textView.defaultParagraphStyle = PlainTextEditor.lineParagraphStyle()
            textView.typingAttributes[.paragraphStyle] = PlainTextEditor.lineParagraphStyle()
            coordinator.highlightNow()
        }

        if let line = scrollToLine {
            coordinator.scroll(toLine: line)
            DispatchQueue.main.async {
                self.scrollToLine = nil
            }
        }

        if requestFocus {
            // 等本轮布局结束再夺焦点,避免被同一轮的其它焦点变更覆盖;消费后回调清空标志
            let handled = onFocusHandled
            DispatchQueue.main.async { [weak textView] in
                if let textView, let window = textView.window, window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
                handled()
            }
        }

        coordinator.updateBlame(text: blameText)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        weak var blameLabel: BlameLabel?
        var commitPopover: CommitPopoverController?
        var lastConflicts: [ConflictBlock] = []
        var lastThemeName: String?
        var lastFileName: String?
        var lastLanguageOverride: String?
        var lastLineHeight: Double = 0
        private var lastBlameText: String?
        private var lastCursorLine = -1
        private var pendingHighlight: DispatchWorkItem?

        init(parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit()
            ruler?.invalidateLineIndex()
            scheduleHighlight()
        }

        /// 底部留约半屏空白，末行可以滚到视野中上部。
        @objc func scrollViewFrameChanged() {
            updateOverscroll()
        }

        func updateOverscroll() {
            guard let textView = textView as? OverscrollTextView,
                  let scrollView = textView.enclosingScrollView else { return }
            let target = max(0, scrollView.contentSize.height * 0.6)
            if abs(textView.overscroll - target) > 1 {
                textView.overscroll = target
                textView.setFrameSize(textView.frame.size)  // 走重写逻辑刷新高度
            }
        }

        /// 编辑器是否持有键盘焦点——blame 注解只在用户聚焦编辑后才出现
        private var editorFocused: Bool {
            guard let textView else { return false }
            return textView.window?.firstResponder === textView
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let ruler else { return }
            // 输入法合成中不上报光标/选区，避免触发重绘打断输入法
            if textView.hasMarkedText() { return }
            guard editorFocused else {
                blameLabel?.isHidden = true
                return
            }
            let sel = textView.selectedRange()
            let caret = sel.location
            let line = ruler.lineNumber(forCharacterPublic: caret)
            // 列 = 光标相对本行行首的字符数 + 1；选中跨越的行数
            let nsString = textView.string as NSString
            let lineStart = nsString.lineRange(for: NSRange(location: min(caret, nsString.length), length: 0)).location
            let column = caret - lineStart + 1
            let selectedLines = sel.length == 0 ? 0
                : ruler.lineNumber(forCharacterPublic: max(caret, NSMaxRange(sel) - 1)) - line + 1
            parent.onSelectionInfo(line, column, selectedLines)
            if line != lastCursorLine {
                lastCursorLine = line
                blameLabel?.isHidden = true  // 移动后先隐藏，等新结果
                commitPopover?.close()       // 注解锚点要移动了，收起旧浮窗
                parent.onCursorLineChange(line)
            }
            positionBlameLabel()
        }

        func updateBlame(text: String?) {
            // hash 随行变化，先同步给注解（点击/悬浮时读它）
            blameLabel?.commitHash = parent.blameHash
            guard text != lastBlameText else { return }
            lastBlameText = text
            guard let blameLabel else { return }
            if let text, !text.isEmpty, editorFocused {
                blameLabel.stringValue = text
                blameLabel.sizeToFit()
                blameLabel.isHidden = false
                positionBlameLabel()
            } else {
                blameLabel.isHidden = true
                commitPopover?.close()
            }
        }

        private func positionBlameLabel() {
            guard let textView, let blameLabel, !blameLabel.isHidden,
                  let layoutManager = textView.layoutManager
            else { return }
            let nsString = textView.string as NSString
            guard nsString.length > 0 else {
                blameLabel.isHidden = true
                return
            }
            let caret = min(textView.selectedRange().location, nsString.length - 1)
            let glyph = layoutManager.glyphIndexForCharacter(at: caret)
            guard glyph < layoutManager.numberOfGlyphs || layoutManager.numberOfGlyphs > 0 else { return }
            let safeGlyph = min(glyph, max(0, layoutManager.numberOfGlyphs - 1))
            let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: safeGlyph, effectiveRange: nil)
            let inset = textView.textContainerInset
            blameLabel.setFrameOrigin(NSPoint(
                x: fragment.maxX + inset.width + 28,
                y: fragment.minY + inset.height + (fragment.height - blameLabel.frame.height) / 2
            ))
        }

        func scheduleHighlight() {
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.highlightNow()
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        func highlightNow() {
            guard let textView, let storage = textView.textStorage else { return }
            let string = textView.string
            let nsString = string as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            let settings = SettingsStore.shared

            // 超大文件跳过高亮，保持编辑流畅
            guard nsString.length < 400_000 else { return }

            lastConflicts = parent.conflicts

            let theme = ThemeStore.shared
            lastThemeName = theme.active?.name
            textView.backgroundColor = theme.editorBackground ?? .textBackgroundColor
            textView.insertionPointColor = theme.editorForeground ?? .labelColor
            ruler?.invalidateLineIndex()

            lastLineHeight = settings.editorLineHeight
            storage.beginEditing()
            storage.setAttributes([
                .font: settings.editorNSFont,
                .foregroundColor: theme.editorForeground ?? NSColor.labelColor,
                .paragraphStyle: PlainTextEditor.lineParagraphStyle(),
            ], range: fullRange)

            lastLanguageOverride = parent.languageOverride
            let langDef = parent.languageOverride.flatMap { Lexer.language(forFileExtension: $0) }
                ?? Lexer.language(forFileName: parent.fileName)
            if let language = langDef {
                for token in Lexer.tokenize(string, language: language) {
                    guard NSMaxRange(token.range) <= nsString.length else { continue }
                    storage.addAttribute(
                        .foregroundColor,
                        value: settings.tokenNSColor(for: token.type),
                        range: token.range
                    )
                }
            }

            applyConflictBackgrounds(storage: storage, nsString: nsString)
            storage.endEditing()
        }

        /// 为冲突块上背景色：当前侧绿色、传入侧蓝色、标记行灰色。
        private func applyConflictBackgrounds(storage: NSTextStorage, nsString: NSString) {
            guard !parent.conflicts.isEmpty else { return }
            let lineRanges = Self.lineRanges(of: nsString)

            func range(forLines from: Int, _ to: Int) -> NSRange? {
                guard from <= to, from >= 0, to < lineRanges.count else { return nil }
                let start = lineRanges[from].location
                let end = NSMaxRange(lineRanges[to])
                return NSRange(location: start, length: end - start)
            }

            for block in parent.conflicts {
                guard block.endLine < lineRanges.count else { continue }
                // 在块内找分隔行
                var separatorLine = block.startLine
                for lineIndex in block.startLine...block.endLine {
                    let lineText = nsString.substring(with: lineRanges[lineIndex])
                    if lineText.hasPrefix("=======") {
                        separatorLine = lineIndex
                        break
                    }
                }

                let markerColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18)
                let currentColor = NSColor.systemGreen.withAlphaComponent(0.13)
                let incomingColor = NSColor.systemBlue.withAlphaComponent(0.13)

                if let r = range(forLines: block.startLine, block.startLine) {
                    storage.addAttribute(.backgroundColor, value: markerColor, range: r)
                }
                if separatorLine > block.startLine + 1,
                   let r = range(forLines: block.startLine + 1, separatorLine - 1) {
                    storage.addAttribute(.backgroundColor, value: currentColor, range: r)
                }
                if let r = range(forLines: separatorLine, separatorLine) {
                    storage.addAttribute(.backgroundColor, value: markerColor, range: r)
                }
                if separatorLine + 1 <= block.endLine - 1,
                   let r = range(forLines: separatorLine + 1, block.endLine - 1) {
                    storage.addAttribute(.backgroundColor, value: incomingColor, range: r)
                }
                if let r = range(forLines: block.endLine, block.endLine) {
                    storage.addAttribute(.backgroundColor, value: markerColor, range: r)
                }
            }
        }

        func scroll(toLine line: Int) {
            guard let textView else { return }
            let nsString = textView.string as NSString
            let lineRanges = Self.lineRanges(of: nsString)
            guard line >= 0, line < lineRanges.count else { return }
            let range = NSRange(location: lineRanges[line].location, length: 0)
            textView.scrollRangeToVisible(range)
            textView.setSelectedRange(range)
            // 跳转后自动把焦点交给编辑器（全局搜索选中结果 / 冲突跳转）：光标停在目标行，
            // 可直接打字、上下浏览，不用再点一下编辑器。async 让它在本次布局结束后再夺取，
            // 避免被同一轮的其它焦点变更覆盖。
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        /// 每一行的 NSRange（含行内容，不含换行符）。
        static func lineRanges(of nsString: NSString) -> [NSRange] {
            var result: [NSRange] = []
            var location = 0
            while location <= nsString.length {
                let lineEnd: Int
                let searchRange = NSRange(location: location, length: nsString.length - location)
                let newline = nsString.range(of: "\n", options: [], range: searchRange)
                if newline.location == NSNotFound {
                    lineEnd = nsString.length
                    result.append(NSRange(location: location, length: lineEnd - location))
                    break
                } else {
                    lineEnd = newline.location
                    result.append(NSRange(location: location, length: lineEnd - location))
                    location = newline.location + 1
                }
            }
            return result
        }
    }
}

// MARK: - 底部留白文本视图

/// 高度始终为「文本实际高度 + overscroll」（且不小于视口），
/// 让底部留白属于文本视图本身：I-beam 指针、点击落焦文末都是原生行为。
final class OverscrollTextView: NSTextView {
    var overscroll: CGFloat = 0
    private var resizing = false

    override func setFrameSize(_ newSize: NSSize) {
        guard !resizing, overscroll > 0,
              let layoutManager, let textContainer
        else {
            super.setFrameSize(newSize)
            return
        }
        resizing = true
        defer { resizing = false }
        // 不强制全量排版（大文件会把主线程卡死数秒）：
        // 用渐进布局当前已知的高度，TextKit 后台排版推进时会再次回调本方法，高度自然收敛
        let used = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        let minHeight = enclosingScrollView?.contentSize.height ?? 0
        super.setFrameSize(NSSize(width: newSize.width, height: max(used + overscroll, minHeight)))
    }

    /// 粘贴从访达复制的文件时插入其绝对路径（而非系统默认的文件名）；
    /// 多个文件按行分隔。普通文本粘贴走原生行为。
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path).joined(separator: "\n")
            insertText(paths, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    // MARK: - 标识符级单词边界（abc.efg 拆成 abc / efg）

    // 系统默认把 `abc.efg`、`3.14` 这类当成一个整词（句点算词内字符），
    // 双击 / ⌥←→ / ⌥⇧←→ 会一次吞掉整段。代码里更想按标识符切：
    // 词 = 字母/数字/下划线（含 CJK 等非 ASCII 文字），其余标点皆为分隔符。
    // 重写选词与按词移动/扩选/删除，让它们都用这套边界。

    /// 连续两次按词扩选之间保持的锚点；其它任何改选区的动作都会清空它（见 setSelectedRanges）。
    private static let wordAnchorKey = "OverscrollTextView.wordAnchor"

    private static func isWordChar(_ ch: unichar) -> Bool {
        if ch == 0x5F { return true }                       // _
        if let scalar = Unicode.Scalar(ch) {
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return true                                          // 代理对半个码元：当词内,别切进 emoji 中间
    }

    /// 从 index 向右到下一个词尾：先跳过分隔符,再跳过词字符。
    private func nextWordBoundary(from index: Int, in s: NSString) -> Int {
        var i = max(0, min(index, s.length))
        let n = s.length
        while i < n, !Self.isWordChar(s.character(at: i)) { i += 1 }
        while i < n, Self.isWordChar(s.character(at: i)) { i += 1 }
        return i
    }

    /// 从 index 向左到上一个词首：先跳过分隔符,再跳过词字符。
    private func prevWordBoundary(from index: Int, in s: NSString) -> Int {
        var i = max(0, min(index, s.length))
        while i > 0, !Self.isWordChar(s.character(at: i - 1)) { i -= 1 }
        while i > 0, Self.isWordChar(s.character(at: i - 1)) { i -= 1 }
        return i
    }

    /// 包含某位置的「同类字符段」范围:词字符段或分隔符段(双击选词用)。
    private func wordRange(at index: Int, in s: NSString) -> NSRange {
        let n = s.length
        guard n > 0 else { return NSRange(location: 0, length: 0) }
        let pos = min(index, n - 1)
        let cls = Self.isWordChar(s.character(at: pos))
        var start = pos, end = pos + 1
        while start > 0, Self.isWordChar(s.character(at: start - 1)) == cls { start -= 1 }
        while end < n, Self.isWordChar(s.character(at: end)) == cls { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// 双击 / 按词拖选:用标识符边界覆盖系统默认选词。
    override func selectionRange(forProposedRange proposedCharRange: NSRange,
                                 granularity: NSSelectionGranularity) -> NSRange {
        guard granularity == .selectByWord else {
            return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        }
        let s = string as NSString
        guard s.length > 0 else { return proposedCharRange }
        let lower = wordRange(at: proposedCharRange.location, in: s)
        let upperIndex = NSMaxRange(proposedCharRange) > proposedCharRange.location
            ? NSMaxRange(proposedCharRange) - 1 : proposedCharRange.location
        let upper = wordRange(at: upperIndex, in: s)
        let start = min(lower.location, upper.location)
        let end = max(NSMaxRange(lower), NSMaxRange(upper))
        return NSRange(location: start, length: end - start)
    }

    // 锚点跟踪:只有连续按词扩选才保留锚点,其它改选区动作经此漏斗清空。
    private var wordAnchor: Int?
    private var inWordExtend = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        if !inWordExtend { wordAnchor = nil }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
    }

    private func moveCaretByWord(forward: Bool) {
        let s = string as NSString
        let sel = selectedRange()
        // 有选区时,移动从对应一端的边缘出发;无选区从光标出发
        let from = forward ? NSMaxRange(sel) : sel.location
        let target = forward ? nextWordBoundary(from: from, in: s) : prevWordBoundary(from: from, in: s)
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func extendSelectionByWord(forward: Bool) {
        let s = string as NSString
        let sel = selectedRange()
        let anchor: Int
        if let a = wordAnchor {
            anchor = a
        } else {
            anchor = forward ? sel.location : NSMaxRange(sel)   // 新一轮:锚定移动方向的反端
            wordAnchor = anchor
        }
        let active = sel.length == 0 ? anchor : (anchor == sel.location ? NSMaxRange(sel) : sel.location)
        let target = forward ? nextWordBoundary(from: active, in: s) : prevWordBoundary(from: active, in: s)
        let lower = min(anchor, target)
        let upper = max(anchor, target)
        inWordExtend = true
        setSelectedRange(NSRange(location: lower, length: upper - lower))
        inWordExtend = false
        scrollRangeToVisible(selectedRange())
    }

    private func deleteByWord(forward: Bool) {
        let s = string as NSString
        let sel = selectedRange()
        guard sel.length == 0 else { super.deleteBackward(nil); return }  // 有选区交还系统
        let target = forward ? nextWordBoundary(from: sel.location, in: s)
                             : prevWordBoundary(from: sel.location, in: s)
        let range = forward
            ? NSRange(location: sel.location, length: target - sel.location)
            : NSRange(location: target, length: sel.location - target)
        guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: 0))
    }

    // ⌥←→ 走 Right/Left 绑定(LTR 下 Right=Forward);Forward/Backward 一并覆盖以防其它绑定。
    override func moveWordRight(_ sender: Any?) { moveCaretByWord(forward: true) }
    override func moveWordLeft(_ sender: Any?) { moveCaretByWord(forward: false) }
    override func moveWordForward(_ sender: Any?) { moveCaretByWord(forward: true) }
    override func moveWordBackward(_ sender: Any?) { moveCaretByWord(forward: false) }
    override func moveWordRightAndModifySelection(_ sender: Any?) { extendSelectionByWord(forward: true) }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { extendSelectionByWord(forward: false) }
    override func moveWordForwardAndModifySelection(_ sender: Any?) { extendSelectionByWord(forward: true) }
    override func moveWordBackwardAndModifySelection(_ sender: Any?) { extendSelectionByWord(forward: false) }
    override func deleteWordForward(_ sender: Any?) { deleteByWord(forward: true) }
    override func deleteWordBackward(_ sender: Any?) { deleteByWord(forward: false) }
}

// MARK: - 行号 gutter

/// NSTextView 的行号标尺：缓存行起始偏移，滚动/编辑时按可见区域绘制。
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// 每行起始字符偏移（utf16），首元素恒为 0。
    private var lineStarts: [Int] = [0]
    private var lineIndexValid = false

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView

        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func needsRedraw() {
        needsDisplay = true
    }

    func invalidateLineIndex() {
        lineIndexValid = false
        needsDisplay = true
    }

    private func rebuildLineIndexIfNeeded() {
        guard !lineIndexValid, let textView else { return }
        let nsString = textView.string as NSString
        let length = nsString.length
        var starts: [Int] = [0]
        starts.reserveCapacity(max(16, length / 40))
        // 分块拷出 unichar 单遍扫描：比逐行 range(of:) 快一个数量级，大文件编辑不卡
        let chunkSize = 64 * 1024
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var location = 0
        while location < length {
            let count = min(chunkSize, length - location)
            nsString.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for i in 0..<count where buffer[i] == 0x0A {  // \n
                starts.append(location + i + 1)
            }
            location += count
        }
        lineStarts = starts
        lineIndexValid = true

        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * 8 + 14
    }

    /// 字符偏移所在行号（1 基），供光标 blame 使用。
    func lineNumber(forCharacterPublic location: Int) -> Int {
        rebuildLineIndexIfNeeded()
        return lineNumber(forCharacter: location)
    }

    /// 字符偏移所在行号（1 基）。
    private func lineNumber(forCharacter location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        rebuildLineIndexIfNeeded()

        // 底色与编辑器完全一致，不画分隔线，避免出现「边」
        let background = textView.backgroundColor
        background.setFill()
        bounds.fill()

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        guard glyphRange.length > 0 || (textView.string as NSString).length == 0 else { return }

        let numberColor = (ThemeStore.shared.editorForeground ?? .labelColor).withAlphaComponent(0.35)
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: max(9, SettingsStore.shared.editorFontSize - 3),
            weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: numberColor]
        let inset = textView.textContainerInset

        var lastDrawnLine = -1
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var fragmentGlyphRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphRange)
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            let line = lineNumber(forCharacter: charIndex)

            // 软换行的后续片段不重复编号
            if line != lastDrawnLine, lineStarts[line - 1] == charIndex {
                lastDrawnLine = line
                let y = fragmentRect.minY + inset.height - visibleRect.minY
                let text = "\(line)" as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(
                    at: NSPoint(x: bounds.width - size.width - 6, y: y + (fragmentRect.height - size.height) / 2),
                    withAttributes: attributes
                )
            }
            glyphIndex = NSMaxRange(fragmentGlyphRange)
        }

        // 末尾空行（文本以换行结尾时 layoutManager 有 extra fragment）
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fragmentRect = layoutManager.extraLineFragmentRect
            let line = lineStarts.count
            if line != lastDrawnLine {
                let y = fragmentRect.minY + inset.height - visibleRect.minY
                let text = "\(line)" as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(
                    at: NSPoint(x: bounds.width - size.width - 6, y: y + (fragmentRect.height - size.height) / 2),
                    withAttributes: attributes
                )
            }
        }
    }
}

// MARK: - 行内 blame 注解（可悬浮/点击弹提交卡）

/// 光标行尾的 blame 文字标签：committed 行（commitHash 非空）可悬浮预览、点击钉住提交卡。
final class BlameLabel: NSTextField {
    var commitHash: String? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        if commitHash != nil { onClick?() } else { super.mouseDown(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func resetCursorRects() {
        if commitHash != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

// MARK: - 提交卡浮窗控制器（悬浮预览 + 点击钉住）

/// 管理一个 NSPopover 承载 CommitCard：
/// 悬浮 0.35s 出预览（移开自动收，鼠标桥接进卡片不收）；点击钉住（外点才关）。
/// 仅在主线程使用（由 NSTextViewDelegate 回调驱动）。
final class CommitPopoverController {
    private let popover = NSPopover()
    private(set) var pinned = false
    private var currentHash: String?
    private var showWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var mouseInCard = false

    var fetch: ((String) async -> Repository.CommitDetail?)?
    var onViewCommit: ((Repository.CommitDetail) -> Void)?

    init() {
        popover.behavior = .transient   // 外点 / 切窗自动关
        popover.animates = false
    }

    func hoverEntered(hash: String, relativeTo rect: NSRect, of view: NSView) {
        cancelClose()
        guard !pinned else { return }
        if popover.isShown, currentHash == hash { return }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, view.window != nil else { return }
            self.present(hash: hash, relativeTo: rect, of: view, pin: false)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func hoverExited() {
        showWork?.cancel(); showWork = nil
        guard !pinned else { return }
        scheduleClose()
    }

    func clicked(hash: String, relativeTo rect: NSRect, of view: NSView) {
        showWork?.cancel(); showWork = nil
        cancelClose()
        if popover.isShown, currentHash == hash {
            pinned = true   // 预览已开着同一个 → 直接钉住，不重弹
            return
        }
        present(hash: hash, relativeTo: rect, of: view, pin: true)
    }

    func close() {
        showWork?.cancel(); showWork = nil
        cancelClose()
        pinned = false
        currentHash = nil
        mouseInCard = false
        if popover.isShown { popover.performClose(nil) }
    }

    private func present(hash: String, relativeTo rect: NSRect, of view: NSView, pin: Bool) {
        currentHash = hash
        pinned = pin
        let card = CommitCard(
            hash: hash,
            fetch: { [weak self] h in
                guard let fetch = self?.fetch else { return nil }
                return await fetch(h)
            },
            onViewCommit: { [weak self] detail in self?.onViewCommit?(detail) },
            onHoverChange: { [weak self] inside in
                guard let self else { return }
                self.mouseInCard = inside
                if inside { self.cancelClose() }
                else if !self.pinned { self.scheduleClose() }
            },
            onClose: { [weak self] in self?.close() }
        )
        let host = NSHostingController(rootView: card)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        guard view.window != nil, !popover.isShown else { return }
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    private func scheduleClose() {
        cancelClose()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.mouseInCard, !self.pinned { self.close() }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelClose() { closeWork?.cancel(); closeWork = nil }
}
