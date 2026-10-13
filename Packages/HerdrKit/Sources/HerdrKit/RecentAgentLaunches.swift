import Foundation

/// One New Agent launch, kept so it can be started again with one click from
/// the New Agent sheet's Recent list.
public struct RecentAgentLaunch: Codable, Equatable, Sendable, Identifiable {
    public let deviceID: UUID
    public let kind: String
    /// The space it started in. Spaces are matched by name, since herdr's
    /// workspace ids do not survive a closed space.
    public let spaceLabel: String
    /// The agent's folder, to open the space again when it was closed.
    public let directory: String?
    public let arguments: [String]
    /// A grazr account the agent had to itself; nil for the shared rotation.
    public let grazrAccountID: String?
    public let date: Date

    public var id: String { "\(deviceID.uuidString)|\(kind)|\(spaceLabel)" }

    public init(
        deviceID: UUID, kind: String, spaceLabel: String, directory: String?,
        arguments: [String], grazrAccountID: String?, date: Date
    ) {
        self.deviceID = deviceID
        self.kind = kind
        self.spaceLabel = spaceLabel
        self.directory = directory
        self.arguments = arguments
        self.grazrAccountID = grazrAccountID
        self.date = date
    }
}

/// The last launches, newest first, one per device, kind and space.
public enum RecentAgentLaunches {
    public static let limit = 10
    public static let defaultsKey = "newAgent.recent"

    public static func recording(_ launch: RecentAgentLaunch, into list: [RecentAgentLaunch]) -> [RecentAgentLaunch] {
        Array(([launch] + list.filter { $0.id != launch.id }).prefix(limit))
    }

    /// Adds agents already running, after the recorded launches and only
    /// where their device, agent and space are not listed yet, so the list
    /// is useful before anything was started from New Agent.
    public static func seeding(_ running: [RecentAgentLaunch], into list: [RecentAgentLaunch]) -> [RecentAgentLaunch] {
        var result = list
        for launch in running where result.count < limit && !result.contains(where: { $0.id == launch.id }) {
            result.append(launch)
        }
        return result
    }

    public static func load(from defaults: UserDefaults = .standard) -> [RecentAgentLaunch] {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([RecentAgentLaunch].self, from: data)
        else { return [] }
        return list
    }

    public static func save(_ list: [RecentAgentLaunch], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Array(list.prefix(limit))) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
