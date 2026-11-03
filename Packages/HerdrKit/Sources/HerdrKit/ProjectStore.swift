import Foundation

/// On-disk shape of `projects.json`.
public struct ProjectStoreFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    /// Space root per workspace, keyed `"<deviceID>:<workspaceLabel>"`.
    public var spaceRoots: [String: String] = [:]
    /// Per-project overrides, keyed by project key.
    public var projects: [String: ProjectOverrides] = [:]

    public init(
        version: Int = 1, spaceRoots: [String: String] = [:],
        projects: [String: ProjectOverrides] = [:]
    ) {
        self.version = version
        self.spaceRoots = spaceRoots
        self.projects = projects
    }
}

// Synthesized Decodable ignores init defaults, so a file missing a key would fail to load.
extension ProjectStoreFile {
    private enum CodingKeys: String, CodingKey {
        case version, spaceRoots, projects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            spaceRoots: try c.decodeIfPresent([String: String].self, forKey: .spaceRoots) ?? [:],
            projects: try c.decodeIfPresent([String: ProjectOverrides].self, forKey: .projects) ?? [:])
    }
}

/// Persists per-project overrides and space roots as JSON under Application Support.
public final class ProjectStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "sb.moe.herdrm.projects")

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("projects.json")
    }

    /// Missing file yields an empty store. An undecodable file is moved aside to
    /// `projects.json.corrupt`. A file that cannot be read is left in place.
    public func load() -> ProjectStoreFile {
        queue.sync { loadUnlocked().file }
    }

    /// Skips the write when the existing file exists but cannot be read.
    public func save(_ file: ProjectStoreFile) {
        queue.sync {
            guard loadUnlocked().readable else { return }
            saveUnlocked(file)
        }
    }

    public func overrides(for key: String) -> ProjectOverrides {
        queue.sync { loadUnlocked().file.projects[key] ?? ProjectOverrides() }
    }

    public func update(key: String, _ mutate: (inout ProjectOverrides) -> Void) {
        queue.sync {
            var (file, readable) = loadUnlocked()
            // Never overwrite a file we could not read.
            guard readable else { return }
            var entry = file.projects[key] ?? ProjectOverrides()
            mutate(&entry)
            file.projects[key] = entry
            saveUnlocked(file)
        }
    }

    public func spaceRoot(deviceID: UUID, workspaceLabel: String) -> String? {
        queue.sync { loadUnlocked().file.spaceRoots[Self.spaceRootKey(deviceID, workspaceLabel)] }
    }

    /// Passing `nil` for `root` removes the stored root.
    public func setSpaceRoot(deviceID: UUID, workspaceLabel: String, root: String?) {
        queue.sync {
            var (file, readable) = loadUnlocked()
            guard readable else { return }
            let key = Self.spaceRootKey(deviceID, workspaceLabel)
            file.spaceRoots[key] = root
            saveUnlocked(file)
        }
    }

    private static func spaceRootKey(_ deviceID: UUID, _ workspaceLabel: String) -> String {
        "\(deviceID.uuidString):\(workspaceLabel)"
    }

    // Callers must hold `queue`.

    /// Returns the stored file and whether it was read. `readable` is false when the file
    /// exists but could not be read, in which case the caller must not write over it.
    private func loadUnlocked() -> (file: ProjectStoreFile, readable: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return (ProjectStoreFile(), true)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return (ProjectStoreFile(), false)
        }
        do {
            return (try JSONDecoder().decode(ProjectStoreFile.self, from: data), true)
        } catch {
            quarantineCorruptFile()
            return (ProjectStoreFile(), true)
        }
    }

    private func saveUnlocked(_ file: ProjectStoreFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(file) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func quarantineCorruptFile() {
        let corruptURL = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }
}
