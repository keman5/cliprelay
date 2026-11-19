#if os(iOS)
import SwiftUI
import UIKit

struct KeyboardStartupOptions: View {
    @AppStorage("keyboard.startsWithClipboard", store: ClipRelayPreferences.defaults) private var startsInClipboard = true
    @AppStorage("keyboard.inputLanguage", store: ClipRelayPreferences.defaults) private var inputLanguage = "english"

    var body: some View {
        Picker("Keyboard opens to", selection: $startsInClipboard) {
            Text("Clipboard").tag(true)
            Text("Typing").tag(false)
        }
        Picker("Default input mode", selection: $inputLanguage) {
            Text("English").tag("english")
            Text("Chinese Pinyin").tag("pinyin")
        }
    }
}

struct SetupGuide: View {
    @ObservedObject var model: Model
    @Binding var theme: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var stage: Stage = .keyboard
    @State private var challenge: String?
    @State private var keyboardFound = false
    @AppStorage("setupGuide.returningFromSettings") private var returningFromSettings = false
    @State private var focusTest = false
    @State private var newlyPaired: Peer?

    private enum Stage { case keyboard, preferences, pairing }

    var body: some View {
        NavigationStack {
            Form {
                switch stage {
                case .keyboard: keyboardSteps
                case .preferences: preferences
                case .pairing: pairing
                }
            }
            .scrollDismissesKeyboard(stage == .pairing ? .immediately : .automatic)
            .navigationTitle("Setup guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismissGuide() }
                }
            }
        }
        .onAppear { if stage == .keyboard && challenge == nil { resumeTest() } }
        .onDisappear(perform: clearTest)
        .onChange(of: phase) { _, phase in
            guard stage == .keyboard else { return }
            if phase == .background { clearTest() }
            if phase == .active, challenge == nil { resumeTest() }
        }
    }

    @ViewBuilder private var keyboardSteps: some View {
        Section("Add the ClipRelay keyboard") {
            if keyboardFound { Label("Keyboard detected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → ClipRelay")
        }
        Section("Allow Full Access") {
            Text("In the Keyboards list, tap ClipRelay, turn on Allow Full Access, then tap Allow.")
            Text("Full Access lets the keyboard open your shared clipboard history and saved phrases. Basic typing works without it.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { openSettings() } label: { Label("Open system settings", systemImage: "gear") }
        }
        Section("Check your keyboard") {
            if let challenge {
                KeyboardSetupField(challenge: challenge, focus: focusTest) { access in
                    if self.challenge == challenge { accept(access) }
                }
                    .frame(minHeight: 24)
                    .id(challenge)
                    .overlay(alignment: .leading) {
                        Label("Tap to test the keyboard", systemImage: "keyboard")
                            .foregroundStyle(.secondary).allowsHitTesting(false).accessibilityHidden(true)
                    }
                Text("Return here, tap the test field, then hold the globe key and choose ClipRelay. The check runs automatically.")
            } else {
                Button("Retry keyboard check") { prepareTest() }
            }
            if keyboardFound {
                Text("Full Access is still off. Turn it on in Settings, then test again.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var preferences: some View {
        Section("Keyboard preferences") {
            Label("Keyboard and Full Access verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            KeyboardStartupOptions()
            Picker("Appearance", selection: $theme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Button("Continue to Mac pairing") { stage = .pairing }
        }
    }

    private var pairing: some View {
        Group {
            if let newlyPaired {
                Section("Pair with your Mac") {
                    Label(newlyPaired.name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Done") { dismissGuide() }
                }
            } else {
                PairingSettings(model: model, guidingMacPairing: true) { newlyPaired = $0 }
                Section { Button("Pair later") { dismissGuide() } }
            }
        }
        .task { model.startNetworking() }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        returningFromSettings = true
        openURL(url) { accepted in if !accepted { returningFromSettings = false } }
    }

    private func dismissGuide() {
        returningFromSettings = false
        dismiss()
    }

    private func resumeTest() {
        prepareTest(focus: returningFromSettings)
        returningFromSettings = false
    }

    private func prepareTest(focus: Bool = false) {
        clearTest()
        let next = KeyboardSetupCheck.challenge()
        guard KeyboardSetupCheck.activate(next) else { return }
        challenge = next
        focusTest = focus
    }

    private func clearTest() {
        if let challenge { KeyboardSetupCheck.clear(challenge) }
        challenge = nil
        focusTest = false
    }

    private func accept(_ access: KeyboardSetupCheck.Access) {
        keyboardFound = true
        if access == .full {
            clearTest()
            stage = .preferences
        }
    }
}

private struct KeyboardSetupField: UIViewRepresentable {
    let challenge: String
    let focus: Bool
    let onResult: (KeyboardSetupCheck.Access) -> Void

    func makeUIView(context: Context) -> TestField {
        let field = TestField()
        field.text = challenge
        field.textColor = .clear
        field.tintColor = .clear
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.delegate = context.coordinator
        field.accessibilityIdentifier = "keyboard-setup-test"
        field.accessibilityLabel = ClipRelayPreferences.localized("Tap to test the keyboard")
        field.accessibilityValue = ""
        field.focusWhenAttached = focus
        return field
    }

    func updateUIView(_ field: TestField, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TestField, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: max(24, UIFont.preferredFont(forTextStyle: .body).lineHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class TestField: UITextField {
        var focusWhenAttached = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, focusWhenAttached else { return }
            focusWhenAttached = false
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let check: KeyboardSetupField
        init(_ check: KeyboardSetupField) { self.check = check }

        func textFieldDidChangeSelection(_ field: UITextField) {
            let end = field.endOfDocument
            if let selection = field.selectedTextRange,
               field.offset(from: selection.start, to: end) != 0 || !selection.isEmpty {
                field.selectedTextRange = field.textRange(from: end, to: end)
            }
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard let text = field.text, let range = Range(range, in: text),
                  let result = KeyboardSetupCheck.result(from: text.replacingCharacters(in: range, with: string), for: check.challenge) else { return false }
            DispatchQueue.main.async { [check, weak field] in
                field?.resignFirstResponder()
                check.onResult(result)
            }
            return false
        }
    }
}
#endif
