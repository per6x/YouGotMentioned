import AppKit
import ApplicationServices

// MARK: - AX Helpers

private func axAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    return value
}

private func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    axAttr(el, "AXChildren") as? [AXUIElement] ?? []
}

private func axString(_ el: AXUIElement, _ attr: String) -> String? {
    axAttr(el, attr) as? String
}

private func findCaptionsRoot(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 25 else { return nil }
    if axString(el, "AXDescription") == "Live Captions" { return el }
    for child in axChildren(el) {
        if let found = findCaptionsRoot(child, depth: depth + 1) { return found }
    }
    return nil
}

private func collectEntries(_ el: AXUIElement, depth: Int = 0, into result: inout [(String, String)]) {
    guard depth < 15 else { return }
    let children = axChildren(el)
    let texts = children.filter { axString($0, "AXRole") == "AXStaticText" }
    if texts.count == 2,
       let spk = axString(texts[0], "AXValue")?.trimmingCharacters(in: .whitespaces),
       let txt = axString(texts[1], "AXValue")?.trimmingCharacters(in: .whitespaces),
       !spk.isEmpty, !txt.isEmpty
    {
        result.append((spk, txt))
        return
    }
    for child in children { collectEntries(child, depth: depth + 1, into: &result) }
}

private func extractEntries(_ root: AXUIElement) -> [(String, String)] {
    var result: [(String, String)] = []
    collectEntries(root, into: &result)
    return result
}

// MARK: - Text field with visible focus ring

private final class MenuTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
        }
        return result
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        layer?.borderWidth = 0
    }
}

// MARK: - Menu that forwards key equivalents to text fields

private final class EditableMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers ?? ""
        switch key {
        case "a": editor.selectAll(nil); return true
        case "c": editor.copy(nil); return true
        case "v": editor.paste(nil); return true
        case "x": editor.cut(nil); return true
        case "z":
            if event.modifierFlags.contains(.shift) {
                editor.undoManager?.redo()
            } else {
                editor.undoManager?.undo()
            }
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var monitorItem: NSMenuItem!
    private var nameField: NSTextField!
    private var pollTimer: Timer?
    private var finalized: Set<String> = []
    private var captionsRoot: AXUIElement?
    private var teamsElement: AXUIElement?

    private var nameVariants: [String] {
        get { (UserDefaults.standard.array(forKey: "nameVariants") as? [String]) ?? ["Petrs", "Petr", "Петр"] }
        set { UserDefaults.standard.set(newValue, forKey: "nameVariants") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔕"

        let menu = EditableMenu()
        menu.delegate = self

        monitorItem = NSMenuItem(title: "Start Monitoring", action: #selector(toggleMonitoring), keyEquivalent: "")
        monitorItem.target = self
        menu.addItem(monitorItem)

        menu.addItem(.separator())

        let label = NSMenuItem(title: "Names (comma-separated):", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)

        nameField = MenuTextField(frame: .zero)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = 5
        nameField.focusRingType = .none
        nameField.stringValue = nameVariants.joined(separator: ", ")
        nameField.font = .systemFont(ofSize: 12)
        nameField.placeholderString = "Petrs, Petr, Петр"
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.drawsBackground = true
        nameField.usesSingleLineMode = false
        nameField.cell?.wraps = true
        nameField.cell?.isScrollable = false
        nameField.lineBreakMode = .byWordWrapping
        nameField.target = self
        nameField.action = #selector(nameFieldChanged)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 72))
        container.addSubview(nameField)
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            nameField.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            nameField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        let fieldItem = NSMenuItem()
        fieldItem.view = container
        menu.addItem(fieldItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggleMonitoring() {
        if pollTimer != nil { stopMonitoring() } else { startMonitoring() }
    }

    private func startMonitoring() {
        finalized = []
        captionsRoot = nil
        teamsElement = nil
        statusItem.button?.title = "🔔"
        monitorItem.title = "Stop Monitoring"
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        statusItem.button?.title = "🔕"
        monitorItem.title = "Start Monitoring"
    }

    private func tick() {
        if teamsElement == nil {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier?.hasPrefix("com.microsoft.teams") == true
            }) else { return }
            teamsElement = AXUIElementCreateApplication(app.processIdentifier)
            captionsRoot = nil
        }
        guard let teams = teamsElement else { return }

        if captionsRoot == nil {
            captionsRoot = findCaptionsRoot(teams)
            guard captionsRoot != nil else { return }
        }
        guard let root = captionsRoot else { return }

        let entries = extractEntries(root)
        guard entries.count > 1 else { return }

        for (speaker, text) in entries.dropLast() {
            let key = "\(speaker)|\(text)"
            guard !finalized.contains(key) else { continue }
            finalized.insert(key)
            checkAndNotify(speaker: speaker, text: text)
        }

        if finalized.count > 1000 { finalized = Set(finalized.suffix(300)) }
    }

    private func checkAndNotify(speaker: String, text: String) {
        let speakerLow = speaker.lowercased()
        let textLow = text.lowercased()
        for name in nameVariants {
            let nameLow = name.lowercased()
            if speakerLow.contains(nameLow) { return }
            if textLow.contains(nameLow) {
                notify(title: speaker, body: text)
                return
            }
        }
    }

    private func notify(title: String, body: String) {
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let b = body.replacingOccurrences(of: "\"", with: "'")
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "display notification \"\(b)\" with title \"\(t)\""]
        try? task.run()
    }

    private func saveNames() {
        // End editing so field editor commits text back to nameField.stringValue
        nameField.window?.makeFirstResponder(nil)
        let parts = nameField.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { nameVariants = parts }
    }

    @objc private func nameFieldChanged() { saveNames() }

    func menuDidClose(_ menu: NSMenu) { saveNames() }
}

// MARK: - Entry Point

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
