import HerdrKit
import Testing
@testable import herdrm

@Suite(.serialized) @MainActor
struct DeviceFileBrowserModelTests {
    @Test func loadingDirectoryPreservesPathEditedBeforeItsReply() async throws {
        let requests = HeldDeviceDirectoryRequests()
        let browser = DeviceFileBrowserModel(listDirectory: requests.list)
        browser.pathText = "/test1"
        let loading = Task { await browser.navigate(to: browser.pathText) }
        try await requests.waitForCount(1)

        // The path field remains editable while a remote directory is loading.
        browser.pathText = "/test2/pasted-path"
        requests.finish(0, path: "/test1/resolved")
        await loading.value

        #expect(browser.pathText == "/test2/pasted-path")
        #expect(browser.currentPath == "/test1/resolved")
        #expect(browser.entries.map(\.name) == ["test1.txt"])
        #expect(!browser.isLoading)
    }

    @Test func uneditedPathStillFollowsTheResolvedDirectory() async throws {
        let requests = HeldDeviceDirectoryRequests()
        let browser = DeviceFileBrowserModel(listDirectory: requests.list)
        browser.pathText = "/test1/../test2"
        let loading = Task { await browser.navigate(to: browser.pathText) }
        try await requests.waitForCount(1)

        requests.finish(0, path: "/test2")
        await loading.value

        #expect(browser.pathText == "/test2")
        #expect(browser.currentPath == "/test2")
        #expect(!browser.isLoading)
    }

    @Test func olderReplyCannotReplaceANewerNavigation() async throws {
        let requests = HeldDeviceDirectoryRequests()
        let browser = DeviceFileBrowserModel(listDirectory: requests.list)
        browser.pathText = "/test1"
        let older = Task { await browser.navigate(to: browser.pathText) }
        try await requests.waitForCount(1)

        browser.pathText = "/test2"
        let newer = Task { await browser.navigate(to: browser.pathText) }
        try await requests.waitForCount(2)
        requests.finish(1, path: "/test2/resolved", filename: "test2.txt")
        await newer.value
        requests.finish(0, path: "/test1/resolved")
        await older.value

        #expect(browser.pathText == "/test2/resolved")
        #expect(browser.currentPath == "/test2/resolved")
        #expect(browser.entries.map(\.name) == ["test2.txt"])
        #expect(!browser.isLoading)
    }

    @Test func refreshDoesNotNavigateAnUnsubmittedPath() async throws {
        let requests = HeldDeviceDirectoryRequests()
        let browser = DeviceFileBrowserModel(listDirectory: requests.list)
        let initial = Task { await browser.navigate(to: "/test1") }
        try await requests.waitForCount(1)
        requests.finish(0, path: "/test1")
        await initial.value

        // Transfer completion refreshes the listing, not the unsubmitted draft.
        browser.pathText = "/test2/../test3"
        let refreshing = Task { await browser.refresh() }
        try await requests.waitForCount(2)
        #expect(requests.paths[1] == "/test1")
        requests.finish(1, path: "/test1")
        await refreshing.value

        #expect(browser.pathText == "/test2/../test3")
        #expect(browser.currentPath == "/test1")
        #expect(!browser.isLoading)
    }
}

@MainActor
final class HeldDeviceDirectoryRequests {
    private enum WaitError: Error { case requestDidNotStart }

    private(set) var paths: [String] = []
    private var replies: [CheckedContinuation<DeviceDirectoryListing, Never>?] = []

    func list(_ service: DeviceFileService, _ path: String, _ includesHidden: Bool) async -> DeviceDirectoryListing {
        paths.append(path)
        return await withCheckedContinuation { replies.append($0) }
    }

    func waitForCount(_ count: Int) async throws {
        for _ in 0..<1_000 {
            if replies.count >= count { return }
            await Task.yield()
        }
        // This fixture is shared by Swift Testing and XCTest UI cases.
        throw WaitError.requestDidNotStart
    }

    func finish(_ index: Int, path: String, filename: String = "test1.txt") {
        let reply = replies[index]
        replies[index] = nil
        reply?.resume(returning: DeviceDirectoryListing(path: path, entries: [
            DeviceFileEntry(name: filename, path: "\(path)/\(filename)", kind: .regularFile)
        ]))
    }
}
