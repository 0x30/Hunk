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
    var onEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

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

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
            coordinator.highlightNow()
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
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        var lastConflicts: [ConflictBlock] = []
        var lastThemeName: String?
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

        let background = ThemeStore.shared.editorBackground ?? NSColor.textBackgroundColor
        background.setFill()
        bounds.fill()

        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

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
