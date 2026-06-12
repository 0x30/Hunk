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
        var lastConflicts: [ConflictBlock] = []
        private var pendingHighlight: DispatchWorkItem?

        init(parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit()
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
            textView.backgroundColor = theme.editorBackground ?? .textBackgroundColor
            textView.insertionPointColor = theme.editorForeground ?? .labelColor

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
        private static func lineRanges(of nsString: NSString) -> [NSRange] {
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
