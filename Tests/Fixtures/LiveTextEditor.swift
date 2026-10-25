// Build with swiftc for the opt-in native text output smoke test. This process
// owns its disposable window; no user document is opened or changed.
import AppKit

class PasteOnlyTextView: NSTextView {
    @available(macOS, introduced: 10.1, deprecated: 10.10)
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        if attribute == .selectedText { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if NSStringFromSelector(selector) == "setAccessibilitySelectedText:" { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}

final class RichTextAXView: PasteOnlyTextView {
    override func accessibilitySelectedTextRange() -> NSRange {
        string.isEmpty ? NSRange(location: 1, length: 0) : super.accessibilitySelectedTextRange()
    }

    override func accessibilityValue() -> String? {
        guard let value = super.accessibilityValue() else { return nil }
        // Reproduce an empty contenteditable placeholder that disappears on paste,
        // and rich-text spaces that differ from the editor's backing string.
        if value.isEmpty { return "\n" }
        return value.replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

final class DelayedAXTextView: NSTextView {
    @available(macOS, introduced: 10.1, deprecated: 10.10)
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .selectedText {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.applySelectedText(value)
            }
            return
        }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }

    @available(macOS, introduced: 10.1, deprecated: 10.10)
    private func applySelectedText(_ value: Any?) {
        super.accessibilitySetValue(value, forAttribute: .selectedText)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editItem.submenu = editMenu
menu.addItem(editItem)
app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 220),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "VoicePloeg disposable live dictation test"
let richText = CommandLine.arguments.contains("--rich-text")
let editor: NSTextView
if richText {
    editor = RichTextAXView(frame: window.contentView!.bounds)
} else if CommandLine.arguments.contains("--delayed-ax") {
    editor = DelayedAXTextView(frame: window.contentView!.bounds)
} else if CommandLine.arguments.contains("--paste-only") {
    editor = PasteOnlyTextView(frame: window.contentView!.bounds)
} else {
    editor = NSTextView(frame: window.contentView!.bounds)
}
editor.autoresizingMask = [.width, .height]
editor.isRichText = false
editor.string = richText ? "" : "Draft tail"
editor.setSelectedRange(NSRange(location: richText ? 0 : 5, length: 0))
window.contentView?.addSubview(editor)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(editor)
app.activate(ignoringOtherApps: true)
app.run()
