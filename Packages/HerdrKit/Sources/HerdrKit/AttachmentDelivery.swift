import Foundation

public enum AgentAttachmentSource: Sendable, Equatable {
    /// Image pixels supplied directly by the clipboard.
    case imageData
    /// Files supplied by URL; image-only sets can use image-specific delivery.
    case files(allImages: Bool)
}

public enum AgentAttachmentPathSyntax: String, Decodable, Sendable, Equatable {
    case shellQuoted = "shell_quoted"

    public func format(_ path: String) -> String {
        switch self {
        case .shellQuoted:
            return ShellQuoting.quoted(path)
        }
    }
}

public struct AgentAttachmentCapabilities: Decodable, Sendable, Equatable {
    public let nativeClipboardImageData: Bool
    public let imagePath: AgentAttachmentPathSyntax?
    public let filePath: AgentAttachmentPathSyntax?

    public init(
        nativeClipboardImageData: Bool = false,
        imagePath: AgentAttachmentPathSyntax? = nil,
        filePath: AgentAttachmentPathSyntax? = nil
    ) {
        self.nativeClipboardImageData = nativeClipboardImageData
        self.imagePath = imagePath
        self.filePath = filePath
    }

    enum CodingKeys: String, CodingKey {
        case nativeClipboardImageData = "native_clipboard_image_data"
        case imagePath = "image_path"
        case filePath = "file_path"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nativeClipboardImageData = try container.decodeIfPresent(
            Bool.self,
            forKey: .nativeClipboardImageData
        ) ?? false
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
            .flatMap(AgentAttachmentPathSyntax.init(rawValue:))
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
            .flatMap(AgentAttachmentPathSyntax.init(rawValue:))
    }
}

public struct AgentManifestCapabilities: Decodable, Sendable, Equatable {
    public let attachments: AgentAttachmentCapabilities?
}

public struct AgentManifestInfo: Decodable, Sendable, Equatable {
    public let agent: String
    public let aliases: [String]
    public let capabilities: AgentManifestCapabilities?

    enum CodingKeys: String, CodingKey {
        case agent
        case aliases
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(String.self, forKey: .agent)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        capabilities = try container.decodeIfPresent(
            AgentManifestCapabilities.self,
            forKey: .capabilities
        )
    }
}

public struct AgentAttachmentCapabilityRegistry: Sendable, Equatable {
    private let capabilitiesByAgentKind: [String: AgentAttachmentCapabilities]

    public init(manifests: [AgentManifestInfo] = []) {
        var capabilitiesByAgentKind: [String: AgentAttachmentCapabilities] = [:]
        for manifest in manifests {
            guard let capabilities = manifest.capabilities?.attachments else { continue }
            for agentKind in [manifest.agent] + manifest.aliases {
                capabilitiesByAgentKind[Self.key(for: agentKind)] = capabilities
            }
        }
        if !manifests.contains(where: { $0.capabilities != nil }) {
            for (agentKinds, capabilities) in Self.legacyFallbacks {
                for agentKind in agentKinds {
                    capabilitiesByAgentKind[Self.key(for: agentKind)] = capabilities
                }
            }
        }
        self.capabilitiesByAgentKind = capabilitiesByAgentKind
    }

    public func capabilities(for agentKind: String?) -> AgentAttachmentCapabilities? {
        guard let agentKind else { return nil }
        return capabilitiesByAgentKind[Self.key(for: agentKind)]
    }

    private static func key(for agentKind: String) -> String {
        agentKind.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// Compatibility for Herdr servers predating manifest capabilities — which
    /// is every release through 0.8.2, so today this table is what actually
    /// applies. Once any manifest advertises capabilities, the server becomes
    /// authoritative. Alias spellings mirror the `aliases` in herdr's
    /// agent-detection manifests; herdr reports the manifest id as a pane's
    /// agent kind, so the aliases are only defensive.
    ///
    /// Every kind listed binds Ctrl+V to a clipboard read that attaches image
    /// pixels (each shells out to `osascript` for `«class PNGf»` on macOS), and
    /// resolves a pasted path — Claude, Codex, Cursor, Gemini and OpenCode
    /// attach it in the composer, while Copilot, Grok and pi leave it as text
    /// for a file-read tool that returns images as vision input. Kinds whose
    /// handling is unverified stay out of the table and paste as plain text.
    private static let legacyFallbacks: [([String], AgentAttachmentCapabilities)] = [
        (
            [
                "claude", "claude-code",
                "codex", "codex-cli", "openai-codex",
                "copilot", "github-copilot", "ghcs",
                "cursor", "cursor-agent",
                "gemini",
                "grok", "grok-build",
                "opencode", "open-code",
                "pi",
            ],
            AgentAttachmentCapabilities(
                nativeClipboardImageData: true,
                imagePath: .shellQuoted,
                filePath: .shellQuoted
            )
        ),
    ]
}

public enum AgentAttachmentDeliveryAction: Sendable, Equatable {
    case unsupported
    /// Forward the paste shortcut so an agent on this Mac reads the clipboard.
    case nativeClipboard
    /// Materialize resources on the agent's device, then paste their paths.
    case devicePaths(AgentAttachmentPathSyntax)
}

public enum AgentAttachmentDeliveryPolicy {
    public static func action(
        capabilities: AgentAttachmentCapabilities?,
        deviceKind: Device.Kind,
        source: AgentAttachmentSource
    ) -> AgentAttachmentDeliveryAction {
        guard let capabilities else { return .unsupported }
        let isLocal = if case .local = deviceKind { true } else { false }

        switch source {
        case .imageData:
            if isLocal, capabilities.nativeClipboardImageData {
                return .nativeClipboard
            }
            return capabilities.imagePath.map(AgentAttachmentDeliveryAction.devicePaths)
                ?? .unsupported
        case .files(allImages: true):
            // A copied image file is still an image: a local agent that reads
            // clipboard images natively (Claude Code's [Image #1] flow) gets
            // the paste shortcut, same as raw image data — not a quoted path.
            if isLocal, capabilities.nativeClipboardImageData {
                return .nativeClipboard
            }
            let pathSyntax = capabilities.imagePath ?? capabilities.filePath
            return pathSyntax.map(AgentAttachmentDeliveryAction.devicePaths) ?? .unsupported
        case .files(allImages: false):
            return capabilities.filePath.map(AgentAttachmentDeliveryAction.devicePaths)
                ?? .unsupported
        }
    }

    /// Path syntax for files dropped onto the terminal. A drop never goes
    /// through the clipboard, so `nativeClipboard` is meaningless here and a
    /// drop always resolves to paths — quoted like cmux even when the pane has
    /// no agent capabilities (a bare shell just receives the path as text).
    /// Remote devices still upload first, then paste the device-side paths.
    public static func dropAction(
        capabilities: AgentAttachmentCapabilities?,
        allImages: Bool
    ) -> AgentAttachmentPathSyntax {
        let preferred = allImages
            ? capabilities?.imagePath ?? capabilities?.filePath
            : capabilities?.filePath
        return preferred ?? .shellQuoted
    }
}