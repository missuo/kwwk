import Foundation

/// Running the user's own, already signed-in Antigravity CLI (`agy`) as a
/// model backend, with no AirRelay in between.
///
/// `agy acp` is an Agent Client Protocol server over stdio. kwwk spawns it,
/// opens one ACP session per kwwk conversation, and hands kwwk's tools to it
/// through a loopback MCP server (``AgyMCPBridgeServer``). Every tool call
/// agy makes on that server runs inline through the agent loop's
/// ``CursorExecBridge``, so one kwwk turn is one ACP `session/prompt`.
///
/// Discovery is macOS-only: it is meant for the CLI on a Mac where the user
/// already ran `agy` and signed in. AirRelay stays the route everywhere
/// else (iOS, Linux backends).
public enum AgyLocal {
    /// The `model.provider` scope local agy registers under. It is the same
    /// scope the AirRelay route uses, so the `agy` catalog, `/model` group
    /// and `agy/<model>` overrides all work unchanged; the local provider
    /// simply replaces the relay one on this machine.
    public static let providerScope = AgyOAuth.providerId

    /// The wire `api` key the local provider registers under. The `agy`
    /// catalog rows carry `anthropic-messages` (the AirRelay wire), and the
    /// `/model` picker adopts each catalog row's `api`; registering the ACP
    /// provider under that same key in the `agy` scope routes every catalog
    /// model to it without rewriting the catalog per machine.
    public static let registryAPI = "anthropic-messages"

    /// Synthetic `ProviderSlot.storeId` for a local agy slot that has no
    /// stored credentials behind it (compare the CLI's `env:<provider>`).
    public static let slotStoreId = "local:agy"

    /// Display name for the local slot in `/model`.
    public static let displayName = "Antigravity CLI (local)"

    /// Name of the MCP server kwwk's tools are exposed under. agy prefixes
    /// every MCP tool with `mcp_<server>_`, which is how the permission
    /// policy tells kwwk's tools from agy's built-ins.
    static let mcpServerName = "kwwk"
    static var mcpToolPrefix: String { "mcp_\(mcpServerName)_" }

    /// Environment switch: `KWWK_AGY_LOCAL=0` (or `false`/`off`/`no`)
    /// disables local discovery even when `agy` is installed.
    public static let disableEnvironmentKey = "KWWK_AGY_LOCAL"
    /// Environment override for the `agy` executable path.
    public static let pathEnvironmentKey = "KWWK_AGY_PATH"

    /// Locate a runnable `agy` binary, or nil when local mode is off or no
    /// binary is found. Only checks that the file is executable: whether
    /// `agy` is signed in is only known once a session is opened, and the
    /// error then says how to fix it.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        #if os(macOS)
        if let flag = environment[disableEnvironmentKey]?.lowercased(),
           ["0", "false", "off", "no"].contains(flag) {
            return nil
        }
        if let explicit = environment[pathEnvironmentKey], !explicit.isEmpty {
            let path = (explicit as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for path in candidatePaths(environment: environment) where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
        #else
        return nil
        #endif
    }

    /// `$PATH` entries first, then where the installer and Homebrew put
    /// `agy` — a GUI-launched kwwk often has a minimal `$PATH`.
    static func candidatePaths(environment: [String: String]) -> [String] {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = environment["HOME"] ?? NSHomeDirectory()
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var seen: Set<String> = []
        return dirs.compactMap { dir in
            guard !dir.isEmpty else { return nil }
            let path = (dir as NSString).appendingPathComponent("agy")
            return seen.insert(path).inserted ? path : nil
        }
    }

    /// The `agy` model slug for a kwwk model id (`agy/<slug>` and bare
    /// slugs both accepted).
    static func slug(for modelId: String) -> String {
        modelId.hasPrefix(AgyModels.modelPrefix)
            ? String(modelId.dropFirst(AgyModels.modelPrefix.count))
            : modelId
    }

    /// The template model a local slot starts on: the catalog row for
    /// `modelId` (default `AgyModels.defaultModelId`), routed to the local
    /// provider. `baseURL` stays empty — there is no HTTP endpoint.
    public static func model(id modelId: String? = nil) -> Model {
        var model = AgyModels.model(id: slug(for: modelId ?? AgyModels.defaultModelId))
        model.api = registryAPI
        model.provider = providerScope
        model.baseURL = ""
        return model
    }

    /// Register the local provider on `APIRegistry.shared` (replacing any
    /// AirRelay provider in the `agy` scope) and return the session's
    /// starting point for it. Nil when no local `agy` is found.
    public static func register(
        modelOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> ResolvedAuth? {
        guard let executable = discover(environment: environment) else { return nil }
        await APIRegistry.shared.register(
            AgyLocalProvider(executable: executable),
            scope: providerScope
        )
        let model = model(id: modelOverride)
        return ResolvedAuth(
            model: model,
            modelLabel: "\(model.id) · \(displayName)",
            authResolver: nil
        )
    }

    /// The `/model` slot for a registered local provider.
    public static func slot(template: Model) -> ProviderSlot {
        ProviderSlot(
            storeId: slotStoreId,
            catalogProvider: AgyOAuth.providerId,
            displayName: displayName,
            template: template
        )
    }
}
