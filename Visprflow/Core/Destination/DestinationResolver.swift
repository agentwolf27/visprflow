import Foundation

/// What the resolver knows about the focused window. Kept free of AppKit so the matching rules
/// can be tested exhaustively without a running app.
struct FocusContext: Sendable, Equatable {
    var bundleIdentifier: String?
    /// Process id of the focused app, used to find what is running inside a terminal.
    var processIdentifier: pid_t?
    var windowTitle: String?
    /// Address of the front tab, when the focused app is a browser.
    var browserURL: String?
    /// Foreground process on the terminal's tty, such as `claude`, `codex` or `zsh`.
    var terminalProcess: String?
    /// The project the terminal is sitting in, when there is one.
    var workspace: WorkspaceContext = .none
    var isSecureInput: Bool = false

    static let unknown = FocusContext()
}

/// Maps a focused window to the destination that should shape the text.
enum DestinationResolver {
    /// Terminal emulators. What matters inside them is which process is in the foreground.
    static let terminalBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "com.tabby.app",
    ]

    /// Coding agents worth compiling a full prompt for.
    static let agentProcesses: Set<String> = [
        "claude", "codex", "aider", "opencode", "goose", "amp", "cursor-agent", "gemini",
    ]

    static let editorBundles: Set<String> = [
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "dev.zed.Zed",
        "com.exafunction.windsurf",
    ]

    static let browserBundles: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "company.thebrowser.Browser",      // Arc
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static let messagingBundles: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "com.microsoft.teams2",
        "com.linear",
    ]

    static let emailBundles: Set<String> = [
        "com.apple.mail",
        "com.readdle.smartemail-Mac",
        "com.superhuman.electron",
        "com.microsoft.Outlook",
        "com.missiveapp.missive",
    ]

    /// Hosts that mean a chat assistant is on screen.
    static let chatHosts: Set<String> = [
        "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com",
        "perplexity.ai", "www.perplexity.ai", "poe.com", "grok.com", "x.ai",
    ]

    static let messageHosts: Set<String> = [
        "slack.com", "app.slack.com", "discord.com", "web.whatsapp.com",
        "teams.microsoft.com", "linear.app", "github.com",
    ]

    static let emailHosts: Set<String> = [
        "mail.google.com", "outlook.office.com", "outlook.live.com", "mail.proton.me",
    ]

    /// Picks the destination for a focused window. Falls back to `document`, which only
    /// cleans the text up, because guessing wrong there is the least damaging outcome.
    static func resolve(_ context: FocusContext) -> Destination {
        guard let bundle = context.bundleIdentifier else { return .document }

        if terminalBundles.contains(bundle) {
            return resolveTerminal(context)
        }
        if editorBundles.contains(bundle) {
            // Cursor, VS Code, Zed and Windsurf all put an agent chat pane beside the editor,
            // and that pane is what people dictate into.
            return .cursor
        }
        if browserBundles.contains(bundle) {
            return resolveBrowser(context)
        }
        if messagingBundles.contains(bundle) { return .message }
        if emailBundles.contains(bundle) { return .email }
        return .document
    }

    private static func resolveTerminal(_ context: FocusContext) -> Destination {
        guard let process = context.terminalProcess?.lowercased() else {
            // No process information: treat it as a shell, because reformatting a shell
            // command is worse than leaving a sentence uncleaned.
            return .shell
        }
        let name = process.split(separator: "/").last.map(String.init) ?? process
        if name == "codex" { return .codex }
        if agentProcesses.contains(name) { return .claudeCode }
        return .shell
    }

    private static func resolveBrowser(_ context: FocusContext) -> Destination {
        guard let host = host(of: context.browserURL) else { return .document }
        if chatHosts.contains(host) { return .chat }
        if messageHosts.contains(host) { return .message }
        if emailHosts.contains(host) { return .email }
        // An unrecognised site is just a text field.
        return .document
    }

    /// Host of a URL, tolerating an address typed without a scheme.
    static func host(of urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let host = URL(string: urlString)?.host()?.lowercased() {
            return host
        }
        if let host = URL(string: "https://\(urlString)")?.host()?.lowercased() {
            return host
        }
        return nil
    }
}
