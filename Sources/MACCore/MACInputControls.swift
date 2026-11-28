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
