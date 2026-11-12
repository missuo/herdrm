import XCTest
@testable import herdrm

final class LegacyDefaultsTests: XCTestCase {
    private let newDomain = "sb.moe.herdrm.tests.legacy-new"
    private let oldDomain = "sb.moe.herdrm.tests.legacy-old"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: newDomain)
        UserDefaults.standard.removePersistentDomain(forName: oldDomain)
        super.tearDown()
    }

    func testCopiesOldSettingsOnceWithoutOverwritingNewOnes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: newDomain))
        UserDefaults.standard.setPersistentDomain(
            ["app.theme": "dark", "devices.selected": "abc", "SUEnableAutomaticChecks": false],
            forName: oldDomain
        )
        defaults.set("light", forKey: "app.theme")

        LegacyDefaults.migrate(defaults, bundleID: newDomain, from: oldDomain)

        XCTAssertEqual(defaults.string(forKey: "app.theme"), "light")
        XCTAssertEqual(defaults.string(forKey: "devices.selected"), "abc")
        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
        XCTAssertTrue(defaults.bool(forKey: LegacyDefaults.migratedKey))

        // Later changes to the old domain are not copied again.
        UserDefaults.standard.setPersistentDomain(["devices.selected": "xyz"], forName: oldDomain)
        LegacyDefaults.migrate(defaults, bundleID: newDomain, from: oldDomain)
        XCTAssertEqual(defaults.string(forKey: "devices.selected"), "abc")
    }

    func testDoesNothingUnderTheOldBundleID() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: newDomain))
        LegacyDefaults.migrate(defaults, bundleID: oldDomain, from: oldDomain)
        XCTAssertFalse(defaults.bool(forKey: LegacyDefaults.migratedKey))
    }
}
