import AppKit
import CommonCrypto
import CryptoKit
import Foundation

public enum MACConfigCrypto {
    public static func encrypt(data: Data, password: String) throws -> Data {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw NSError(domain: "MACConfigCrypto", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate random salt"])
        }
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            100_000,
            &keyBytes, keyBytes.count
        )
        guard status == 0 else {
            throw NSError(domain: "MACConfigCrypto", code: 2, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed"])
        }
        let symKey = SymmetricKey(data: keyBytes)
        let sealed = try AES.GCM.seal(data, using: symKey)

        let container: [String: Any] = [
            "format": "ai-mac-config-encrypted",
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "kdf": [
                "algorithm": "PBKDF2-HMAC-SHA256",
                "iterations": 100_000,
                "salt": Data(salt).base64EncodedString()
            ],
            "cipher": [
                "algorithm": "AES-256-GCM",
                "nonce": sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
                "tag": sealed.tag.base64EncodedString(),
                "ciphertext": sealed.ciphertext.base64EncodedString()
            ]
        ]
        return try JSONSerialization.data(withJSONObject: container, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func decrypt(data: Data, password: String) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kdf = json["kdf"] as? [String: Any],
              let saltB64 = kdf["salt"] as? String,
              let salt = Data(base64Encoded: saltB64),
              let iterationsNum = kdf["iterations"] as? NSNumber,
              let cipher = json["cipher"] as? [String: Any],
              let nonceB64 = cipher["nonce"] as? String,
              let nonceData = Data(base64Encoded: nonceB64),
              let tagB64 = cipher["tag"] as? String,
              let tagData = Data(base64Encoded: tagB64),
              let ciphertextB64 = cipher["ciphertext"] as? String,
              let ciphertext = Data(base64Encoded: ciphertextB64) else {
            throw NSError(domain: "MACConfigCrypto", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted file format"])
        }

        let iterations = UInt32(iterationsNum.uint32Value)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let saltArray = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            saltArray, saltArray.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations,
            &keyBytes, keyBytes.count
        )
        guard status == 0 else {
            throw NSError(domain: "MACConfigCrypto", code: 4, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed"])
        }
        let symKey = SymmetricKey(data: keyBytes)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
        return try AES.GCM.open(sealed, using: symKey)
    }

    public static func isEncrypted(data: Data) -> Bool {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let format = json["format"] as? String,
           format == "ai-mac-config-encrypted" {
            return true
        }
        return false
    }
}

private final class MACExportAccessoryView: NSView {
    let historyCheckbox: NSButton
    let encryptCheckbox: NSButton
    let passwordField: NSSecureTextField
    let confirmField: NSSecureTextField

    init() {
        self.historyCheckbox = NSButton(checkboxWithTitle: "Export message history (workspaces → work history)", target: nil, action: nil)
        self.historyCheckbox.state = .off

        self.encryptCheckbox = NSButton(checkboxWithTitle: "Encrypt export with password", target: nil, action: nil)
        self.encryptCheckbox.state = .off

        self.passwordField = NSSecureTextField(frame: .zero)
        self.passwordField.placeholderString = "Password"
        self.passwordField.isHidden = true

        self.confirmField = NSSecureTextField(frame: .zero)
        self.confirmField.placeholderString = "Confirm Password"
        self.confirmField.isHidden = true

        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 56))

        encryptCheckbox.target = self
        encryptCheckbox.action = #selector(handleCheckboxChanged)

        addSubview(historyCheckbox)
        addSubview(encryptCheckbox)
        addSubview(passwordField)
        addSubview(confirmField)

        updateLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateLayout() {
        let isEncrypt = encryptCheckbox.state == .on
        let h: CGFloat = isEncrypt ? 118 : 56
        self.frame = NSRect(x: 0, y: 0, width: 340, height: h)

        if isEncrypt {
            historyCheckbox.frame = NSRect(x: 10, y: 90, width: 320, height: 20)
            encryptCheckbox.frame = NSRect(x: 10, y: 66, width: 320, height: 20)
            passwordField.frame = NSRect(x: 10, y: 36, width: 320, height: 22)
            confirmField.frame = NSRect(x: 10, y: 8, width: 320, height: 22)
        } else {
            historyCheckbox.frame = NSRect(x: 10, y: 28, width: 320, height: 20)
            encryptCheckbox.frame = NSRect(x: 10, y: 4, width: 320, height: 20)
        }
    }

    @objc private func handleCheckboxChanged() {
        let isChecked = encryptCheckbox.state == .on
        passwordField.isHidden = !isChecked
        confirmField.isHidden = !isChecked
        if !isChecked {
            passwordField.stringValue = ""
            confirmField.stringValue = ""
        }
        updateLayout()
    }

    var isHistoryChecked: Bool {
        historyCheckbox.state == .on
    }

    var isEncryptChecked: Bool {
        encryptCheckbox.state == .on
    }

    var password: String {
        passwordField.stringValue
    }

    var confirmPassword: String {
        confirmField.stringValue
    }
}

@MainActor
public enum MACConfigExportImportManager {
    public static func exportConfig(appState: MACAppState) {
        let savePanel = NSSavePanel()
        savePanel.title = "Export AI MAC"
        savePanel.prompt = "Export"
        savePanel.allowedContentTypes = [.json]
        savePanel.showsTagField = false

        let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        savePanel.nameFieldStringValue = "ai-mac-\(dateStr).json"

        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = docs
        }

        let accessory = MACExportAccessoryView()
        savePanel.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        let response = savePanel.runModal()
        guard response == .OK, let targetURL = savePanel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            let configData = try encoder.encode(appState.config)
            var exportDict: [String: Any] = [
                "format": "ai-mac-config",
                "version": 1,
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "config": try JSONSerialization.jsonObject(with: configData)
            ]

            if accessory.isHistoryChecked {
                let stateURL = appState.configStore.dataDir.appendingPathComponent("state.json")
                if let rawState = try? Data(contentsOf: stateURL),
                   let stateObj = (try? JSONSerialization.jsonObject(with: rawState)) as? [String: Any] {
                    exportDict["messageHistory"] = stateObj
                }
            }

            let exportPayloadData = try JSONSerialization.data(withJSONObject: exportDict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let finalData: Data

            if accessory.isEncryptChecked {
                let pass = accessory.password.trimmingCharacters(in: .whitespacesAndNewlines)
                let confirm = accessory.confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !pass.isEmpty else {
                    showAlert(title: "Export Failed", message: "Password cannot be empty.", style: .critical)
                    return
                }
                guard pass == confirm else {
                    showAlert(title: "Export Failed", message: "Passwords do not match.", style: .critical)
                    return
                }

                finalData = try MACConfigCrypto.encrypt(data: exportPayloadData, password: pass)
            } else {
                finalData = exportPayloadData
            }

            try finalData.write(to: targetURL, options: .atomic)
            let encNote = accessory.isEncryptChecked ? " (encrypted with password)" : ""
            let histNote = accessory.isHistoryChecked ? " with message history" : ""
            appState.statusBannerMessage = "Exported to \(targetURL.lastPathComponent)\(encNote)"
            showAlert(title: "Export Successful", message: "Successfully exported\(histNote)\(encNote) to:\n\(targetURL.path)", style: .informational)
        } catch {
            showAlert(title: "Export Failed", message: "Error exporting: \(error.localizedDescription)", style: .critical)
        }
    }

    public static func importConfig(appState: MACAppState) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import AI MAC"
        openPanel.prompt = "Import"
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            openPanel.directoryURL = docs
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = openPanel.runModal()
        guard response == .OK, let fileURL = openPanel.url else { return }

        do {
            let rawData = try Data(contentsOf: fileURL)
            let decryptedData: Data

            if MACConfigCrypto.isEncrypted(data: rawData) {
                guard let password = promptForPassword(message: "Enter the password used to encrypt this file:") else {
                    return
                }
                do {
                    decryptedData = try MACConfigCrypto.decrypt(data: rawData, password: password)
                } catch {
                    showAlert(title: "Decryption Failed", message: "The password entered is incorrect or the file is corrupted.", style: .critical)
                    return
                }
            } else {
                decryptedData = rawData
            }

            let decoder = JSONDecoder()
            let importedConfig: MACConfig

            if let direct = try? decoder.decode(MACConfig.self, from: decryptedData) {
                importedConfig = direct
            } else if let dict = (try? JSONSerialization.jsonObject(with: decryptedData)) as? [String: Any],
                      let cfgDict = dict["config"] as? [String: Any],
                      let cfgData = try? JSONSerialization.data(withJSONObject: cfgDict),
                      let fromContainer = try? decoder.decode(MACConfig.self, from: cfgData) {
                importedConfig = fromContainer
            } else {
                showAlert(title: "Import Failed", message: "The selected file is not a valid AI MAC configuration JSON file.", style: .critical)
                return
            }

            // Restore message history if present in the imported backup
            var restoredHistoryNote = ""
            if let dict = (try? JSONSerialization.jsonObject(with: decryptedData)) as? [String: Any],
               let importedHistory = dict["messageHistory"] as? [String: Any] {
                let stateURL = appState.configStore.dataDir.appendingPathComponent("state.json")
                var currentState: [String: Any] = [:]
                if let currentData = try? Data(contentsOf: stateURL),
                   let parsed = (try? JSONSerialization.jsonObject(with: currentData)) as? [String: Any] {
                    currentState = parsed
                }
                if let importedWorkspaces = importedHistory["workspaces"] as? [String: Any] {
                    var currentWorkspaces = (currentState["workspaces"] as? [String: Any]) ?? [:]
                    for (k, v) in importedWorkspaces {
                        currentWorkspaces[k] = v
                    }
                    currentState["workspaces"] = currentWorkspaces
                }
                if let importedSessions = importedHistory["userSessions"] as? [String: Any] {
                    var currentSessions = (currentState["userSessions"] as? [String: Any]) ?? [:]
                    for (k, v) in importedSessions {
                        currentSessions[k] = v
                    }
                    currentState["userSessions"] = currentSessions
                }
                if let mergedData = try? JSONSerialization.data(withJSONObject: currentState, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                    try? mergedData.write(to: stateURL, options: .atomic)
                    restoredHistoryNote = " and restored message history"
                }
            }

            appState.config = importedConfig
            appState.saveConfigToDisk(importedConfig, banner: "Imported configuration successfully! (\(importedConfig.workspaces.count) workspace(s) loaded)")
            appState.reloadConfigFromDisk()

            showAlert(
                title: "Import Successful",
                message: "Successfully imported \(importedConfig.workspaces.count) workspace(s), General settings\(restoredHistoryNote) from \(fileURL.lastPathComponent).",
                style: .informational
            )
        } catch {
            showAlert(title: "Import Failed", message: "Error importing: \(error.localizedDescription)", style: .critical)
        }
    }

    private static func promptForPassword(message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Encrypted Configuration File"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Unlock & Import")
        alert.addButton(withTitle: "Cancel")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "Password"
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return input.stringValue
        }
        return nil
    }

    private static func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
