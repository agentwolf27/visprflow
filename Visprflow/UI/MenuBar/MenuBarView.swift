import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Visprflow")
                    .font(.headline)
                Spacer()
                Text(state.permissions.allGranted ? "Ready" : "Needs setup")
                    .font(.caption)
                    .foregroundStyle(state.permissions.allGranted ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Permission.allCases.filter(\.isRequired)) { permission in
                    Label {
                        Text(permission.title)
                    } icon: {
                        Image(systemName: state.permissions.isGranted(permission) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.permissions.isGranted(permission) ? .green : .secondary)
                    }
                    .font(.callout)
                }
            }

            Divider()

            Button("Destinations…") {
                state.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Setup…") {
                state.showSetup()
            }

            Button("Quit Visprflow") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(14)
        .frame(width: 240)
        .task {
            state.refreshPermissions()
        }
    }
}
