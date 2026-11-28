import AppKit
import SwiftUI

// MARK: - Window-Wide Click-Outside Input Unfocus Monitor

@MainActor
public enum MACOutsideClickUnfocusMonitor {
    private static var isInstalled: Bool = false

    public static func installIfNeeded() {
        guard !isInstalled else { return }
        isInstalled = true

        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window else { return event }
            if NSApp.modalWindow === window && window is NSPanel {
                return event
            }
            if shouldUnfocusFirstResponder(in: window, clickLocationInWindow: event.locationInWindow) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// Returns `true` when `window` currently has an editable text input focused and
    /// `point` (in `window` coordinates) falls outside that input and outside any other editable text input.
    public static func shouldUnfocusFirstResponder(
        in window: NSWindow,
        clickLocationInWindow point: NSPoint
    ) -> Bool {
        guard let firstResponder = window.firstResponder else { return false }

        let activeEditorView: NSView
        if let tv = firstResponder as? NSTextView, tv.isEditable {
            activeEditorView = (tv.delegate as? NSView) ?? tv
        } else if let tf = firstResponder as? NSTextField, tf.isEditable {
            activeEditorView = tf
        } else {
            return false
        }

        // Keep focus when clicking inside the currently focused field (cursor placement / text selection)
        let pointInActive = activeEditorView.convert(point, from: nil)
        if activeEditorView.bounds.contains(pointInActive) {
            return false
        }

        // Keep focus transition seamless when clicking directly into another editable text field or filter box
        if let rootView = window.contentView?.superview ?? window.contentView {
            let rootPoint = rootView.convert(point, from: nil)
            if let hitView = rootView.hitTest(rootPoint) {
                var cursor: NSView? = hitView
                while let cur = cursor {
                    if cur is MACSearchFilterContainerView {
                        return false
                    }
                    if let tf = cur as? NSTextField, tf.isEditable {
                        return false
                    }
                    if let tv = cur as? NSTextView, tv.isEditable {
                        return false
                    }
                    cursor = cur.superview
                }
            }
        }

        return true
    }
}

// MARK: - Zero-Jump AppKit Search / Filter Field

public final class MACSearchFilterContainerView: NSView, NSTextFieldDelegate {
    public let iconView: NSImageView
    public let placeholderLabel: NSTextField
    public let inputField: NSTextField
    public let clearButton: NSButton

    public var onTextChanged: ((String) -> Void)?

    public init(placeholder: String, initialText: String = "", fontSize: CGFloat = 11.5) {
        self.iconView = NSImageView()
        self.placeholderLabel = NSTextField(labelWithString: placeholder)
        self.inputField = NSTextField(string: initialText)
        self.clearButton = NSButton()
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Magnifying glass icon
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            iconView.image = img.withSymbolConfiguration(cfg) ?? img
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let font = NSFont.systemFont(ofSize: fontSize)

        // Static placeholder label (never touched by AppKit field editor on focus, so 0.0px jump)
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.drawsBackground = false
        placeholderLabel.isBordered = false
        placeholderLabel.isBezeled = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.refusesFirstResponder = true
        placeholderLabel.usesSingleLineMode = true
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Editable input field with nil placeholderString so AppKit never swaps placeholder geometry
        inputField.placeholderString = nil
        inputField.font = font
        inputField.textColor = .labelColor
        inputField.drawsBackground = false
        inputField.isBordered = false
        inputField.isBezeled = false
        inputField.focusRingType = .none
        inputField.usesSingleLineMode = true
        inputField.cell?.wraps = false
        inputField.cell?.isScrollable = true
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Clear button
        if let clearImg = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear filter") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            clearButton.image = clearImg.withSymbolConfiguration(cfg) ?? clearImg
        }
        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(handleClearClicked)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(placeholderLabel)
        addSubview(inputField)
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),

            // Pin placeholderLabel and inputField to identical leading, trailing, and vertical center constraints
            placeholderLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            inputField.leadingAnchor.constraint(equalTo: placeholderLabel.leadingAnchor),
            inputField.trailingAnchor.constraint(equalTo: placeholderLabel.trailingAnchor),
            inputField.centerYAnchor.constraint(equalTo: placeholderLabel.centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
            clearButton.heightAnchor.constraint(equalToConstant: 14)
        ])

        syncAccessoriesVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(inputField)
    }

    public func updateText(_ newText: String) {
        if inputField.stringValue != newText {
            inputField.stringValue = newText
        }
        syncAccessoriesVisibility()
    }

    public func updatePlaceholder(_ newPlaceholder: String) {
        if placeholderLabel.stringValue != newPlaceholder {
            placeholderLabel.stringValue = newPlaceholder
        }
    }

    private func syncAccessoriesVisibility() {
        let isEmpty = inputField.stringValue.isEmpty
        placeholderLabel.isHidden = !isEmpty
        clearButton.isHidden = isEmpty
    }

    @objc private func handleClearClicked() {
        inputField.stringValue = ""
        syncAccessoriesVisibility()
        onTextChanged?("")
    }

    public func controlTextDidChange(_ obj: Notification) {
        syncAccessoriesVisibility()
        onTextChanged?(inputField.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !inputField.stringValue.isEmpty {
                inputField.stringValue = ""
                syncAccessoriesVisibility()
                onTextChanged?("")
            } else {
                window?.makeFirstResponder(nil)
            }
            return true
        }
        return false
    }
}

public struct MACSearchFilterField: NSViewRepresentable {
    public let placeholder: String
    @Binding public var text: String
    public var fontSize: CGFloat

    public init(_ placeholder: String, text: Binding<String>, fontSize: CGFloat = 11.5) {
        self.placeholder = placeholder
        self._text = text
        self.fontSize = fontSize
    }

    public func makeNSView(context: Context) -> MACSearchFilterContainerView {
        let view = MACSearchFilterContainerView(
            placeholder: placeholder,
            initialText: text,
            fontSize: fontSize
        )
        view.onTextChanged = { updated in
            if self.text != updated {
                self.text = updated
            }
        }
        return view
    }

    public func updateNSView(_ nsView: MACSearchFilterContainerView, context: Context) {
        nsView.onTextChanged = { updated in
            if self.text != updated {
                self.text = updated
            }
        }
        nsView.updatePlaceholder(placeholder)
        nsView.updateText(text)
    }
}


// MARK: - Native Multi-Row Selectable Logbook Console with Smart Auto-Scroll

public struct MACLogbookConsoleEntry: Equatable, Identifiable {
    public let id: UInt64
    public let badgeLabel: String
    public let badgeColor: NSColor
    public let lineNumber: String
    public let workspaceName: String?
    public let messageText: String
    public let messageColor: NSColor

    public init(
        id: UInt64,
        badgeLabel: String,
        badgeColor: NSColor,
        lineNumber: String,
        workspaceName: String?,
        messageText: String,
        messageColor: NSColor
    ) {
        self.id = id
        self.badgeLabel = badgeLabel
        self.badgeColor = badgeColor
        self.lineNumber = lineNumber
        self.workspaceName = workspaceName
        self.messageText = messageText
        self.messageColor = messageColor
    }
}

public final class MACLogbookScrollView: NSScrollView {
    public var onUserScrollWheel: ((CGFloat) -> Void)?

    public override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScrollWheel?(event.scrollingDeltaY)
    }
}

public final class MACLogbookConsoleContainerView: NSView {
    public let scrollView: MACLogbookScrollView
    public let textView: NSTextView

    public private(set) var isAutoScrollEnabled: Bool = true
    public var onAutoScrollChanged: ((Bool) -> Void)?

    private var renderedEntries: [MACLogbookConsoleEntry] = []
    private var renderedEmptyMessage: String? = nil
    private var lastAppliedScrollTrigger: Int = 0
    private var isProgrammaticScroll: Bool = false

    public static let bottomThresholdPoints: CGFloat = 18.0

    public override init(frame frameRect: NSRect) {
        self.scrollView = MACLogbookScrollView(frame: frameRect)
        self.textView = NSTextView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1.0).cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(100, frameRect.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]

        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        scrollView.onUserScrollWheel = { [weak self] deltaY in
            self?.handleUserScroll(scrollingDeltaY: deltaY)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func layout() {
        super.layout()
        if isAutoScrollEnabled {
            scrollToBottom()
        }
    }

    public func isScrolledToBottom() -> Bool {
        guard let docView = scrollView.documentView else { return true }
        let docHeight = docView.frame.height
        let clipBounds = scrollView.contentView.bounds
        if docHeight <= clipBounds.height + 1.0 {
            return true
        }
        return (clipBounds.maxY >= docHeight - Self.bottomThresholdPoints)
    }

    public func handleUserScroll(scrollingDeltaY: CGFloat) {
        if scrollingDeltaY > 0 && !isScrolledToBottom() {
            setAutoScroll(false)
        } else {
            setAutoScroll(isScrolledToBottom())
        }
    }

    @objc private func handleClipViewBoundsChanged(_ notification: Notification) {
        guard !isProgrammaticScroll else { return }
        setAutoScroll(isScrolledToBottom())
    }

    public func setAutoScroll(_ enabled: Bool) {
        guard isAutoScrollEnabled != enabled else { return }
        isAutoScrollEnabled = enabled
        onAutoScrollChanged?(enabled)
    }

    public func scrollToLatestAndEnableAutoScroll() {
        setAutoScroll(true)
        scrollToBottom()
    }

    public func scrollToBottom() {
        guard let storage = textView.textStorage else { return }
        isProgrammaticScroll = true
        defer { isProgrammaticScroll = false }

        if let tc = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: tc)
        }
        let docHeight = textView.frame.height
        let clipHeight = scrollView.contentView.bounds.height
        if docHeight > clipHeight {
            let targetOrigin = NSPoint(x: 0, y: max(0, docHeight - clipHeight))
            scrollView.contentView.scroll(to: targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if storage.length > 0 {
            textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }

    public func updateContent(
        entries: [MACLogbookConsoleEntry],
        emptyMessage: String,
        scrollTrigger: Int
    ) {
        let forceScrollToLatest = (scrollTrigger != lastAppliedScrollTrigger)
        if forceScrollToLatest {
            lastAppliedScrollTrigger = scrollTrigger
            setAutoScroll(true)
        }

        guard let storage = textView.textStorage else { return }

        if entries.isEmpty {
            if renderedEmptyMessage != emptyMessage || !renderedEntries.isEmpty {
                renderedEntries = []
                renderedEmptyMessage = emptyMessage
                isProgrammaticScroll = true
                storage.beginEditing()
                storage.setAttributedString(Self.makeEmptyAttributedString(emptyMessage))
                storage.endEditing()
                isProgrammaticScroll = false
            }
            return
        }

        renderedEmptyMessage = nil

        let preservedScrollOrigin = scrollView.contentView.bounds.origin
        let preservedSelections = textView.selectedRanges

        if entries == renderedEntries {
            if forceScrollToLatest || isAutoScrollEnabled {
                scrollToBottom()
            }
            return
        }

        // Fast incremental append when new log lines arrive without altering existing prefix
        let canAppend = !renderedEntries.isEmpty
            && entries.count > renderedEntries.count
            && Array(entries.prefix(renderedEntries.count)) == renderedEntries

        isProgrammaticScroll = true
        storage.beginEditing()
        if canAppend {
            let added = entries.suffix(from: renderedEntries.count)
            for item in added {
                if storage.length > 0 {
                    storage.append(NSAttributedString(string: "\n", attributes: Self.newlineAttributes))
                }
                storage.append(Self.formatEntry(item))
            }
        } else {
            let full = NSMutableAttributedString()
            for (idx, item) in entries.enumerated() {
                if idx > 0 {
                    full.append(NSAttributedString(string: "\n", attributes: Self.newlineAttributes))
                }
                full.append(Self.formatEntry(item))
            }
            storage.setAttributedString(full)
        }
        storage.endEditing()
        renderedEntries = entries

        if let tc = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: tc)
        }
        isProgrammaticScroll = false

        if forceScrollToLatest || isAutoScrollEnabled {
            scrollToBottom()
        } else {
            // Keep exact viewport position & active multi-row selection when scrolled up
            isProgrammaticScroll = true
            let maxY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
            let clampedY = min(preservedScrollOrigin.y, maxY)
            scrollView.contentView.scroll(to: NSPoint(x: preservedScrollOrigin.x, y: clampedY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let totalLen = storage.length
            let validRanges = preservedSelections.filter { val in
                let r = val.rangeValue
                return r.location + r.length <= totalLen
            }
            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
            isProgrammaticScroll = false
        }
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2.5
        p.paragraphSpacing = 3.0
        p.headIndent = 108.0
        return p
    }()

    private static let newlineAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
        .paragraphStyle: paragraphStyle
    ]

    private static func makeEmptyAttributedString(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1.0)
            ]
        )
    }

    private static func formatEntry(_ item: MACLogbookConsoleEntry) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let basePara = paragraphStyle

        // 1. Source Badge Pill (fixed 7-char inner width so columns align cleanly across multi-row copy)
        let trimmedBadge = String(item.badgeLabel.prefix(7))
        let padCount = max(0, 7 - trimmedBadge.count)
        let leftPad = padCount / 2
        let rightPad = padCount - leftPad
        let badgeStr = " " + String(repeating: " ", count: leftPad) + trimmedBadge + String(repeating: " ", count: rightPad) + " "
        line.append(NSAttributedString(
            string: badgeStr,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor.white,
                .backgroundColor: item.badgeColor.withAlphaComponent(0.85),
                .paragraphStyle: basePara
            ]
        ))

        // 2. Line Number
        let numPadded = item.lineNumber.count < 5
            ? String(repeating: " ", count: 5 - item.lineNumber.count) + item.lineNumber
            : item.lineNumber
        line.append(NSAttributedString(
            string: " " + numPadded + "  ",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 1.0),
                .paragraphStyle: basePara
            ]
        ))

        // 3. Optional Workspace Badge
        if let ws = item.workspaceName, !ws.isEmpty {
            line.append(NSAttributedString(
                string: " \(ws) ",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.88, alpha: 0.90),
                    .paragraphStyle: basePara
                ]
            ))
            line.append(NSAttributedString(
                string: "  ",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    .paragraphStyle: basePara
                ]
            ))
        }

        // 4. Message Text
        line.append(NSAttributedString(
            string: item.messageText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: item.messageColor,
                .paragraphStyle: basePara
            ]
        ))

        return line
    }
}

public struct MACLogbookConsoleView: NSViewRepresentable {
    public let entries: [MACLogbookConsoleEntry]
    public let emptyMessage: String
    @Binding public var autoScroll: Bool
    public let scrollTrigger: Int

    public init(
        entries: [MACLogbookConsoleEntry],
        emptyMessage: String,
        autoScroll: Binding<Bool>,
        scrollTrigger: Int
    ) {
        self.entries = entries
        self.emptyMessage = emptyMessage
        self._autoScroll = autoScroll
        self.scrollTrigger = scrollTrigger
    }

    public func makeNSView(context: Context) -> MACLogbookConsoleContainerView {
        let view = MACLogbookConsoleContainerView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
        view.onAutoScrollChanged = { updated in
            DispatchQueue.main.async {
                if self.autoScroll != updated {
                    self.autoScroll = updated
                }
            }
        }
        view.updateContent(entries: entries, emptyMessage: emptyMessage, scrollTrigger: scrollTrigger)
        return view
    }

    public func updateNSView(_ nsView: MACLogbookConsoleContainerView, context: Context) {
        nsView.onAutoScrollChanged = { updated in
            DispatchQueue.main.async {
                if self.autoScroll != updated {
                    self.autoScroll = updated
                }
            }
        }
        nsView.updateContent(entries: entries, emptyMessage: emptyMessage, scrollTrigger: scrollTrigger)
    }
}
