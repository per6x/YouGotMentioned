import Cocoa
import UserNotifications

// MARK: - AX Helpers

private func axAttr<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, attr as CFString, &v)
    return v as? T
}

private func findCaptionsRoot(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 25 else { return nil }
    if let desc: String = axAttr(el, "AXDescription"), desc == "Live Captions" { return el }
    for child in axAttr(el, "AXChildren") as [AXUIElement]? ?? [] {
        if let found = findCaptionsRoot(child, depth: depth + 1) { return found }
    }
    return nil
}

private func extractEntries(_ el: AXUIElement, depth: Int = 0, into result: inout [(String, String)]) {
    guard depth < 15, let children: [AXUIElement] = axAttr(el, "AXChildren") else { return }
    let texts = children.filter { axAttr($0, "AXRole") == "AXStaticText" }

    if texts.count == 2,
       let spk: String = axAttr(texts[0], "AXValue"),
       let txt: String = axAttr(texts[1], "AXValue") {
        let s = spk.trimmingCharacters(in: .whitespaces)
        let t = txt.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty && !t.isEmpty { result.append((s, t)); return }
    }
    for child in children { extractEntries(child, depth: depth + 1, into: &result) }
}

// MARK: - Menu Fix for Text Field Copy/Paste

private final class EditableMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "a": editor.selectAll(nil); return true
        case "c": editor.copy(nil); return true
        case "v": editor.paste(nil); return true
        case "x": editor.cut(nil); return true
        case "z": event.modifierFlags.contains(.shift) ? editor.undoManager?.redo() : editor.undoManager?.undo(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var monitorItem: NSMenuItem!
    private var nameField: NSTextField!
    private var pollTimer: Timer?
    private var pendingText: String?
    private var pendingSpeaker: String?
    private var stableCount = 0
    private var captionsRoot: AXUIElement?
    private var teamsElement: AXUIElement?

    private var nameVariants: [String] {
        get { UserDefaults.standard.stringArray(forKey: "names") ?? ["Petrs", "Petr", "Петр"] }
        set { UserDefaults.standard.set(newValue, forKey: "names") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        nc.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔕"

        let menu = EditableMenu()
        menu.delegate = self

        monitorItem = NSMenuItem(title: "Start Monitoring", action: #selector(toggle), keyEquivalent: "")
        monitorItem.target = self
        menu.addItem(monitorItem)
        menu.addItem(.separator())

        nameField = NSTextField(string: nameVariants.joined(separator: ", "))
        nameField.placeholderString = "Names (comma-separated)"
        nameField.frame = NSRect(x: 16, y: 6, width: 218, height: 60)
        nameField.cell?.wraps = true
        nameField.lineBreakMode = .byWordWrapping

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 72))
        container.addSubview(nameField)

        let fieldItem = NSMenuItem()
        fieldItem.view = container
        menu.addItem(fieldItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggle() {
        if pollTimer != nil {
            pollTimer?.invalidate()
            pollTimer = nil
            statusItem.button?.title = "🔕"
            monitorItem.title = "Start Monitoring"
        } else {
            pendingText = nil
            pendingSpeaker = nil
            stableCount = 0
            captionsRoot = nil
            teamsElement = nil
            statusItem.button?.title = "🔔"
            monitorItem.title = "Stop Monitoring"
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    private func tick() {
        if teamsElement == nil {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.microsoft.teams" || $0.bundleIdentifier == "com.microsoft.teams2"
            }) else { return }
            teamsElement = AXUIElementCreateApplication(app.processIdentifier)
        }
        guard let teams = teamsElement else { return }

        if captionsRoot == nil { captionsRoot = findCaptionsRoot(teams) }
        guard let root = captionsRoot else { return }

        var entries: [(String, String)] = []
        extractEntries(root, into: &entries)
        guard let (speaker, text) = entries.last else { return }

        // Wait for the latest caption to stabilize (~2s)
        if text == pendingText && speaker == pendingSpeaker {
            stableCount += 1
        } else {
            pendingText = text
            pendingSpeaker = speaker
            stableCount = 0
        }

        guard stableCount == 5 else { return }
        stableCount += 1 // prevent re-firing until text changes

        let names = nameVariants
        let isMentioned = names.contains { text.localizedCaseInsensitiveContains($0) }
        let isSpeaker = names.contains { speaker.localizedCaseInsensitiveContains($0) }

        if isMentioned && !isSpeaker {
            let content = UNMutableNotificationContent()
            content.title = speaker
            content.body = text
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func saveNames() {
        nameField.window?.makeFirstResponder(nil)
        let parts = nameField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { nameVariants = parts }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func menuDidClose(_ menu: NSMenu) { saveNames() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
