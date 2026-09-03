import Foundation

/// The user's per-destination overrides.
///
/// This is the box Wispr Flow does not have: a free-text instruction for each destination
/// ("in Slack keep it lowercase", "for Claude Code always ask for a plan when it touches more
/// than one file"), plus control over the level and whether a preview is required.
struct DestinationOverride: Codable, Sendable, Equatable {
    var instructions: String?
    var defaultLevel: EditLevel?
    var requiresPreview: Bool?
    var allowsAutoSubmit: Bool?
    var strategy: InsertionStrategy?
}

/// Stores overrides in user defaults, keyed by destination identifier.
///
/// `UserDefaults` is thread-safe but not marked `Sendable`, so the reference is held unchecked.
struct DestinationSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "destinationOverrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func overrides() -> [String: DestinationOverride] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: DestinationOverride].self, from: data)
        else { return [:] }
        return decoded
    }

    func override(for destinationID: String) -> DestinationOverride? {
        overrides()[destinationID]
    }

    func setOverride(_ override: DestinationOverride?, for destinationID: String) {
        var all = overrides()
        all[destinationID] = override
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }

    /// Returns the destination with any user override applied.
    func apply(to destination: Destination) -> Destination {
        guard let override = override(for: destination.id) else { return destination }
        var result = destination
        if let instructions = override.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            result.instructions = instructions
        }
        if let level = override.defaultLevel { result.defaultLevel = level }
        if let preview = override.requiresPreview { result.requiresPreview = preview }
        if let submit = override.allowsAutoSubmit { result.allowsAutoSubmit = submit }
        if let strategy = override.strategy { result.strategy = strategy }
        return result
    }
}
