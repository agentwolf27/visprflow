import SwiftUI

/// What the overlay is showing right now.
enum HUDState: Equatable, Sendable {
    case hidden
    /// Recording. `locked` means hands-free, so the key is not being held.
    case listening(level: Float, seconds: TimeInterval, locked: Bool)
    case transcribing
    /// The compiler is streaming its result in. Phase 2 fills this with real text.
    case compiling(partial: String)
    /// Waiting for the user to press Return to insert.
    case ready(text: String, level: EditLevel, destination: String)
    case inserted(characters: Int)
    case failed(message: String)
}

struct HUDView: View {
    let state: HUDState

    var body: some View {
        Group {
            switch state {
            case .hidden:
                EmptyView()
            case let .listening(level, seconds, locked):
                listening(level: level, seconds: seconds, locked: locked)
            case .transcribing:
                row(icon: "waveform", tint: .secondary) {
                    Text("Transcribing…").foregroundStyle(.secondary)
                }
            case let .compiling(partial):
                row(icon: "sparkles", tint: .accentColor) {
                    Text(partial.isEmpty ? "Compiling…" : partial)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
            case let .ready(text, level, destination):
                ready(text: text, level: level, destination: destination)
            case let .inserted(characters):
                row(icon: "checkmark.circle.fill", tint: .green) {
                    Text("Inserted \(characters) characters").foregroundStyle(.secondary)
                }
            case let .failed(message):
                row(icon: "exclamationmark.triangle.fill", tint: .orange) {
                    Text(message).lineLimit(2)
                }
            }
        }
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Pieces

    private func listening(level: Float, seconds: TimeInterval, locked: Bool) -> some View {
        row(icon: locked ? "lock.fill" : "mic.fill", tint: .red) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(locked ? "Hands-free" : "Listening")
                        .font(.callout.weight(.medium))
                    Text(Self.elapsed(seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(locked ? "tap to stop · esc" : "release to compile · esc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                LevelMeter(level: level)
            }
        }
    }

    private func ready(text: String, level: EditLevel, destination: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.tint)
                Text(destination)
                    .font(.caption.weight(.medium))
                Text(level.displayName.uppercased())
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                Spacer()
                Text("⏎ insert · ⇥ level · esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.callout)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
    }

    private func row<Content: View>(
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Twenty bars driven by the current peak, with a little decay so it reads as a voice
/// rather than a flickering number.
private struct LevelMeter: View {
    let level: Float
    private let barCount = 28

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(colour(for: index))
                        .frame(width: 3, height: height(for: index, in: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func normalised(_ index: Int) -> Float {
        // A log-ish curve, so quiet speech still moves the meter.
        let scaled = min(1, max(0, level * 6))
        let position = Float(index) / Float(barCount)
        return scaled > position ? 1 : 0.12
    }

    private func height(for index: Int, in available: CGFloat) -> CGFloat {
        let base = CGFloat(normalised(index))
        // Taller in the middle so it reads as a waveform rather than a progress bar.
        let centre = 1 - abs(CGFloat(index) / CGFloat(barCount) - 0.5) * 1.2
        return max(3, available * base * centre)
    }

    private func colour(for index: Int) -> Color {
        normalised(index) > 0.5 ? .red : .secondary.opacity(0.4)
    }
}
