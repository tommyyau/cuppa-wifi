import Foundation
import CuppaCore

@main
enum IdentityStoreRegression {
    static func main() throws {
        precondition(ProcessInfo.processInfo.environment["WIFI_AUTOLOGIN_DATA_DIR"] != nil)
        var identity = FakeIdentity.sarahChen
        identity.firstName = "  D'Arcy = \"guest\"  "
        identity.password = "\"'literal=$HOME $(nothing) \\ secret'\""
        identity.addressLine2 = "  Flat #2  "
        try IdentityStore.save(identity)
        precondition(IdentityStore.load() == identity)

        // Exercise replacement of an older, overly permissive file as well as
        // first creation. Both runtimes must read the same literal values.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: IdentityStore.file.path)
        identity.company = "=Company= "
        try IdentityStore.save(identity)
        precondition(IdentityStore.load() == identity)
        let attributes = try FileManager.default.attributesOfItem(atPath: IdentityStore.file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directory = IdentityStore.file.deletingLastPathComponent()
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        precondition((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let actual = try PortalIdentity.load(from: IdentityStore.file)
        precondition(actual.firstName == identity.firstName)
        precondition(actual.password == identity.password)
        precondition(actual["FAKE_ADDRESS_LINE_2"] == identity.addressLine2)
        precondition(actual["FAKE_COMPANY"] == identity.company)

        let saved = try Data(contentsOf: IdentityStore.file)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var missing = identity
        missing.email = "  "
        do {
            try IdentityStore.save(missing)
            preconditionFailure("A Persona missing required details was saved")
        } catch IdentityStore.SaveError.requiredField(let label) {
            precondition(label == "Email")
        }
        for separator in ["\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{001C}", "\u{001D}", "\u{001E}", "\u{0085}", "\u{2028}", "\u{2029}", "\0"] {
            var invalid = identity
            invalid.password = "unchanged" + separator + "FAKE_EMAIL=injected@example.test"
            do {
                try IdentityStore.save(invalid)
                preconditionFailure("A multiline Persona was saved")
            } catch IdentityStore.SaveError.controlCharacter {}
            let remainingData = try Data(contentsOf: IdentityStore.file)
            let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            precondition(remainingData == saved && remainingFiles == files)
        }
        print("Identity persistence regression passed (UI/native-engine round trip, rejection, private replacement)")
    }
}
