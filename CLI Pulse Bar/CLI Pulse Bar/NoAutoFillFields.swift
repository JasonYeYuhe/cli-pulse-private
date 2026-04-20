#if os(macOS)
import SwiftUI
import AppKit

/// Secure text field that suppresses Keychain/iCloud Password AutoFill.
///
/// Why: on macOS, an `NSTextField` immediately followed by an `NSSecureTextField` is
/// heuristically treated as a login form, and Keychain offers saved credentials even
/// when the SecureField holds something unrelated (e.g. an API key). Bridging to
/// AppKit lets us explicitly set `contentType = nil` and disable completion.
struct NoAutoFillSecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.contentType = nil
        field.isAutomaticTextCompletionEnabled = false
        field.font = .systemFont(ofSize: 10)
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoAutoFillSecureField
        init(parent: NoAutoFillSecureField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// Plain text field with AutoFill suppressed. Used alongside `NoAutoFillSecureField`
/// so the pair is not misread as a username/password form.
struct NoAutoFillTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.contentType = nil
        field.isAutomaticTextCompletionEnabled = false
        field.font = .systemFont(ofSize: 10)
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoAutoFillTextField
        init(parent: NoAutoFillTextField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
#endif
