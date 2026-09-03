import Foundation

/// Stores which provider handles which edit level.
struct ProviderSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "providerPolicy"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func policy() -> ProviderPolicy {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ProviderPolicy.self, from: data)
        else { return .default }
        return decoded
    }

    func save(_ policy: ProviderPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: key)
        Log.compile.info("Provider policy: fast=\(policy.fastPath.rawValue, privacy: .public) compile=\(policy.compilePath.rawValue, privacy: .public)")
    }
}
