import CuppaCore
import CuppaEngine
import Foundation
import XCTest

/// Exact Persona, path and private-log contracts from the frozen v1 cases.
final class CoreMigrationParityTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-core-" + UUID().uuidString)
        try PrivateFile.directory(root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private let required = """
        FAKE_FIRST_NAME=Alex
        FAKE_LAST_NAME=Morgan
        FAKE_EMAIL=wal7x9k2@example.com
        FAKE_DOB=1988-03-14
        FAKE_POSTCODE=SW1A 1AA
        FAKE_PHONE=07700900123
        SIGNUP_PASSWORD=s3cr3t
        """
    private func load(_ text: String) throws -> PortalIdentity {
        let url = root.appendingPathComponent("persona.env")
        try PrivateFile.write(Data(text.utf8), to: url)
        return try PortalIdentity.load(from: url)
    }
    func testQuotesCommentsAndWhitespaceAreData() throws {
        let identity = try PortalIdentity.parse(
            "# comment\n\nFAKE_FIRST_NAME=Alex\nFAKE_LAST_NAME=\"Morgan\"\nFAKE_POSTCODE='SW1A 1AA'\n  # indented\nFAKE_PHONE=07700900123  \n"
        )
        XCTAssertEqual(identity.firstName, "Alex")
        XCTAssertEqual(identity.lastName, "Morgan")
        XCTAssertEqual(identity.postcode, "SW1A 1AA")
        XCTAssertEqual(identity.phone, "07700900123")
    }
    func testMalformedLineErrorDoesNotExposeItsValue() {
        XCTAssertThrowsError(try PortalIdentity.parse("private-password-without-equals\n")) {
            error in
            XCTAssertTrue(error.localizedDescription.contains("line 1"))
            XCTAssertFalse(error.localizedDescription.contains("private-password"))
        }
    }
    func testMissingFileHasActionableError() {
        XCTAssertThrowsError(try PortalIdentity.load(from: root.appendingPathComponent("missing")))
        {
            XCTAssertTrue($0.localizedDescription.contains("not found"))
        }
    }
    func testMissingRequiredPersonaValueRejected() throws {
        XCTAssertThrowsError(try load("FAKE_FIRST_NAME=Alex\n"))
        for key in [
            "FAKE_FIRST_NAME", "FAKE_LAST_NAME", "FAKE_EMAIL", "FAKE_DOB", "FAKE_POSTCODE",
            "FAKE_PHONE", "SIGNUP_PASSWORD",
        ] {
            let text = required.components(separatedBy: .newlines).filter {
                !$0.hasPrefix(key + "=")
            }.joined(separator: "\n")
            XCTAssertThrowsError(try load(text), key)
        }
    }
    func testFullPersonaAndExplicitFlags() throws {
        let optional = [
            "FAKE_TITLE": "Dr", "FAKE_ADDRESS_LINE_1": "2 Example Street",
            "FAKE_ADDRESS_LINE_2": "Flat 1", "FAKE_CITY": "York", "FAKE_COUNTY": "Yorkshire",
            "FAKE_COUNTRY": "United Kingdom", "FAKE_GENDER": "Prefer not to say",
            "FAKE_COMPANY": "Independent", "FAKE_OCCUPATION": "Other",
            "FAKE_REASON_FOR_VISIT": "Guest Wi-Fi access",
        ]
        let identity = try load(
            required + "\n" + optional.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                + "\nMARKETING_OPT_IN=true\nENABLE_REASSOC_FALLBACK=false\nIGNORE_HOTSPOTS=false")
        XCTAssertEqual(identity.fullName, "Alex Morgan")
        XCTAssertEqual(identity.email, "wal7x9k2@example.com")
        for (key, value) in optional { XCTAssertEqual(identity[key], value, key) }
        XCTAssertTrue(identity.boolean("MARKETING_OPT_IN", default: false))
        XCTAssertFalse(identity.enableReassociation)
        XCTAssertFalse(identity.ignoreHotspots)
    }
    func testAbsentOptionalPersonaUsesLegacyDefaults() throws {
        let identity = try load(required)
        XCTAssertFalse(identity.boolean("MARKETING_OPT_IN", default: false))
        XCTAssertFalse(identity.enableReassociation)
        XCTAssertTrue(identity.ignoreHotspots)
        let defaults = [
            "FAKE_TITLE": "Mx", "FAKE_ADDRESS_LINE_1": "1 Example Street",
            "FAKE_ADDRESS_LINE_2": "", "FAKE_CITY": "London", "FAKE_COUNTY": "Greater London",
            "FAKE_COUNTRY": "United Kingdom", "FAKE_GENDER": "Prefer not to say",
            "FAKE_COMPANY": "Independent", "FAKE_OCCUPATION": "Other",
            "FAKE_REASON_FOR_VISIT": "Guest Wi-Fi access",
        ]
        for (key, value) in defaults { XCTAssertEqual(identity[key], value, key) }
    }
    func testEnvironmentOverrideWinsOverHome() {
        let override = root.appendingPathComponent("override")
        XCTAssertEqual(
            EnginePaths(home: root, environment: ["WIFI_AUTOLOGIN_DATA_DIR": override.path]).root,
            override)
    }
    func testOverrideExpandsTilde() {
        XCTAssertEqual(
            EnginePaths(environment: ["WIFI_AUTOLOGIN_DATA_DIR": "~/cuppa-parity"]).root,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("cuppa-parity"))
    }
    func testEmptyOverrideUsesSharedDirectory() {
        XCTAssertEqual(
            EnginePaths(home: root, environment: ["WIFI_AUTOLOGIN_DATA_DIR": ""]).root,
            root.appendingPathComponent(".local/state/wifi-autologin"))
    }
    func testDefaultIsSharedHomeDirectory() {
        XCTAssertEqual(
            EnginePaths(home: root, environment: [:]).root,
            root.appendingPathComponent(".local/state/wifi-autologin"))
    }
    func testPathResolutionDoesNotCreateDirectories() {
        let home = root.appendingPathComponent("absent-home")
        _ = EnginePaths(home: home, environment: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }
    func testProductionDefaultsReadProcessEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        let expected = EnginePaths(
            home: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
        XCTAssertEqual(EnginePaths().root, expected.root)
        XCTAssertEqual(EnginePaths().log, expected.log)
    }
    private var source: URL { root.appendingPathComponent("legacy/config/identity.env") }
    private var target: URL { root.appendingPathComponent("shared/config/identity.env") }
    private func seedLegacy() throws { try PrivateFile.write(Data(required.utf8), to: source) }
    func testMigrationCopiesExactBytesWhenTargetMissing() throws {
        try seedLegacy()
        XCTAssertTrue(try IdentityMigration.copyIfNeeded(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data(required.utf8))
    }
    func testMigrationPreservesOriginal() throws {
        try seedLegacy()
        try IdentityMigration.copyIfNeeded(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: source), Data(required.utf8))
    }
    func testMigrationCreatesPrivateCopyAndDirectory() throws {
        try seedLegacy()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        try IdentityMigration.copyIfNeeded(from: source, to: target)
        XCTAssertEqual(try mode(target), 0o600)
        XCTAssertEqual(try mode(target.deletingLastPathComponent()), 0o700)
    }
    func testMissingLegacyIdentityIsNoOp() throws {
        XCTAssertFalse(try IdentityMigration.copyIfNeeded(from: source, to: target))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    }
    func testMigrationNeverReplacesSavedPersona() throws {
        try seedLegacy()
        let saved = Data("FAKE_FIRST_NAME=AlreadyShared\n".utf8)
        try PrivateFile.write(saved, to: target)
        XCTAssertFalse(try IdentityMigration.copyIfNeeded(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: target), saved)
    }
    func testMigrationSamePathIsNoOp() throws {
        try seedLegacy()
        XCTAssertFalse(try IdentityMigration.copyIfNeeded(from: source, to: source))
        XCTAssertEqual(try Data(contentsOf: source), Data(required.utf8))
    }
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber)
            .intValue
    }
    func testLogPrivateWhenCreatedReopenedAndRotated() throws {
        let paths = EnginePaths(root: root, log: root.appendingPathComponent("logs/test.log"))
        let evidence = EvidenceStore(paths: paths)
        evidence.log("first private message")
        XCTAssertEqual(try mode(paths.log), 0o600)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: paths.log.path)
        evidence.log(String(repeating: "padding ", count: 130000))
        XCTAssertEqual(try mode(paths.log), 0o600)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: paths.log.path)
        evidence.log("after rotation")
        let backup = URL(fileURLWithPath: paths.log.path + ".1")
        XCTAssertEqual(try mode(paths.log), 0o600)
        XCTAssertEqual(try mode(backup), 0o600)
        XCTAssertTrue(try String(contentsOf: backup).contains("first private message"))
        XCTAssertTrue(try String(contentsOf: paths.log).contains("after rotation"))
    }
}
