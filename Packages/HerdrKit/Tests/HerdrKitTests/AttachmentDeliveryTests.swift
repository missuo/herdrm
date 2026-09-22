import XCTest
@testable import HerdrKit

/// The delivery matrix for pasted attachments. The local image rows guard the
/// "Claude default" flow: anything that is an image — raw clipboard data or a
/// copied image file — forwards Ctrl+V so the agent reads the clipboard and
/// shows [Image #1], instead of pasting a quoted path (regressed in 0.3.9).
final class AttachmentDeliveryTests: XCTestCase {
    private let claude = AgentAttachmentCapabilities(
        nativeClipboardImageData: true,
        imagePath: .shellQuoted,
        filePath: .shellQuoted
    )
    private let pathOnly = AgentAttachmentCapabilities(
        nativeClipboardImageData: false,
        imagePath: .shellQuoted,
        filePath: .shellQuoted
    )
    private let ssh = Device.Kind.ssh(target: "user@host")

    func testLocalImageDataForwardsClipboard() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: claude, deviceKind: .local, source: .imageData
            ),
            .nativeClipboard
        )
    }

    func testLocalImageFilesForwardClipboard() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: claude, deviceKind: .local, source: .files(allImages: true)
            ),
            .nativeClipboard
        )
    }

    func testLocalNonImageFilesPastePaths() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: claude, deviceKind: .local, source: .files(allImages: false)
            ),
            .devicePaths(.shellQuoted)
        )
    }

    func testLocalImageFilesPastePathsWithoutNativeClipboard() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: pathOnly, deviceKind: .local, source: .files(allImages: true)
            ),
            .devicePaths(.shellQuoted)
        )
    }

    func testRemoteImageDataUploadsAndPastesPaths() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: claude, deviceKind: ssh, source: .imageData
            ),
            .devicePaths(.shellQuoted)
        )
    }

    func testRemoteImageFilesUploadAndPastePaths() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: claude, deviceKind: ssh, source: .files(allImages: true)
            ),
            .devicePaths(.shellQuoted)
        )
    }

    func testUnknownAgentIsUnsupported() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: nil, deviceKind: .local, source: .imageData
            ),
            .unsupported
        )
    }
}

/// Files dropped onto the terminal are never on the agent's clipboard, so a
/// drop always resolves to paths (cmux-style), even for a local Claude that
/// would take a pasted image through Ctrl+V.
final class AttachmentDropDeliveryTests: XCTestCase {
    private let claude = AgentAttachmentCapabilities(
        nativeClipboardImageData: true,
        imagePath: .shellQuoted,
        filePath: .shellQuoted
    )
    func testLocalImageDropPastesPathsNotClipboard() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.dropAction(
                capabilities: claude, allImages: true
            ),
            .shellQuoted
        )
    }

    func testRemoteDropUsesAgentPathSyntax() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.dropAction(
                capabilities: claude, allImages: false
            ),
            .shellQuoted
        )
    }

    func testDropWithoutAgentCapabilitiesStillInsertsShellQuotedPaths() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.dropAction(
                capabilities: nil, allImages: false
            ),
            .shellQuoted
        )
    }

    func testImageDropPrefersImagePathSyntax() {
        let capabilities = AgentAttachmentCapabilities(
            nativeClipboardImageData: false,
            imagePath: .shellQuoted,
            filePath: nil
        )
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.dropAction(
                capabilities: capabilities, allImages: true
            ),
            .shellQuoted
        )
    }
}
