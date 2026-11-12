#if os(macOS)
import Security
import XCTest
@testable import HerdrKit

/// Against the real login Keychain, with throwaway service names this test
/// creates itself, so the items belong to the test and never prompt.
final class KeychainServiceMigrationTests: XCTestCase {
    private let old = "test.herdrm.migration.old.\(UUID().uuidString)"
    private let new = "test.herdrm.migration.new.\(UUID().uuidString)"

    override func tearDown() {
        for service in [old, new] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        super.tearDown()
    }

    func testEveryItemMovesToTheNewServiceAndTheOldOneIsGone() {
        let oldStore = RelayKeychain(service: old)
        XCTAssertTrue(oldStore.set(Data("one".utf8), for: "a"))
        XCTAssertTrue(oldStore.set(Data("two".utf8), for: "b"))

        XCTAssertTrue(KeychainServiceMigration.move(from: old, to: new))

        let newStore = RelayKeychain(service: new)
        XCTAssertEqual(newStore.data("a"), Data("one".utf8))
        XCTAssertEqual(newStore.data("b"), Data("two".utf8))
        XCTAssertNil(oldStore.data("a"))
        XCTAssertNil(oldStore.data("b"))
    }

    func testAnItemAlreadyUnderTheNewNameKeepsTheNewCopy() {
        XCTAssertTrue(RelayKeychain(service: old).set(Data("stale".utf8), for: "a"))
        XCTAssertTrue(RelayKeychain(service: new).set(Data("current".utf8), for: "a"))

        XCTAssertTrue(KeychainServiceMigration.move(from: old, to: new))

        XCTAssertEqual(RelayKeychain(service: new).data("a"), Data("current".utf8))
        XCTAssertNil(RelayKeychain(service: old).data("a"))
    }

    func testNothingUnderTheOldNameIsDone() {
        XCTAssertTrue(KeychainServiceMigration.move(from: old, to: new))
    }

    func testNoServiceKeepsTheOldBundleID() {
        for rename in KeychainServiceMigration.renames {
            XCTAssertTrue(rename.from.hasPrefix("dev.bybee.herdrm."))
            XCTAssertTrue(rename.to.hasPrefix("sb.moe.herdrm."), rename.to)
            XCTAssertEqual(rename.from.dropFirst("dev.bybee.herdrm.".count), rename.to.dropFirst("sb.moe.herdrm.".count))
        }
        XCTAssertEqual(KeychainServiceMigration.renames.count, 5)
    }
}
#endif
