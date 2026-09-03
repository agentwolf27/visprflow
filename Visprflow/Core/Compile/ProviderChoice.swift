import Foundation

/// Where rewrites are sent.
enum ProviderChoice: String, Codable, Sendable, CaseIterable {
    /// Nothing leaves the Mac. Mechanical cleanup only, and instant.
    case local
    /// The `claude` command line tool, billed against your Claude subscription.
    case subscription
    /// The Anthropic API, billed per token against a key.
    case apiKey

    var displayName: String {
        switch self {
        case .local: "On this Mac"
        case .subscription: "My Claude subscription"
        case .apiKey: "Anthropic API key"
        }
    }

    var summary: String {
        switch self {
        case .local:
            "Instant and free. Removes fillers and stutters, applies spoken punctuation, fixes capitalisation. Cannot resolve a self-correction, so those go to a model."
        case .subscription:
            "The same models, billed against your Claude plan rather than per token. Roughly 3 seconds to the first word and 6 to 10 to finish, so it suits a compiled prompt you preview rather than a quick message."
        case .apiKey:
            "Fastest: about 0.7 seconds to the first word. Costs a fraction of a cent per dictation."
        }
    }

    /// The speed the user should expect, for the settings window.
    var latencyNote: String {
        switch self {
        case .local: "instant"
        case .subscription: "3–10 s"
        case .apiKey: "1–2 s"
        }
    }
}

/// How the app picks a provider for a given edit level.
///
/// The default is a mix rather than a single choice, because the levels have opposite needs.
/// Cleaning up "hey can you send me the figma link" has to feel instant and happens constantly;
/// restructuring a rambling request into a prompt is worth waiting for and happens rarely, and
/// you are looking at a preview while it works.
struct ProviderPolicy: Codable, Sendable, Equatable {
    /// Used for LIGHT edits, where the work is mechanical.
    var fastPath: ProviderChoice = .local
    /// Used for MEDIUM and FULL, where judgement is needed.
    var compilePath: ProviderChoice = .subscription

    static let `default` = ProviderPolicy()

    /// Everything through the API: the fastest configuration, and the one that costs money.
    static let allAPI = ProviderPolicy(fastPath: .apiKey, compilePath: .apiKey)

    /// Nothing leaves the Mac at all. Self-corrections stay unresolved.
    static let offline = ProviderPolicy(fastPath: .local, compilePath: .local)

    func provider(for level: EditLevel) -> ProviderChoice {
        switch level {
        case .verbatim, .light: fastPath
        case .medium, .full: compilePath
        }
    }
}

/// Routes each request to the provider the policy names, and escalates when the local path
/// admits it cannot do the job.
struct RoutingGenerator: TextGenerating {
    var policy: ProviderPolicy
    var local: any TextGenerating
    var subscription: any TextGenerating
    var api: any TextGenerating
    /// The level this request is for, since the routing depends on it.
    var level: EditLevel

    init(
        policy: ProviderPolicy,
        level: EditLevel,
        local: any TextGenerating = LocalGenerator(),
        subscription: any TextGenerating = ClaudeCLIGenerator(),
        api: any TextGenerating = ClaudeGenerator()
    ) {
        self.policy = policy
        self.level = level
        self.local = local
        self.subscription = subscription
        self.api = api
    }

    func generate(
        _ request: GenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var choice = policy.provider(for: level)

        // The local path handles disfluencies and punctuation, not judgement. When the
        // transcript contains a self-correction, resolving it wrongly would silently change
        // what the user meant, so hand it to whichever model the compile path uses.
        if choice == .local,
           let transcript = LocalGenerator.transcript(in: request.user),
           LocalCleanup.needsModel(transcript) {
            Log.compile.info("Self-correction detected; escalating from local to \(self.policy.compilePath.rawValue, privacy: .public)")
            choice = policy.compilePath == .local ? .local : policy.compilePath
        }

        switch choice {
        case .local:
            return try await local.generate(request, onDelta: onDelta)
        case .subscription:
            return try await subscription.generate(request, onDelta: onDelta)
        case .apiKey:
            return try await api.generate(request, onDelta: onDelta)
        }
    }
}
