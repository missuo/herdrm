#if os(macOS)
import Foundation

/// One SSH probe for the whole catalog. Login banners are outside the framed
/// result, so they cannot become agent names or masquerade as an empty catalog.
enum RemoteAgentCatalog {
    static let begin = "HERDRM_AGENT_CATALOG_BEGIN"
    static let end = "HERDRM_AGENT_CATALOG_END"

    static func unixScript(kinds: [String]) -> String {
        var lines = ["printf '%s\\n' '\(begin)'"]
        for (index, kind) in kinds.enumerated() {
            let binary = ShellQuoting.quoted(HerdrService.binaryName(for: kind))
            lines.append("if resolved=$(command -v \(binary) 2>/dev/null) && [ -f \"$resolved\" ] && [ -x \"$resolved\" ]; then printf '\(index)\\t%s\\n' \"$resolved\"; fi")
        }
        lines.append("printf '%s\\n' '\(end)'")
        return lines.joined(separator: "\n")
    }

    static func command(kinds: [String], platform: SSHTunnel.RemotePlatform) -> String {
        switch platform {
        case .unix:
            // Match interactive login PATH (nvm, user-installed CLIs, etc.), then
            // run the probe with POSIX syntax even when the login shell is fish.
            let probe = "exec /bin/sh -c " + ShellQuoting.quoted(unixScript(kinds: kinds))
            let login = "exec \"${SHELL:-/bin/sh}\" -ilc " + ShellQuoting.quoted(probe)
            return "exec /bin/sh -c " + ShellQuoting.quoted(login)
        case .windows:
            return SSHTunnel.powershellEncodedCommand(windowsScript(kinds: kinds))
        }
    }

    static func windowsScript(kinds: [String]) -> String {
        var lines = ["$ErrorActionPreference = 'Stop'", "Write-Output '\(begin)'"]
        for (index, kind) in kinds.enumerated() {
            let binary = HerdrService.binaryName(for: kind).replacingOccurrences(of: "'", with: "''")
            lines.append("$found = Get-Command -Name '\(binary)' -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1")
            lines.append("if ($found) { Write-Output (\"\(index)`t\" + $found.Path) }")
        }
        lines.append("Write-Output '\(end)'")
        return lines.joined(separator: "\n")
    }

    static func parse(_ output: String, kinds: [String]) throws -> [HerdrService.InstalledAgent] {
        let lines = output.components(separatedBy: .newlines)
        guard let first = lines.firstIndex(of: begin),
              let last = lines[(first + 1)...].firstIndex(of: end) else {
            throw HerdrError.fileOperationFailed("The remote shell did not complete the agent CLI check.")
        }
        var paths: [Int: String] = [:]
        for line in lines[(first + 1)..<last] where !line.isEmpty {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let index = Int(fields[0]), kinds.indices.contains(index),
                  !fields[1].isEmpty else {
                throw HerdrError.fileOperationFailed("The remote shell returned an invalid agent CLI check result.")
            }
            paths[index] = String(fields[1])
        }
        return kinds.enumerated().compactMap { index, kind in
            paths[index].map { HerdrService.InstalledAgent(kind: kind, path: $0) }
        }
    }
}
#endif
