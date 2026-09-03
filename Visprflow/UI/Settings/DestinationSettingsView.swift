import SwiftUI

/// Per-destination settings: the free-text instruction, the default edit level, and whether
/// a compiled prompt waits for Return.
///
/// This is the control Wispr Flow does not offer. It ships four fixed tones chosen by app
/// category, English only, with no way to say "in Slack keep it lowercase" or "for Claude Code
/// always ask for a plan when more than one file changes".
struct DestinationSettingsView: View {
    @State private var settings = DestinationSettings()
    @State private var selection: String = Destination.claudeCode.id
    @State private var draft = DestinationOverride()

    private var destination: Destination {
        Destination.named(selection) ?? .document
    }

    var body: some View {
        HSplitView {
            list
            detail
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { loadDraft() }
        .onChange(of: selection) { loadDraft() }
    }

    private var list: some View {
        List(Destination.all, id: \.id, selection: $selection) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.body)
                Text(summary(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(item.id)
            .padding(.vertical, 2)
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.displayName).font(.title2.weight(.semibold))
                    Text(defaultsDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your instructions").font(.headline)
                    Text("Added to the compiler's rules for this destination only. Written the way you would tell a colleague.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { draft.instructions ?? "" },
                        set: { draft.instructions = $0 }
                    ))
                    .font(.body.monospaced())
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    Text(placeholder(for: destination))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Behaviour").font(.headline)

                    Picker("Edit level", selection: Binding(
                        get: { draft.defaultLevel ?? destination.defaultLevel },
                        set: { draft.defaultLevel = $0 }
                    )) {
                        ForEach(EditLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    Text(( draft.defaultLevel ?? destination.defaultLevel ).summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Show a preview before inserting", isOn: Binding(
                        get: { draft.requiresPreview ?? destination.requiresPreview },
                        set: { draft.requiresPreview = $0 }
                    ))
                    Text("Worth the keystroke where a wrong prompt costs more than a wrong message.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Insertion", selection: Binding(
                        get: { draft.strategy ?? destination.strategy },
                        set: { draft.strategy = $0 }
                    )) {
                        Text("Paste (⌘V)").tag(InsertionStrategy.paste)
                        Text("Paste (⇧Insert, for Electron terminals)").tag(InsertionStrategy.pasteShiftInsert)
                        Text("Replace the selection directly").tag(InsertionStrategy.accessibility)
                        Text("Type character by character").tag(InsertionStrategy.typing)
                    }
                }

                HStack {
                    Button("Save") { save() }
                        .keyboardShortcut(.return)
                    Button("Reset to defaults") { reset() }
                    Spacer()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Helpers

    private var defaultsDescription: String {
        let level = destination.defaultLevel.displayName.lowercased()
        let preview = destination.requiresPreview ? "shows a preview first" : "inserts straight away"
        return "By default: \(level) editing, \(preview)."
    }

    private func summary(for item: Destination) -> String {
        let override = settings.override(for: item.id)
        if let instructions = override?.instructions, !instructions.isEmpty {
            return "Custom instructions"
        }
        return item.defaultLevel.displayName
    }

    private func placeholder(for destination: Destination) -> String {
        switch destination.id {
        case "claude_code", "cursor", "codex":
            "For example: always ask for a plan first when more than one file changes."
        case "message":
            "For example: keep it lowercase, no greetings."
        case "email":
            "For example: sign off with my first name only."
        default:
            "For example: keep sentences short."
        }
    }

    private func loadDraft() {
        draft = settings.override(for: selection) ?? DestinationOverride()
    }

    private func save() {
        var value = draft
        if value.instructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            value.instructions = nil
        }
        settings.setOverride(value, for: selection)
        Log.app.info("Saved settings for \(self.selection, privacy: .public)")
    }

    private func reset() {
        settings.setOverride(nil, for: selection)
        draft = DestinationOverride()
    }
}
