import AppKit

@MainActor
public enum PasswordPromptPanel {
    public static func promptForSessionPassword(isRestart: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isRestart ? "Restart MAC Bot Session" : "Start MAC Bot Session"
        alert.informativeText = isRestart
            ? "Enter a new session password for the restarted bot run. Previous Telegram sessions will re-authenticate with this password."
            : "Enter a session password for this bot run (used to unlock Telegram). Your Mac will be prevented from sleeping while MAC is running."

        let containerWidth: CGFloat = 320
        let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 56))

        let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: containerWidth, height: 26))
        secureField.placeholderString = "Session password..."
        secureField.usesSingleLineMode = true

        let plainField = NSTextField(frame: NSRect(x: 0, y: 28, width: containerWidth, height: 26))
        plainField.placeholderString = "Session password..."
        plainField.usesSingleLineMode = true
        plainField.isHidden = true

        let showToggle = ButtonToggleHelper(secureField: secureField, plainField: plainField)
        let checkbox = NSButton(checkboxWithTitle: "Show password", target: showToggle, action: #selector(ButtonToggleHelper.toggleChanged(_:)))
        checkbox.frame = NSRect(x: 0, y: 2, width: 160, height: 20)

        container.addSubview(secureField)
        container.addSubview(plainField)
        container.addSubview(checkbox)

        alert.accessoryView = container
        let okButton = alert.addButton(withTitle: isRestart ? "Restart Bot" : "Start Bot")
        okButton.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel")

        alert.window.level = .floating
        alert.window.initialFirstResponder = secureField

        DispatchQueue.main.async {
            alert.window.makeFirstResponder(secureField)
        }

        while true {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                return nil
            }
            let rawValue = showToggle.currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawValue.isEmpty {
                return rawValue
            }
            NSSound.beep()
            alert.informativeText = "⚠️ Session password cannot be empty. Please enter a password:"
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(plainField.isHidden ? secureField : plainField)
            }
        }
    }
}

private final class ButtonToggleHelper: NSObject {
    let secureField: NSSecureTextField
    let plainField: NSTextField

    init(secureField: NSSecureTextField, plainField: NSTextField) {
        self.secureField = secureField
        self.plainField = plainField
    }

    var currentValue: String {
        plainField.isHidden ? secureField.stringValue : plainField.stringValue
    }

    @objc func toggleChanged(_ sender: NSButton) {
        let show = (sender.state == .on)
        if show {
            plainField.stringValue = secureField.stringValue
            secureField.isHidden = true
            plainField.isHidden = false
            plainField.window?.makeFirstResponder(plainField)
        } else {
            secureField.stringValue = plainField.stringValue
            plainField.isHidden = true
            secureField.isHidden = false
            secureField.window?.makeFirstResponder(secureField)
        }
    }
}
