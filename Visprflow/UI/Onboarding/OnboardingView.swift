import AppKit
import SwiftUI

/// First-run setup: the three permissions with live status, the Anthropic key, and a paste
/// probe that proves the Accessibility grant works without leaving the window.
struct OnboardingView: View {
    @Environment(AppState.self) private var state

    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var keyMessage: String?

    @State private var pasteTarget = ""
    @State private var pasteMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                permissions
                apiKey
                pasteProbe
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 640)
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
            Text("Hold fn, talk, release. Three permissions make that work anywhere on your Mac.")
                .foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Permissions", trailing: state.permissions.allGranted ? "All granted" : nil)
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
            Text("Rebuilding an ad-hoc signed app changes its code signature, and macOS may ask for Accessibility again. The README explains how to make the grant stick with a self-signed certificate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var apiKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Anthropic API key", trailing: hasStoredKey ? "Stored in Keychain" : nil)
            Text("Used from phase 2 to compile transcripts into prompts. Stored in your login keychain, never in a file.")
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

    private var pasteProbe: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Test paste", trailing: nil)
            Text("Click into the field, then press the button. If Accessibility is granted, the marker text appears in the field and your clipboard is restored afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Paste lands here", text: $pasteTarget)
                    .textFieldStyle(.roundedBorder)
                Button("Test paste") { runPasteProbe() }
                    .disabled(!state.permissions.accessibility)
            }
            if let pasteMessage {
                Text(pasteMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
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
        let value = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.set(value, for: .anthropicAPIKey)
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

    private func runPasteProbe() {
        pasteTarget = ""
        switch PasteProbe.run() {
        case .notTrusted:
            pasteMessage = "Accessibility is not granted yet."
        case .posted:
            pasteMessage = "Posted ⌘V…"
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                pasteMessage = pasteTarget.contains(PasteProbe.marker)
                    ? "Paste works. Clipboard restored."
                    : "Nothing arrived. Make sure the field above has focus, then try again."
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
