import Darwin
import XCTest
import HerdrKit
@testable import herdrm

@_silgen_name("flock")
private func identityTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class ManagedAgentRegistryTests: XCTestCase {
    private func temporaryRegistryURL() throws -> URL {
        // Foundation resolves /private/var back to /var on macOS; /var is a
        // symlink and must remain rejected by production's nofollow guard.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("herdrm-managed-agent-registry-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock {
            // Only this test's synthetic directory can contain a deny-delete ACL.
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/bin/chmod")
            cleanup.arguments = ["-RN", root.path]
            if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent("agent-reconcile.json")
    }

    private func writePrivate(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func addACL(_ rule: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", rule, url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func aclText(at url: URL) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ManagedAgentRegistryError.storageUnavailable }
        defer { Darwin.close(descriptor) }
        let acl = try XCTUnwrap(Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED))
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        let text = try XCTUnwrap(Darwin.acl_to_text(acl, &length))
        defer { Darwin.acl_free(text) }
        return String(cString: text)
    }

    func testMalformedOwnedFieldsCannotDowngradeToLegacyMatchingOrReplaceData() throws {
        let fields = ["name", "kind", "tab_label", "cwd", "pane_id", "tab_id", "terminal_id", "workspace_id"]
        for field in fields {
            for invalid: Any in [123, true, ["invalid": true], " \n"] {
                let url = try temporaryRegistryURL()
                var row: [String: Any] = ["name": "saved_agent", "kind": "future-kind",
                    "pane_id": "w1:p1", "cwd": "/tmp/project", "terminal_id": "original-terminal"]
                row[field] = invalid
                let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "targets": [row]])
                try writePrivate(bytes, to: url)
                let registry = ManagedAgentRegistry(fileURL: url)
                XCTAssertThrowsError(try registry.load(), field)
                XCTAssertThrowsError(try registry.upsert(intent()), field)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertNil(ManagedAgentIntent(json: row), "Malformed identity must not reach projection")
            }
        }
    }

    func testNullOptionalFieldsRemainCompatibleWithLegacyRecords() throws {
        let url = try temporaryRegistryURL()
        let row: [String: Any] = ["name": "saved_agent", "kind": "future-kind",
            "pane_id": "w1:p1", "cwd": "/tmp/project", "terminal_id": NSNull(),
            "workspace_id": NSNull(), "tab_label": NSNull(), "tab_id": NSNull()]
        try writePrivate(JSONSerialization.data(withJSONObject: ["version": 1, "targets": [row]]), to: url)
        let saved = try XCTUnwrap(ManagedAgentRegistry(fileURL: url).load().first)
        XCTAssertNil(saved.terminalID)
        XCTAssertEqual(saved.matchingPane(in: [try pane()], tabs: [try tab()])?.paneID, "w1:p1")
    }

    func testGrantACLOnExistingRegistryIsRejectedWithoutChangingDataOrPermissions() throws {
        for permission in ["read", "write"] {
            let url = try temporaryRegistryURL()
            let registry = ManagedAgentRegistry(fileURL: url)
            try registry.upsert(intent())
            let bytes = try Data(contentsOf: url)
            try addACL("everyone allow " + permission, to: url)
            XCTAssertThrowsError(try registry.load())
            XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testInheritedGrantACLPreventsNewRegistryCreation() throws {
        let url = try temporaryRegistryURL()
        let parent = url.deletingLastPathComponent()
        try addACL("everyone allow read,search,file_inherit,directory_inherit", to: parent)
        let registry = ManagedAgentRegistry(fileURL: url)
        XCTAssertThrowsError(try registry.load())
        XCTAssertThrowsError(try registry.upsert(intent()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testDenyOnlyACLDoesNotWeakenOrPreventPrivateStorage() throws {
        let url = try temporaryRegistryURL()
        let registry = ManagedAgentRegistry(fileURL: url)
        try addACL("everyone deny delete", to: url.deletingLastPathComponent())
        try registry.upsert(intent())
        try addACL("everyone deny execute", to: url)
        try addACL("everyone deny writesecurity", to: url)
        let before = try aclText(at: url)
        XCTAssertEqual(try registry.load().first?.name, "saved_agent")
        try registry.upsert(intent(name: "renamed_agent"))
        XCTAssertEqual(try registry.load().first?.name, "renamed_agent")
        XCTAssertEqual(try aclText(at: url), before, "Atomic replacement must preserve all original deny rules")
        try ManagedAgentRegistry(fileURL: url).upsert(intent(name: "saved_again"))
        XCTAssertEqual(try aclText(at: url), before, "Repeated writes must not accumulate ACL entries")
    }

    func testGrantACLOnLockIsRejected() throws {
        let url = try temporaryRegistryURL()
        let registry = ManagedAgentRegistry(fileURL: url)
        try registry.upsert(intent())
        let bytes = try Data(contentsOf: url)
        let lock = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".write.lock")
        try addACL("everyone allow write", to: lock)
        XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testContendedLockFailsWithoutReplacingRegistryOrCreatingTemporaryData() throws {
        let url = try temporaryRegistryURL()
        let registry = ManagedAgentRegistry(fileURL: url)
        try registry.upsert(intent())
        let bytes = try Data(contentsOf: url)
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".write.lock")
        let lock = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { Darwin.close(lock) }
        XCTAssertEqual(identityTestFlock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".agent-registry-") })
    }

    func testReplacedLockDuringSaveDoesNotAuthorizeCommit() throws {
        let url = try temporaryRegistryURL()
        try ManagedAgentRegistry(fileURL: url).upsert(intent())
        let bytes = try Data(contentsOf: url)
        let parent = url.deletingLastPathComponent()
        let registry = ManagedAgentRegistry(fileURL: url, beforeCommit: {
            let lock = parent.appendingPathComponent(url.lastPathComponent + ".write.lock")
            try FileManager.default.moveItem(at: lock, to: parent.appendingPathComponent("previous-lock"))
            try self.writePrivate(Data(), to: lock)
        })
        XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .contains { $0.hasPrefix(".agent-registry-") })
    }

    func testGrantACLAddedDuringSaveIsRejectedAndTemporaryFileIsCleaned() throws {
        for target in ["temporary", "lock", "parent"] {
            let url = try temporaryRegistryURL()
            try ManagedAgentRegistry(fileURL: url).upsert(intent())
            let bytes = try Data(contentsOf: url)
            let parent = url.deletingLastPathComponent()
            let registry = ManagedAgentRegistry(fileURL: url, beforeCommit: {
                let destination: URL
                switch target {
                case "temporary":
                    let temporary = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: parent.path)
                        .first { $0.hasPrefix(".agent-registry-") })
                    destination = parent.appendingPathComponent(temporary)
                case "lock": destination = parent.appendingPathComponent(url.lastPathComponent + ".write.lock")
                default: destination = parent
                }
                try self.addACL("everyone allow read", to: destination)
            })
            XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")), target)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .contains { $0.hasPrefix(".agent-registry-") })
        }
    }

    func testSavedUndetectedAgentAttachesToItsExistingTerminal() throws {
        let saved = try decode(AgentInfo.self, ["pane_id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1",
                                                "terminal_id": "term1", "name": "saved", "agent_status": "unknown"])
        XCTAssertEqual(ManagedAgentProjection.attachmentTarget(agent: saved, managedKind: "future-kind"),
                       .terminal(terminalID: "term1"))
        let detected = try decode(AgentInfo.self, ["pane_id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1",
                                                   "terminal_id": "term1", "name": "saved", "agent": "future-kind", "agent_status": "working"])
        XCTAssertEqual(ManagedAgentProjection.attachmentTarget(agent: detected, managedKind: "future-kind"),
                       .agent(paneID: "w1:p1"))
    }

    func testPostRenameFailureDoesNotClassifyCommittedIdentityAsRollback() throws {
        let url = try temporaryRegistryURL()
        var committed = false
        let registry = ManagedAgentRegistry(fileURL: url, afterCommit: { throw ManagedAgentRegistryError.storageUnavailable })
        let intent = ManagedAgentIntent(tabLabel: "Future", cwd: nil, name: "future", kind: "future", paneID: nil, tabID: nil)
        XCTAssertThrowsError(try registry.upsert(intent, onCommitted: { committed = true }))
        XCTAssertTrue(committed)
        XCTAssertEqual(try ManagedAgentRegistry(fileURL: url).load(), [intent])
    }
    func testLoadsExistingVersionOneSchemaWithoutBrandSpecificLogic() throws {
        let url = try temporaryRegistryURL()
        let root: [String: Any] = [
            "version": 1,
            "targets": [[
                "tab_label": "Future Agent",
                "cwd": "/tmp/future-agent",
                "name": "future_agent",
                "kind": "future-kind",
                "timeout_ms": 30000,
            ]],
        ]
        try writePrivate(JSONSerialization.data(withJSONObject: root), to: url)

        let intents = try ManagedAgentRegistry(fileURL: url).load()

        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents[0].name, "future_agent")
        XCTAssertEqual(intents[0].kind, "future-kind")
        XCTAssertEqual(intents[0].tabLabel, "Future Agent")
        XCTAssertEqual(intents[0].cwd, "/tmp/future-agent")
    }

    func testUpsertPreservesUnknownTopLevelAndPerTargetFields() throws {
        let url = try temporaryRegistryURL()
        let root: [String: Any] = [
            "version": 1,
            "future_top_level": ["enabled": true],
            "targets": [[
                "tab_label": "Future Agent",
                "cwd": "/tmp/future-agent",
                "name": "future_agent",
                "kind": "future-kind",
                "future_per_target": "keep-me",
            ]],
        ]
        try writePrivate(JSONSerialization.data(withJSONObject: root), to: url)

        let registry = ManagedAgentRegistry(fileURL: url)
        try registry.upsert(
            ManagedAgentIntent(
                tabLabel: "Future Agent",
                cwd: "/tmp/future-agent",
                name: "future_agent",
                kind: "future-kind-v2",
                paneID: "w9:p3",
                tabID: "w9:t2"
            )
        )

        let data = try Data(contentsOf: url)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let top = try XCTUnwrap(saved["future_top_level"] as? [String: Any])
        XCTAssertEqual(top["enabled"] as? Bool, true)

        let rows = try XCTUnwrap(saved["targets"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["future_per_target"] as? String, "keep-me")
        XCTAssertEqual(rows[0]["kind"] as? String, "future-kind-v2")
        XCTAssertEqual(rows[0]["pane_id"] as? String, "w9:p3")
        XCTAssertEqual(rows[0]["tab_id"] as? String, "w9:t2")
    }

    func testUpsertAppendsAnyGenericKindWithoutExistingRow() throws {
        let url = try temporaryRegistryURL()
        let registry = ManagedAgentRegistry(fileURL: url)

        try registry.upsert(
            ManagedAgentIntent(
                tabLabel: "Another Agent",
                cwd: "/tmp/another",
                name: "another_agent",
                kind: "deepseek-or-any-future-kind",
                paneID: "w4:p8",
                tabID: "w4:t7"
            )
        )

        let intents = try registry.load()
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents[0].kind, "deepseek-or-any-future-kind")
        XCTAssertEqual(intents[0].name, "another_agent")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func pane(_ id: String = "w1:p1", tab: String = "w1:t1", cwd: String = "/tmp/project", terminalID: String? = nil) throws -> PaneInfo {
        try decode(PaneInfo.self, [
            "pane_id": id, "tab_id": tab, "workspace_id": "w1",
            "terminal_id": terminalID ?? "term-" + id, "cwd": cwd,
        ])
    }

    private func tab(_ id: String = "w1:t1", label: String = "Saved Agent") throws -> TabInfo {
        try decode(TabInfo.self, ["tab_id": id, "workspace_id": "w1", "label": label])
    }

    private func intent(name: String = "saved_agent", paneID: String? = "w1:p1") -> ManagedAgentIntent {
        ManagedAgentIntent(tabLabel: "Saved Agent", cwd: "/tmp/project",
                           name: name, kind: "any-future-kind", paneID: paneID, tabID: "w1:t1")
    }

    func testSavedIdentitySurvivesRegistryReopenWithoutPretendingRuntimeWasDetected() throws {
        let url = try temporaryRegistryURL()
        try ManagedAgentRegistry(fileURL: url).upsert(intent())
        let reopened = try ManagedAgentRegistry(fileURL: url).load()
        let projection = ManagedAgentProjection.resolve(
            agents: [], panes: [try pane()], tabs: [try tab()], intents: reopened)
        let agent = try XCTUnwrap(projection.agents.first)
        XCTAssertEqual(agent.name, "saved_agent")
        XCTAssertEqual(agent.paneID, "w1:p1")
        XCTAssertEqual(projection.kindsByPane["w1:p1"], "any-future-kind")
        XCTAssertNil(agent.agentKindRaw)
        XCTAssertEqual(agent.status, .unknown)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let targets = try XCTUnwrap(saved["targets"] as? [[String: Any]])
        XCTAssertNil(targets.first?["auto_start"], "Identity persistence must not create a launch policy")
    }

    func testSavedIdentityNeverClaimsAnotherNamedAgentsPane() throws {
        let actual = try decode(AgentInfo.self, [
            "pane_id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1",
            "terminal_id": "term-w1:p1", "name": "other_agent",
            "agent": "actual-kind", "agent_status": "working",
        ])
        let result = ManagedAgentProjection.resolve(
            agents: [actual], panes: [try pane()], tabs: [try tab()], intents: [intent()])
        XCTAssertEqual(result.agents, [actual])
        XCTAssertEqual(result.kindsByPane, [:])
        XCTAssertTrue(result.boundIntents.isEmpty)
    }

    func testExplicitNamedAgentRebindsToMovedPaneAndRetainsItsRuntimeStatus() throws {
        let moved = try pane("w1:p9", tab: "w1:t9", cwd: "/tmp/moved")
        let actual = try decode(AgentInfo.self, [
            "pane_id": "w1:p9", "tab_id": "w1:t9", "workspace_id": "w1",
            "terminal_id": "term-w1:p9", "name": "saved_agent",
            "agent": "detected-kind", "agent_status": "working", "cwd": "/tmp/moved",
        ])
        let result = ManagedAgentProjection.resolve(
            agents: [actual], panes: [moved], tabs: [try tab("w1:t9", label: "Moved")],
            intents: [intent()])
        XCTAssertEqual(result.agents, [actual])
        XCTAssertEqual(result.boundIntents.first?.paneID, "w1:p9")
        XCTAssertEqual(result.boundIntents.first?.tabLabel, "Moved")
        XCTAssertEqual(result.boundIntents.first?.cwd, "/tmp/moved")
    }

    func testAmbiguousFallbackDoesNotInventAnAgent() throws {
        let result = ManagedAgentProjection.resolve(
            agents: [], panes: [try pane("w1:p8"), try pane("w1:p9")],
            tabs: [try tab()], intents: [intent(paneID: "old:p1")])
        XCTAssertTrue(result.agents.isEmpty)
        XCTAssertTrue(result.boundIntents.isEmpty)
    }

    func testSplitPaneAgentsInTheSameTabRemainSeparate() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        let first = intent()
        try registry.upsert(first)
        try registry.upsert(intent(name: "second_agent", paneID: "w1:p2"))
        try registry.upsert(first)
        let rows = try registry.load()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.paneID)), ["w1:p1", "w1:p2"])
    }

    func testClosingPaneRemovesOnlyItsSavedIdentity() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        try registry.upsert(intent())
        try registry.upsert(intent(name: "second_agent", paneID: "w1:p2"))
        try registry.remove(paneIDs: ["w1:p1"])
        XCTAssertEqual(try registry.load().map(\.name), ["second_agent"])
    }
    func testMigratedIdentitySurvivesDirectoryChangeAndRegistryReopen() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        let legacy = intent()
        XCTAssertNil(legacy.terminalID)
        XCTAssertNotNil(legacy.matchingPane(in: [try pane()], tabs: [try tab()]))
        try registry.upsert(legacy.rebound(to: try pane(), tab: try tab()))
        let saved = try XCTUnwrap(registry.load().first)
        XCTAssertEqual(saved.terminalID, "term-w1:p1")
        let changed = try pane(cwd: "/tmp/changed-directory")
        let result = ManagedAgentProjection.resolve(
            agents: [], panes: [changed], tabs: [try tab()], intents: [saved])
        XCTAssertEqual(result.agents.first?.name, "saved_agent")
        XCTAssertEqual(result.agents.first?.status, .unknown)
        XCTAssertEqual(result.boundIntents.first?.cwd, "/tmp/changed-directory")
    }

    func testTerminalIdentityDoesNotClaimReusedPaneOrAmbiguousTerminal() throws {
        let saved = intent().rebound(to: try pane(), tab: try tab())
        let replacement = try pane(terminalID: "replacement-terminal")
        XCTAssertNil(saved.matchingPane(in: [replacement], tabs: [try tab()]))
        let duplicate = try pane("w1:p2", terminalID: "term-w1:p1")
        XCTAssertNil(saved.matchingPane(in: [try pane(), duplicate], tabs: [try tab()]))
    }

    func testSameTerminalMayMoveWithoutReassigningLegacyFallback() throws {
        let saved = intent().rebound(to: try pane(), tab: try tab())
        let moved = try pane("w1:p9", tab: "w1:t9", cwd: "/tmp/moved", terminalID: "term-w1:p1")
        XCTAssertEqual(saved.matchingPane(in: [moved], tabs: [try tab("w1:t9")])?.paneID, "w1:p9")
        XCTAssertNil(intent().matchingPane(in: [try pane(cwd: "/tmp/changed")], tabs: [try tab()]))
    }

    func testTerminalIdentityUpsertAndRemovalPreserveOtherPaneOwners() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        let first = intent().rebound(to: try pane(), tab: try tab())
        let second = intent(name: "second_agent", paneID: "w1:p2")
            .rebound(to: try pane("w1:p2"), tab: try tab())
        try registry.upsert(first)
        try registry.upsert(second)
        let movedFirst = try pane("w1:p2", terminalID: "term-w1:p1")
        let movedSecond = try pane("w1:p1", terminalID: "term-w1:p2")
        try registry.upsert(first.rebound(to: movedFirst, tab: try tab()))
        try registry.upsert(second.rebound(to: movedSecond, tab: try tab()))
        let swapped = try registry.load()
        XCTAssertEqual(swapped.count, 2)
        XCTAssertEqual(swapped.first(where: { $0.name == "saved_agent" })?.terminalID, "term-w1:p1")
        XCTAssertEqual(swapped.first(where: { $0.name == "second_agent" })?.terminalID, "term-w1:p2")
        // Stale pane IDs alone cannot remove a migrated terminal identity.
        try registry.remove(paneIDs: ["w1:p2"], terminalIDs: ["replacement-terminal"])
        XCTAssertEqual(try registry.load().count, 2)
        try registry.remove(paneIDs: ["w1:p1"], terminalIDs: ["term-w1:p2"])
        XCTAssertEqual(try registry.load().map(\.name), ["saved_agent"])
    }

    func testClosingUsesCapturedIdentityAfterLiveSnapshotRemovesPane() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        let live = try pane()
        let saved = intent().rebound(to: live, tab: try tab())
        try registry.upsert(saved)
        var livePanes = [live]
        let removal = ManagedAgentRemoval(paneIDs: [live.paneID], agents: [], panes: livePanes)
        livePanes.removeAll() // A server event arrives before close RPC returns.
        XCTAssertTrue(livePanes.isEmpty)
        try registry.remove(paneIDs: removal.paneIDs, names: removal.names, terminalIDs: removal.terminalIDs)
        XCTAssertTrue(try registry.load().isEmpty)
    }

    func testCapturedCloseDoesNotRemoveSameNameReplacementTerminal() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        let live = try pane(terminalID: "original-terminal")
        let agent = try decode(AgentInfo.self, ["pane_id": live.paneID, "tab_id": "w1:t1",
            "workspace_id": "w1", "terminal_id": "original-terminal", "name": "saved_agent"])
        let removal = ManagedAgentRemoval(paneIDs: [live.paneID], agents: [agent], panes: [live])
        try registry.upsert(intent().rebound(to: live, tab: try tab()))
        let replacement = try pane(terminalID: "replacement-terminal")
        try registry.upsert(intent().rebound(to: replacement, tab: try tab()))
        try registry.remove(paneIDs: removal.paneIDs, names: removal.names, terminalIDs: removal.terminalIDs)
        XCTAssertEqual(try registry.load().first?.terminalID, "replacement-terminal")
    }

    func testCapturedCloseUsesAgentTerminalWhenPaneSnapshotIsMissing() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        try registry.upsert(intent().rebound(to: try pane(), tab: try tab()))
        let agent = try decode(AgentInfo.self, ["pane_id": "w1:p1", "tab_id": "w1:t1",
            "workspace_id": "w1", "terminal_id": "term-w1:p1", "name": "saved_agent"])
        let removal = ManagedAgentRemoval(paneIDs: [agent.paneID], agents: [agent], panes: [])
        try registry.remove(paneIDs: removal.paneIDs, names: removal.names, terminalIDs: removal.terminalIDs)
        XCTAssertTrue(try registry.load().isEmpty)
    }

    func testSavedIdentityAfterReboundSurvivesChangedDirectory() throws {
        let registry = ManagedAgentRegistry(fileURL: try temporaryRegistryURL())
        try registry.upsert(intent().rebound(to: try pane(), tab: try tab()))
        let result = ManagedAgentProjection.resolve(
            agents: [], panes: [try pane(cwd: "/tmp/changed-directory")],
            tabs: [try tab()], intents: try registry.load())
        XCTAssertEqual(result.agents.first?.name, "saved_agent")
        XCTAssertEqual(result.agents.first?.status, .unknown)
    }


    func testAddedAgentReloadsAlongsideExistingIdentityAndExplicitRemovalStaysRemoved() throws {
        let url = try temporaryRegistryURL()
        let first = intent().rebound(to: try pane(), tab: try tab())
        try ManagedAgentRegistry(fileURL: url).upsert(first)
        let addedPane = try pane("w1:p2", tab: "w1:t2")
        let addedTab = try tab("w1:t2", label: "Future Agent")
        let added = ManagedAgentIntent(tabLabel: "Future Agent", cwd: "/tmp/project",
            name: "future_agent", kind: "future-kind", paneID: addedPane.paneID, tabID: addedPane.tabID,
            terminalID: addedPane.terminalID)
        try ManagedAgentRegistry(fileURL: url).upsert(added)
        let reopened = ManagedAgentRegistry(fileURL: url)
        let projection = ManagedAgentProjection.resolve(agents: [], panes: [try pane(), addedPane],
            tabs: [try tab(), addedTab], intents: try reopened.load())
        XCTAssertEqual(Set(projection.agents.compactMap(\.name)), ["saved_agent", "future_agent"])
        XCTAssertTrue(projection.agents.allSatisfy { $0.status == .unknown })
        try reopened.remove(paneIDs: [addedPane.paneID], terminalIDs: [addedPane.terminalID!])
        XCTAssertEqual(try ManagedAgentRegistry(fileURL: url).load().map(\.name), ["saved_agent"])
    }







    func testUnsafePermissionsOversizeAndHardlinkFailClosedWithoutReplacement() throws {
        for variant in ["permissions", "oversize", "hardlink"] {
            let url = try temporaryRegistryURL()
            let registry = ManagedAgentRegistry(fileURL: url)
            try registry.upsert(intent())
            switch variant {
            case "permissions":
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            case "oversize":
                try writePrivate(Data(repeating: 32, count: 65_537), to: url)
            default:
                let alias = url.deletingLastPathComponent().appendingPathComponent("hardlink")
                XCTAssertEqual(Darwin.link(url.path, alias.path), 0)
            }
            let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try registry.load(), variant)
            XCTAssertThrowsError(try registry.upsert(intent()), variant)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }

    func testSymlinkLeafAndAncestorAreRejected() throws {
        let original = try temporaryRegistryURL()
        try ManagedAgentRegistry(fileURL: original).upsert(intent())
        let leaf = original.deletingLastPathComponent().appendingPathComponent("linked.json")
        XCTAssertEqual(Darwin.symlink(original.path, leaf.path), 0)
        XCTAssertThrowsError(try ManagedAgentRegistry(fileURL: leaf).load())
        XCTAssertThrowsError(try ManagedAgentRegistry(fileURL: leaf).upsert(intent()))
        let alias = try temporaryRegistryURL().deletingLastPathComponent().appendingPathComponent("directory-link")
        XCTAssertEqual(Darwin.symlink(original.deletingLastPathComponent().path, alias.path), 0)
        let redirected = alias.appendingPathComponent(original.lastPathComponent)
        XCTAssertThrowsError(try ManagedAgentRegistry(fileURL: redirected).load())
        XCTAssertThrowsError(try ManagedAgentRegistry(fileURL: redirected).upsert(intent()))
    }

    func testNonregularFileDoesNotBlockReaderOrGetReplaced() throws {
        let url = try temporaryRegistryURL()
        XCTAssertEqual(Darwin.mkfifo(url.path, 0o600), 0)
        let registry = ManagedAgentRegistry(fileURL: url)
        XCTAssertThrowsError(try registry.load())
        XCTAssertThrowsError(try registry.upsert(intent()))
    }





    func testExternalChangesDuringSaveAreNotOverwrittenAndTemporaryFilesAreCleaned() throws {
        let url = try temporaryRegistryURL()
        try ManagedAgentRegistry(fileURL: url).upsert(intent())
        let replacement = try JSONSerialization.data(withJSONObject: ["version": 1, "targets": [], "external": true])
        let registry = ManagedAgentRegistry(fileURL: url, beforeCommit: {
            try self.writePrivate(replacement, to: url)
        })
        XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")))
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .contains { $0.hasPrefix(".agent-registry-") })
    }

    func testMissingParentsAreCreatedPrivatelyAndNewFileIsPrivate() throws {
        let base = try temporaryRegistryURL().deletingLastPathComponent()
        let url = base.appendingPathComponent("new/nested/agent-reconcile.json")
        let registry = ManagedAgentRegistry(fileURL: url)
        XCTAssertTrue(try registry.load().isEmpty)
        try registry.upsert(intent())
        for target in [url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()] {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try ManagedAgentRegistry(fileURL: url).load().count, 1)
    }


    func testParentReplacementDuringSaveCannotRedirectPinnedWrite() throws {
        let url = try temporaryRegistryURL()
        try ManagedAgentRegistry(fileURL: url).upsert(intent())
        let parent = url.deletingLastPathComponent()
        let moved = parent.appendingPathExtension("moved")
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        let original = try Data(contentsOf: url)
        let registry = ManagedAgentRegistry(fileURL: url, beforeCommit: {
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        })
        XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(url.lastPathComponent)), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: moved.path)
            .contains { $0.hasPrefix(".agent-registry-") })
    }

    func testFileReplacementBySymlinkDuringSaveFailsWithoutFollowingIt() throws {
        let url = try temporaryRegistryURL()
        try ManagedAgentRegistry(fileURL: url).upsert(intent())
        let other = url.deletingLastPathComponent().appendingPathComponent("external.json")
        let external = Data("external sentinel".utf8)
        try writePrivate(external, to: other)
        let registry = ManagedAgentRegistry(fileURL: url, beforeCommit: {
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(Darwin.symlink(other.path, url.path), 0)
        })
        XCTAssertThrowsError(try registry.upsert(intent(name: "new_agent")))
        XCTAssertEqual(try Data(contentsOf: other), external)
    }

    func testOversizeResultDoesNotReplacePriorRegistry() throws {
        let url = try temporaryRegistryURL()
        let registry = ManagedAgentRegistry(fileURL: url)
        try registry.upsert(intent())
        let original = try Data(contentsOf: url)
        var large = intent()
        large.tabLabel = String(repeating: "x", count: 65_536)
        XCTAssertThrowsError(try registry.upsert(large))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

}
