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
    var onEdit: () -> Void
    var onCursorLineChange: (Int) -> Void = { _ in }

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
        textView.delegate = context.coordinator

        // 行号 gutter
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        // 光标行尾的 blame 注解
        let blameLabel = NSTextField(labelWithString: "")
        blameLabel.font = .systemFont(ofSize: 11)
        blameLabel.textColor = .tertiaryLabelColor
        blameLabel.backgroundColor = .clear
        blameLabel.isBezeled = false
        blameLabel.isEditable = false
        blameLabel.isSelectable = false
        blameLabel.isHidden = true
        textView.addSubview(blameLabel)
        context.coordinator.blameLabel = blameLabel

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

        if textView.string != text {
            let isNewDocument = coordinator.lastFileName != fileName
            coordinator.lastFileName = fileName
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: isNewDocument ? 0 : min(selected.location, length), length: 0))
            coordinator.highlightNow()
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
        }

        if let line = scrollToLine {
            coordinator.scroll(toLine: line)
            DispatchQueue.main.async {
                self.scrollToLine = nil
            }
        }

        coordinator.updateBlame(text: blameText)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        weak var blameLabel: NSTextField?
        var lastConflicts: [ConflictBlock] = []
        var lastThemeName: String?
        var lastFileName: String?
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
            guard editorFocused else {
                blameLabel?.isHidden = true
                return
            }
            let caret = textView.selectedRange().location
            let line = ruler.lineNumber(forCharacterPublic: caret)
            if line != lastCursorLine {
                lastCursorLine = line
                blameLabel?.isHidden = true  // 移动后先隐藏，等新结果
                parent.onCursorLineChange(line)
            }
            positionBlameLabel()
        }

        func updateBlame(text: String?) {
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

        private func scheduleHighlight() {
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

            storage.beginEditing()
            storage.setAttributes([
                .font: settings.editorNSFont,
                .foregroundColor: theme.editorForeground ?? NSColor.labelColor,
            ], range: fullRange)

            if let language = Lexer.language(forFileName: parent.fileName) {
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
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        let minHeight = enclosingScrollView?.contentSize.height ?? 0
        super.setFrameSize(NSSize(width: newSize.width, height: max(used + overscroll, minHeight)))
    }
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
        var starts: [Int] = [0]
        var location = 0
        while location < nsString.length {
            let newline = nsString.range(of: "\n", options: [], range: NSRange(location: location, length: nsString.length - location))
            if newline.location == NSNotFound { break }
            starts.append(newline.location + 1)
            location = newline.location + 1
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
