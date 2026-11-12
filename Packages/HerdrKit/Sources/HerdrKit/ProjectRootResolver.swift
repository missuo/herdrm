import Foundation

/// A Space's project: one main repository root (or a non-git directory) plus the
/// worktree checkouts that belong to it. Keyed by device and root path.
public struct ProjectIdentity: Equatable, Sendable, Codable {
    public var deviceID: UUID
    public var root: String
    public var worktreeRoots: [String]

    public init(deviceID: UUID, root: String, worktreeRoots: [String]) {
        self.deviceID = deviceID
        self.root = root
        self.worktreeRoots = worktreeRoots
    }

    public var name: String { (root as NSString).lastPathComponent }

    public var key: String { "\(deviceID.uuidString):\(root)" }

    /// Basename tokens minus version-like ones: "acme-app" → ["acme", "app"], "foo-v2" → ["foo"].
    public var tokens: [String] {
        name
            .components(separatedBy: CharacterSet(charactersIn: "-_. "))
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0.range(of: #"^v?\d+$"#, options: .regularExpression) == nil }
    }
}

/// Turns the git facts probed for each pane's directory into one project root.
public enum ProjectRootResolver {
    /// Returns nil when there are no roots and no override, or when the only non-git directories
    /// are the home directory and "/".
    public static func resolve(
        roots: [ProbeRoot], focusedCwd: String?, home: String, override: String?
    ) -> (root: String, worktreeRoots: [String])? {
        if let override {
            let path = normalized(override)
            return (path, [path])
        }
        guard !roots.isEmpty else { return nil }

        let groups = gitGroups(roots)
        if !groups.isEmpty {
            let focusedMain = focusedCwd.flatMap { focusedMainComponents(cwd: $0, in: roots) }
            var best = groups[0]
            for group in groups.dropFirst() {
                let hasMoreCwds = group.roots.count > best.roots.count
                let tiedButFocused = group.roots.count == best.roots.count
                    && group.rootComponents == focusedMain
                    && best.rootComponents != focusedMain
                if hasMoreCwds || tiedButFocused {
                    best = group
                }
            }
            return (best.rootPath, best.worktreeRoots.sorted())
        }

        let cwds = roots.map(\.cwd)
        let ancestor = commonAncestor(of: cwds)
        let ancestorComponents = components(ancestor)
        // An ancestor that is "/" or contains home is too broad to be a project.
        if ancestorComponents.isEmpty || components(home).starts(with: ancestorComponents) {
            // The focused pane's directory, else the first one that is a real directory. Home
            // itself (or "/") is never a project: scanning it would walk the whole tree.
            let homeComponents = components(home)
            let usable = ([focusedCwd].compactMap { $0 } + cwds).map(normalized).first {
                let parts = components($0)
                return !parts.isEmpty && parts != homeComponents
            }
            guard let fallback = usable else { return nil }
            return (fallback, [fallback])
        }
        return (ancestor, [ancestor])
    }

    // MARK: - Git grouping

    private struct Group {
        var rootPath: String
        var rootComponents: [String]
        var roots: [ProbeRoot]
        var worktreeRoots: [String]
    }

    /// Groups git roots by main root, in first-seen order. Non-git roots are skipped.
    private static func gitGroups(_ roots: [ProbeRoot]) -> [Group] {
        var groups: [Group] = []
        for probeRoot in roots {
            guard let main = mainRoot(of: probeRoot) else { continue }
            let mainComponents = components(main)
            let worktree = normalized(probeRoot.toplevel ?? main)
            if let index = groups.firstIndex(where: { $0.rootComponents == mainComponents }) {
                groups[index].roots.append(probeRoot)
                if !groups[index].worktreeRoots.contains(worktree) {
                    groups[index].worktreeRoots.append(worktree)
                }
            } else {
                groups.append(Group(
                    rootPath: main,
                    rootComponents: mainComponents,
                    roots: [probeRoot],
                    worktreeRoots: [worktree]
                ))
            }
        }
        return groups
    }

    /// The main repository root: the parent of a `.git` common dir (so a worktree maps
    /// to its main checkout), otherwise the toplevel. Nil for a non-git directory.
    /// `commonDir` must be absolute: the probe resolves it with `pwd -P`.
    static func mainRoot(of probeRoot: ProbeRoot) -> String? {
        if let commonDir = probeRoot.commonDir {
            let common = normalized(commonDir)
            if common.hasSuffix("/.git") {
                let parent = String(common.dropLast(".git".count + 1))
                return parent.isEmpty ? "/" : parent
            }
        }
        return probeRoot.toplevel.map(normalized)
    }

    /// Main root components of the root whose cwd is the longest prefix of `cwd`.
    private static func focusedMainComponents(cwd: String, in roots: [ProbeRoot]) -> [String]? {
        let target = components(cwd)
        let match = roots
            .filter { target.starts(with: components($0.cwd)) }
            .max { components($0.cwd).count < components($1.cwd).count }
        return match.flatMap(mainRoot(of:)).map(components)
    }

    // MARK: - Paths

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Longest shared leading path components, as an absolute path ("/" when none).
    private static func commonAncestor(of paths: [String]) -> String {
        guard var shared = paths.first.map(components) else { return "/" }
        for path in paths.dropFirst() {
            let other = components(path)
            var count = 0
            while count < shared.count, count < other.count, shared[count] == other[count] {
                count += 1
            }
            shared = Array(shared.prefix(count))
        }
        return "/" + shared.joined(separator: "/")
    }
}
