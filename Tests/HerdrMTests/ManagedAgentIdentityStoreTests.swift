import Foundation
import HerdrKit
import XCTest
@testable import herdrm

final class ManagedAgentIdentityStoreTests: XCTestCase {
    private func registryURL() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("herdrm-identity-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("registry.json")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func pane(_ id: String, terminal: String, cwd: String = "/tmp/project") throws -> PaneInfo {
        try decode(PaneInfo.self, ["pane_id": id, "terminal_id": terminal, "tab_id": "w1:t1", "workspace_id": "w1", "cwd": cwd])
    }

    private func tab() throws -> TabInfo {
        try decode(TabInfo.self, ["tab_id": "w1:t1", "workspace_id": "w1", "label": "Project"])
    }

    @MainActor
    func testAdoptsRuntimeThenReloadsIdentityWithoutInventingRuntime() throws {
        let url = try registryURL()
        let agent = try decode(AgentInfo.self, ["pane_id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1",
                                              "terminal_id": "term1", "name": "future", "agent": "future-kind", "agent_status": "working"])
        let livePane = try pane("w1:p1", terminal: "term1")
        let store = ManagedAgentIdentityStore(registry: ManagedAgentRegistry(fileURL: url))
        let live = try store.synchronize(agents: [agent], panes: [livePane], tabs: [tab()])
        XCTAssertEqual(live.agents, [agent])
        XCTAssertEqual(store.intents.count, 1)
        let reopened = ManagedAgentIdentityStore(registry: ManagedAgentRegistry(fileURL: url))
        let saved = try reopened.synchronize(agents: [], panes: [livePane], tabs: [tab()])
        XCTAssertEqual(saved.agents.first?.status, .unknown)
        XCTAssertNil(saved.agents.first?.agentKindRaw)
        XCTAssertEqual(saved.kindsByPane["w1:p1"], "future-kind")
    }

    @MainActor
    func testRebindAddAndRemoveAcrossStoreRecreation() throws {
        let url = try registryURL()
        let registry = ManagedAgentRegistry(fileURL: url)
        let store = ManagedAgentIdentityStore(registry: registry)
        try store.remember(ManagedAgentIntent(tabLabel: "Project", cwd: "/tmp/project", name: "first", kind: "future-kind",
                                             paneID: "old:p1", tabID: "w1:t1", terminalID: "term1"))
        let moved = try pane("w1:p2", terminal: "term1", cwd: "/tmp/moved")
        _ = try store.synchronize(agents: [], panes: [moved], tabs: [tab()])
        XCTAssertEqual(try registry.load().first?.paneID, "w1:p2")
        XCTAssertEqual(try registry.load().first?.cwd, "/tmp/moved")
        try store.remember(ManagedAgentIntent(tabLabel: "Project", cwd: nil, name: "second", kind: "another-future-kind",
                                             paneID: "w1:p3", tabID: "w1:t1", terminalID: "term2"))
        let second = try pane("w1:p3", terminal: "term2")
        let reopened = ManagedAgentIdentityStore(registry: registry)
        let both = try reopened.synchronize(agents: [], panes: [moved, second], tabs: [tab()])
        XCTAssertEqual(both.agents.count, 2)
        try reopened.remove(ManagedAgentRemoval(paneIDs: ["w1:p2"], agents: both.agents, panes: [moved, second]))
        let afterRemoval = ManagedAgentIdentityStore(registry: registry)
        let remaining = try afterRemoval.synchronize(agents: [], panes: [second], tabs: [tab()])
        XCTAssertEqual(remaining.agents.map(\.name), ["second"])
    }

    @MainActor
    func testUnknownExtensionFieldsRemainUntouchedIncludingMalformedCredential() throws {
        let url = try registryURL()
        let fields: [String: Any] = ["version": 1, "extension": "keep", "targets": [[
            "name": "future", "kind": "future-kind", "pane_id": "old:p1", "terminal_id": "term1",
            "credential": "opaque-extension-data", "auto_recover": true, "args": ["--custom"], "timeout_ms": 45678,
            "profile_id": "custom-policy", "auto_start": true
        ]]]
        try JSONSerialization.data(withJSONObject: fields).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = ManagedAgentIdentityStore(registry: ManagedAgentRegistry(fileURL: url))
        _ = try store.synchronize(agents: [], panes: [pane("w1:p2", terminal: "term1")], tabs: [tab()])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let row = try XCTUnwrap((root["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(root["extension"] as? String, "keep")
        XCTAssertEqual(row["credential"] as? String, "opaque-extension-data")
        XCTAssertEqual(row["args"] as? [String], ["--custom"])
        XCTAssertEqual(row["timeout_ms"] as? Int, 45678)
        XCTAssertEqual(row["profile_id"] as? String, "custom-policy")
        XCTAssertEqual(row["auto_recover"] as? Bool, true)
        XCTAssertEqual(row["auto_start"] as? Bool, true)
    }
}
