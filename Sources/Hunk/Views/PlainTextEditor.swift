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
    /// 行高倍数(由设置传入)。作为显式参数而非在内部读全局——这样改设置时它是真正的
    /// SwiftUI 依赖,会触发 updateNSView 重新应用;否则编辑器收不到变更。
    var lineHeight: Double = 1.3
    /// 改动标记基线（文件 HEAD 版本）；nil = 不画标记。与当前文本做行级 diff。
    var baseline: String?
    /// 是否在行号槽画改动标记（绿增/蓝改/红删）。
    var showChangeGutter: Bool = true
    /// 是否高亮选中单词的其它整词匹配。
    var highlightOccurrences: Bool = true

    /// 行高:按倍数生成段落样式。等宽字体默认行距偏紧,调大更透气。
    ///
    /// 用「固定像素行高」(min==max) 而非 lineHeightMultiple:
    /// - 倍数会随行内最高字体放大,SF Mono 没有中文字形会回退到苹方,
    ///   导致夹了中文的行突然变高;固定值则与回退字体无关,每行等高。
    /// - lineHeightMultiple 只撑大行框、光标仍按字体自然高顶端对齐(下方留空,
    ///   看着比行矮);固定行高时光标会撑满整行。
    static func lineParagraphStyle(_ multiple: Double, font: NSFont) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let h = ceil((font.ascender - font.descender + font.leading) * multiple)
        p.minimumLineHeight = h
        p.maximumLineHeight = h
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
        let editorFont = SettingsStore.shared.editorNSFont
        textView.font = editorFont
        textView.defaultParagraphStyle = PlainTextEditor.lineParagraphStyle(lineHeight, font: editorFont)
        textView.typingAttributes[.paragraphStyle] = PlainTextEditor.lineParagraphStyle(lineHeight, font: editorFont)
        textView.delegate = context.coordinator
        // 惰性布局：只排版可见区域，大文件不再一次性全文布局（卡死主因之一）
        textView.layoutManager?.allowsNonContiguousLayout = true

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
            coordinator.invalidateLineCache()
            let nsText = text as NSString
            let length = nsText.length
            // 大文件 或 含超长行(SQL dump 常见)→ 关软换行改水平滚动:超长行软换行布局是卡死主因。
            // length>1MB 时短路,不再扫超长行;小文件才扫一遍(O(n) 很快)。
            let largeFile = length > 1_000_000 || Coordinator.hasLongLine(nsText, threshold: 20_000)
            coordinator.applyWrapping(largeFile: largeFile, scrollView: scrollView)
            textView.setSelectedRange(NSRange(location: isNewDocument ? 0 : min(selected.location, length), length: 0))
            // 防抖高亮（与打字路径一致）：快速切文件时合并成一次，不再每次切换都
            // 在主线程同步整文件 tokenize+全量上色——那是「切换卡死」的主因之一。
            // 字体是等宽、已就位，延迟的只是语法配色，可读性不受影响。
            coordinator.scheduleHighlight()
            coordinator.clearOccurrenceHighlights()  // 换内容旧高亮作废
            coordinator.scheduleGutterDiff()
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
        } else if coordinator.lastLineHeight != lineHeight {
            // 行高设置改变后重新应用段落样式
            let editorFont = SettingsStore.shared.editorNSFont
            textView.defaultParagraphStyle = PlainTextEditor.lineParagraphStyle(lineHeight, font: editorFont)
            textView.typingAttributes[.paragraphStyle] = PlainTextEditor.lineParagraphStyle(lineHeight, font: editorFont)
            coordinator.highlightNow()
        }

        // 基线变化 / 开关切换 → 重算改动标记
        if coordinator.lastBaseline != baseline || coordinator.lastShowChangeGutter != showChangeGutter {
            coordinator.lastBaseline = baseline
            coordinator.lastShowChangeGutter = showChangeGutter
            coordinator.scheduleGutterDiff()
        }
        // 同词高亮开关切换 → 立即应用或清除
        if coordinator.lastHighlightOccurrences != highlightOccurrences {
            coordinator.lastHighlightOccurrences = highlightOccurrences
            if highlightOccurrences { coordinator.updateOccurrenceHighlights() }
            else { coordinator.clearOccurrenceHighlights() }
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
        var lastBaseline: String?
        var lastShowChangeGutter = true
        var lastHighlightOccurrences = true
        private var lastBlameText: String?
        private var lastCursorLine = -1
        private var pendingHighlight: DispatchWorkItem?
        private var pendingGutterDiff: DispatchWorkItem?
        private var cachedLineRanges: [NSRange]?
        private var isHighlighting = false
        /// 当前已应用同词高亮的范围（临时属性，clear 时逐个撤销）
        private var occurrenceRanges: [NSRange] = []

        init(parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit()
            ruler?.invalidateLineIndex()
            invalidateLineCache()
            clearOccurrenceHighlights()  // 编辑后旧范围失配，先清；选区变化会重算
            scheduleHighlight()
            scheduleGutterDiff()
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
            updateOccurrenceHighlights()
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
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: safeGlyph, effectiveRange: nil)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: safeGlyph, effectiveRange: nil)
            let glyphLoc = layoutManager.location(forGlyphAt: safeGlyph)
            let inset = textView.textContainerInset
            // 注解(11pt 系统字)与代码(等宽字、字号更大)按「基线对齐」才视觉居中：
            // 两种字号若按 frame 盒子居中，NSTextField 的单元内边距会让小字偏上/偏下。
            // glyphLoc.y 是该字形基线相对所在行片段顶部的偏移；firstBaselineOffsetFromTop
            // 是标签自身文字基线相对其顶部的偏移，两者相减即让两条基线落在同一水平线。
            let codeBaselineY = lineRect.minY + inset.height + glyphLoc.y
            blameLabel.setFrameOrigin(NSPoint(
                x: usedRect.maxX + inset.width + 28,
                y: codeBaselineY - blameLabel.firstBaselineOffsetFromTop
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

        // MARK: - 改动标记（行号槽竖线）

        func scheduleGutterDiff() {
            pendingGutterDiff?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.computeGutterDiff() }
            pendingGutterDiff = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }

        /// 基线与当前文本做行级 diff，把 hunk 交给标尺绘制。计算放后台线程，应用回主线程。
        private func computeGutterDiff() {
            guard let ruler else { return }
            guard parent.showChangeGutter, let baseline = parent.baseline else {
                if !ruler.changeHunks.isEmpty {
                    ruler.changeHunks = []
                    ruler.needsDisplay = true
                }
                return
            }
            let new = parent.text
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let hunks = LineDiff.hunks(old: baseline, new: new)
                DispatchQueue.main.async {
                    guard let self, let ruler = self.ruler else { return }
                    guard self.parent.text == new else { return }  // 期间又编辑了 → 丢弃旧结果
                    ruler.changeHunks = hunks
                    ruler.needsDisplay = true
                }
            }
        }

        // MARK: - 同词高亮（选中一个单词，标其它整词匹配）

        func clearOccurrenceHighlights() {
            let hadHighlights = !occurrenceRanges.isEmpty
            occurrenceRanges = []
            // 按整文档范围撤销临时背景：编辑后旧范围可能越界，整段清最安全（同词高亮是唯一的临时背景用途）
            guard hadHighlights, let textView, let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            if full.length > 0 {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            }
        }

        func updateOccurrenceHighlights() {
            clearOccurrenceHighlights()
            guard parent.highlightOccurrences,
                  let textView, let layoutManager = textView.layoutManager else { return }
            let sel = textView.selectedRange()
            let nsString = textView.string as NSString
            // 选区要正好是一个完整单词：长度合理、全是词字符、两端是词边界
            guard sel.length >= 2, sel.length <= 200,
                  NSMaxRange(sel) <= nsString.length, nsString.length < 400_000 else { return }
            let token = nsString.substring(with: sel)
            guard Self.isWord(token), Self.isWholeWord(sel, in: nsString) else { return }

            let color = NSColor.controlAccentColor.withAlphaComponent(0.22)
            var start = 0
            while start < nsString.length {
                let found = nsString.range(
                    of: token, options: [.literal],
                    range: NSRange(location: start, length: nsString.length - start))
                if found.location == NSNotFound { break }
                start = NSMaxRange(found)
                guard found.location != sel.location else { continue }  // 跳过选区本身
                if Self.isWholeWord(found, in: nsString) {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: found)
                    occurrenceRanges.append(found)
                }
            }
        }

        private static func isWordChar(_ ch: unichar) -> Bool {
            if ch == 0x5F { return true }                       // _
            if let scalar = Unicode.Scalar(ch) {
                return CharacterSet.alphanumerics.contains(scalar)
            }
            return true
        }

        private static func isWord(_ s: String) -> Bool {
            guard !s.isEmpty else { return false }
            for scalar in s.unicodeScalars {
                if scalar == "_" { continue }
                if !CharacterSet.alphanumerics.contains(scalar) { return false }
            }
            return true
        }

        /// range 两端是否都是词边界（前一字符 / 后一字符非词字符）。
        private static func isWholeWord(_ range: NSRange, in s: NSString) -> Bool {
            if range.location > 0, isWordChar(s.character(at: range.location - 1)) { return false }
            let end = NSMaxRange(range)
            if end < s.length, isWordChar(s.character(at: end)) { return false }
            return true
        }

        func highlightNow() {
            guard !isHighlighting else { return }  // 防重入：断开 updateNSView↔选择↔重算 的循环
            isHighlighting = true
            defer { isHighlighting = false }
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

            lastLineHeight = parent.lineHeight
            storage.beginEditing()
            storage.setAttributes([
                .font: settings.editorNSFont,
                .foregroundColor: theme.editorForeground ?? NSColor.labelColor,
                .paragraphStyle: PlainTextEditor.lineParagraphStyle(parent.lineHeight, font: settings.editorNSFont),
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
            let lineRanges = lineRangesCached()

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
            let lineRanges = lineRangesCached()
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

        /// 缓存版行范围：文本变化（textDidChange / 切换文件）时失效，避免高亮/滚动/选择反复全文扫描。
        private func lineRangesCached() -> [NSRange] {
            if let c = cachedLineRanges { return c }
            guard let textView else { return [] }
            let r = Self.lineRanges(of: textView.string as NSString)
            cachedLineRanges = r
            return r
        }

        func invalidateLineCache() { cachedLineRanges = nil }

        /// 大文件关软换行（超长行软换行布局是卡死主因，改水平滚动）；常规文件软换行。
        func applyWrapping(largeFile: Bool, scrollView: NSScrollView) {
            guard let textView, let container = textView.textContainer else { return }
            let wrap = !largeFile
            if container.widthTracksTextView == wrap { return }  // 模式没变，跳过
            textView.isHorizontallyResizable = largeFile
            container.widthTracksTextView = wrap
            container.size = largeFile
                ? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                : NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = largeFile
        }

        /// 是否含超长行（某行超过 threshold 个 UTF-16 单元）。逐行只搜到下一个换行，整体 O(n)。
        static func hasLongLine(_ s: NSString, threshold: Int) -> Bool {
            var loc = 0
            let len = s.length
            while loc < len {
                let r = s.range(of: "\n", options: [], range: NSRange(location: loc, length: len - loc))
                let end = r.location == NSNotFound ? len : r.location
                if end - loc > threshold { return true }
                if r.location == NSNotFound { break }
                loc = r.location + 1
            }
            return false
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

    // MARK: - 多选区（⌘D 加选下一个相同词 / ⌘⇧L 选中全部）

    // 选中全文/逐个相同词，便于「选中后一次性改名或删除」。注意：TextKit 1 的 NSTextView
    // 支持多个「非空选区」（可一次性同时编辑），但不支持多个零长光标——按方向键会塌回单个，
    // 故只做多选区，不做持续多光标（那需要 TextKit 2 内核，见 [[hunk-editor-pending]]）。
    // ⌘D / ⌘⇧L 都不是本 app 的菜单快捷键，未拦截会漏给系统（触发系统搜索/Safari），故在此接管。

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command, chars == "d" { return addNextOccurrence() }
        if mods == [.command, .shift], chars == "l" { return selectAllOccurrences() }
        return super.performKeyEquivalent(with: event)
    }

    private func isAllWordChars(_ s: NSString) -> Bool {
        guard s.length > 0 else { return false }
        for i in 0..<s.length where !Self.isWordChar(s.character(at: i)) { return false }
        return true
    }

    private func isWholeWord(_ r: NSRange, in s: NSString) -> Bool {
        let before = r.location - 1
        let after = NSMaxRange(r)
        let okBefore = before < 0 || !Self.isWordChar(s.character(at: before))
        let okAfter = after >= s.length || !Self.isWordChar(s.character(at: after))
        return okBefore && okAfter
    }

    /// 文档里 needle 的全部出现位置（升序）。wholeWord=true 时只取前后均为分隔符的整词匹配。
    private func ranges(of needle: NSString, wholeWord: Bool) -> [NSRange] {
        let s = string as NSString
        guard needle.length > 0, s.length > 0 else { return [] }
        var result: [NSRange] = []
        var from = 0
        while from < s.length {
            let r = s.range(of: needle as String, options: [],
                            range: NSRange(location: from, length: s.length - from))
            if r.location == NSNotFound { break }
            if !wholeWord || isWholeWord(r, in: s) { result.append(r) }
            from = max(NSMaxRange(r), r.location + 1)
        }
        return result
    }

    /// 当前用于匹配的「针」：有选区取选区文本；无选区取光标处整词。
    /// 返回 nil 表示光标停在非词字符上、无可匹配的词。
    private func currentNeedle() -> (text: NSString, wholeWord: Bool, primary: NSRange)? {
        let s = string as NSString
        guard s.length > 0 else { return nil }
        let sel = selectedRange()
        if sel.length > 0 {
            let text = s.substring(with: sel) as NSString
            return (text, isAllWordChars(text), sel)
        }
        let wr = wordRange(at: sel.location, in: s)
        guard wr.length > 0, Self.isWordChar(s.character(at: wr.location)) else { return nil }
        return (s.substring(with: wr) as NSString, true, wr)
    }

    private func setMultiSelection(_ ranges: [NSRange], scrollTo: NSRange) {
        let sorted = ranges.sorted { $0.location < $1.location }
        setSelectedRanges(sorted.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        scrollRangeToVisible(scrollTo)
    }

    /// ⌘⇧L：选中全文所有相同词（无选区时先以光标处整词为准）。
    @discardableResult
    private func selectAllOccurrences() -> Bool {
        guard let needle = currentNeedle() else { return true }
        let all = ranges(of: needle.text, wholeWord: needle.wholeWord)
        guard !all.isEmpty else { return true }
        setMultiSelection(all, scrollTo: needle.primary)
        return true
    }

    /// ⌘D：无选区先选光标处整词；已有选区则加选其后（环绕）第一个尚未选中的相同词。
    @discardableResult
    private func addNextOccurrence() -> Bool {
        let s = string as NSString
        let sel = selectedRange()
        if sel.length == 0 {
            guard let needle = currentNeedle() else { return true }
            setSelectedRange(needle.primary)
            scrollRangeToVisible(needle.primary)
            return true
        }
        let needle = s.substring(with: sel) as NSString
        let all = ranges(of: needle, wholeWord: isAllWordChars(needle))
        guard !all.isEmpty else { return true }
        let existing = selectedRanges.map { $0.rangeValue }
        let taken = Set(existing.map(\.location))
        let anchor = existing.map { NSMaxRange($0) }.max() ?? NSMaxRange(sel)
        let candidates = all.filter { !taken.contains($0.location) }
        guard let next = candidates.first(where: { $0.location >= anchor }) ?? candidates.first else {
            return true   // 全部已选中
        }
        setMultiSelection(existing + [next], scrollTo: next)
        return true
    }
}

// MARK: - 行号 gutter

/// NSTextView 的行号标尺：缓存行起始偏移，滚动/编辑时按可见区域绘制。
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// 每行起始字符偏移（utf16），首元素恒为 0。
    private var lineStarts: [Int] = [0]
    private var lineIndexValid = false

    // MARK: 改动标记
    /// 当前文件相对 HEAD 的改动 hunk；赋值即重建按行索引并刷新。
    var changeHunks: [LineDiff.Hunk] = [] {
        didSet { rebuildChangeIndex(); needsDisplay = true }
    }
    /// 新增/修改：被覆盖的新行下标(0 基) → 所属 hunk，用于画竖线与悬浮。
    private var hunkAtLine: [Int: LineDiff.Hunk] = [:]
    /// 删除：发生删除的新行下标(0 基) → hunk，用于画红三角与悬浮。
    private var deletionAtLine: [Int: LineDiff.Hunk] = [:]
    /// 本次绘制记录的可见行矩形（标尺坐标系），供悬浮命中测试。
    private var visibleRows: [(line: Int, rect: NSRect)] = []
    private var trackingArea: NSTrackingArea?
    private let hoverPopover = NSPopover()
    /// 当前悬浮卡对应的 hunk 起始行，避免同一处反复重弹。
    private var hoveredHunkStart: Int?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        hoverPopover.behavior = .applicationDefined
        hoverPopover.animates = false

        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    private func rebuildChangeIndex() {
        hunkAtLine.removeAll(keepingCapacity: true)
        deletionAtLine.removeAll(keepingCapacity: true)
        for hunk in changeHunks {
            switch hunk.kind {
            case .added, .modified:
                for line in hunk.newStart..<(hunk.newStart + hunk.newCount) {
                    hunkAtLine[line] = hunk
                }
            case .deleted:
                deletionAtLine[hunk.newStart] = hunk   // 删除发生在该新行之前
            }
        }
    }

    /// 改动标记颜色：绿增、蓝改、红删。
    private func changeColor(_ kind: LineDiff.Hunk.Kind) -> NSColor {
        switch kind {
        case .added: return .systemGreen
        case .modified: return .systemBlue
        case .deleted: return .systemRed
        }
    }

    /// 在某行片段矩形右缘画一条改动竖线。
    private func drawChangeBar(_ kind: LineDiff.Hunk.Kind, rowRect: NSRect) {
        changeColor(kind).setFill()
        NSRect(x: bounds.width - 5, y: rowRect.minY, width: 3, height: rowRect.height).fill()
    }

    /// 在行边界 y 处画一个指向右的红三角（表示此处有行被删除）。
    private func drawDeletionTriangle(atBoundaryY y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.width - 8, y: y - 4))
        path.line(to: NSPoint(x: bounds.width - 8, y: y + 4))
        path.line(to: NSPoint(x: bounds.width - 2, y: y))
        path.close()
        changeColor(.deleted).setFill()
        path.fill()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func needsRedraw() {
        needsDisplay = true
        dismissHoverPopover()   // 滚动后锚点失位，先收起悬浮卡
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
        visibleRows.removeAll(keepingCapacity: true)

        var lastDrawnLine = -1
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var fragmentGlyphRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphRange)
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            let line = lineNumber(forCharacter: charIndex)
            let isFirstFragment = lineStarts[line - 1] == charIndex
            let y = fragmentRect.minY + inset.height - visibleRect.minY
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: fragmentRect.height)
            visibleRows.append((line: line - 1, rect: rowRect))

            // 改动竖线：每片段都画，软换行行也连续
            if let hunk = hunkAtLine[line - 1] {
                drawChangeBar(hunk.kind, rowRect: rowRect)
            }
            // 删除红三角只在行首画一次
            if isFirstFragment, deletionAtLine[line - 1] != nil {
                drawDeletionTriangle(atBoundaryY: y)
            }
            // 行号：软换行的后续片段不重复编号
            if line != lastDrawnLine, isFirstFragment {
                lastDrawnLine = line
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
            let y = fragmentRect.minY + inset.height - visibleRect.minY
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: fragmentRect.height)
            visibleRows.append((line: line - 1, rect: rowRect))
            if let hunk = hunkAtLine[line - 1] {
                drawChangeBar(hunk.kind, rowRect: rowRect)
            }
            if deletionAtLine[line - 1] != nil {
                drawDeletionTriangle(atBoundaryY: y)
            }
            if line != lastDrawnLine {
                let text = "\(line)" as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(
                    at: NSPoint(x: bounds.width - size.width - 6, y: y + (fragmentRect.height - size.height) / 2),
                    withAttributes: attributes
                )
            }
        }
    }

    // MARK: - 悬浮看具体变动

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 命中某可见行；该行有改动 hunk 就弹卡，否则收起
        guard let row = visibleRows.first(where: { $0.rect.contains(point) }),
              let hunk = hunkAtLine[row.line] ?? deletionAtLine[row.line] else {
            dismissHoverPopover()
            return
        }
        if hoveredHunkStart == hunk.newStart, hoverPopover.isShown { return }
        hoveredHunkStart = hunk.newStart
        let anchor = NSRect(x: bounds.width - 6, y: row.rect.minY, width: 4, height: row.rect.height)
        let host = NSHostingController(rootView: ChangeHunkCard(hunk: hunk))
        host.sizingOptions = [.preferredContentSize]
        hoverPopover.contentViewController = host
        if hoverPopover.isShown { hoverPopover.close() }
        hoverPopover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
    }

    override func mouseExited(with event: NSEvent) { dismissHoverPopover() }

    private func dismissHoverPopover() {
        hoveredHunkStart = nil
        if hoverPopover.isShown { hoverPopover.close() }
    }
}

// MARK: - 改动悬浮卡（展示某 hunk 的旧/新行）

/// 行号槽竖线/三角的悬浮卡：标题给出改动类型，下面按红(旧)/绿(新)列出具体行。
private struct ChangeHunkCard: View {
    let hunk: LineDiff.Hunk

    private var title: String {
        switch hunk.kind {
        case .added: return tr("新增 \(hunk.newLines.count) 行", "Added \(hunk.newLines.count) line(s)")
        case .deleted: return tr("删除 \(hunk.oldLines.count) 行", "Removed \(hunk.oldLines.count) line(s)")
        case .modified:
            return tr("修改：\(hunk.oldLines.count) 行 → \(hunk.newLines.count) 行",
                      "Modified: \(hunk.oldLines.count) → \(hunk.newLines.count) line(s)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if !hunk.oldLines.isEmpty || !hunk.newLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if hunk.kind != .added {
                            ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { _, line in
                                diffLine("−", line, .red)
                            }
                        }
                        if hunk.kind != .deleted {
                            ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { _, line in
                                diffLine("+", line, .green)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .frame(width: 420)
    }

    private func diffLine(_ sign: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign)
                .foregroundStyle(color)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(SettingsStore.shared.editorFont)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
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
