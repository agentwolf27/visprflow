import AppKit
import SwiftUI

/// First-run setup: the three permissions, the fn-key conflict, the speech model, the API key,
/// and a paste test that exercises the real insertion path rather than a stand-in.
struct OnboardingView: View {
    @Environment(AppState.self) private var state

    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var keyMessage: String?

    @State private var pasteTarget = ""
    @State private var pasteMessage: String?
    @State private var pasteInFlight = false

    private static let pasteMarker = "Visprflow test paste ✓"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                permissions
                triggerKey
                speechModel
                apiKey
                pasteTest
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 580, minHeight: 680)
        .task {
            loadKeyState()
            while !Task.isCancelled {
                state.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up Visprflow")
                .font(.system(size: 26, weight: .bold))
            Text("Hold \(state.triggerKey.displayName), talk, release. Three permissions make that work in every app.")
                .foregroundStyle(.secondary)
            if let error = state.startupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Permissions", badge: state.permissions.allGranted ? "All granted" : nil)
            ForEach(Permission.allCases) { permission in
                PermissionRow(permission: permission, granted: state.permissions.isGranted(permission)) {
                    Task {
                        await PermissionsService.request(permission)
                        state.refreshPermissions()
                    }
                } openSettings: {
                    PermissionsService.openSettings(for: permission)
                }
            }
            Text("Debug builds are ad-hoc signed, so macOS ties these grants to the exact binary. Rebuilding means granting again. The README explains how to avoid that with a self-signed certificate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var triggerKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Trigger key", badge: state.isListening ? "Listening" : nil)
            Text("fn only reaches apps from the built-in keyboard. On an external keyboard, use Right Option.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { state.triggerKey },
                set: { state.setTriggerKey($0) }
            )) {
                ForEach(TriggerKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if state.triggerKey == .fn, state.fnUsage.conflictsWithTrigger {
                calloutRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Your fn key currently \(state.fnUsage.description). macOS handles that before any app sees the key, so set it to “Do Nothing” for a clean trigger.",
                    button: "Open Keyboard Settings"
                ) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
        }
    }

    private var speechModel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Speech model", badge: nil)
            Text("Parakeet v3 runs on this Mac's Neural Engine. Roughly 600 MB on first run. Audio never leaves the machine.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let progress = state.dictation?.modelProgress {
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%").font(.caption)
                }
            }
        }
    }

    private var apiKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Anthropic API key", badge: hasStoredKey ? "Stored in Keychain" : nil)
            Text("Used to compile transcripts into prompts. Without it, Visprflow still dictates: it inserts the cleaned transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("sk-ant-…", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button(hasStoredKey ? "Replace" : "Save") { saveKey() }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasStoredKey {
                    Button("Remove", role: .destructive) { removeKey() }
                }
            }
            if let keyMessage {
                Text(keyMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pasteTest: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Test insertion", badge: nil)
            Text("Click into the field, then press the button. This runs the real insertion path: it writes the clipboard, synthesises the paste, and puts your clipboard back.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Paste lands here", text: $pasteTarget)
                    .textFieldStyle(.roundedBorder)
                Button("Test paste") { runPasteTest() }
                    .disabled(!state.permissions.accessibility || pasteInFlight)
            }
            if let pasteMessage {
                Text(pasteMessage).font(.caption).foregroundStyle(.secondary)
            }
            Text("The real test is holding your trigger key in another app. This one only proves the Accessibility grant works.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String, badge: String?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
    }

    private func calloutRow(
        icon: String,
        tint: Color,
        text: String,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action).font(.caption)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Actions

    private func loadKeyState() {
        do {
            hasStoredKey = try Keychain.get(.anthropicAPIKey) != nil
        } catch {
            keyMessage = "Could not read the keychain: \(error)"
        }
    }

    private func saveKey() {
        do {
            try Keychain.set(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: .anthropicAPIKey)
            apiKeyDraft = ""
            hasStoredKey = true
            keyMessage = "Saved."
        } catch {
            keyMessage = "Could not save: \(error)"
        }
    }

    private func removeKey() {
        do {
            try Keychain.delete(.anthropicAPIKey)
            hasStoredKey = false
            keyMessage = "Removed."
        } catch {
            keyMessage = "Could not remove: \(error)"
        }
    }

    private func runPasteTest() {
        pasteTarget = ""
        pasteInFlight = true
        pasteMessage = "Pasting…"
        Task {
            defer { pasteInFlight = false }
            do {
                try await Inserter().insert(Self.pasteMarker, strategy: .paste)
                pasteMessage = pasteTarget.contains(Self.pasteMarker)
                    ? "Insertion works, and your clipboard was restored."
                    : "Nothing arrived. Give the field above focus, then try again."
            } catch {
                pasteMessage = error.localizedDescription
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.body.weight(.semibold))
                Text(permission.why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !granted {
                VStack(spacing: 6) {
                    Button("Request", action: request)
                    Button("System Settings…", action: openSettings)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
