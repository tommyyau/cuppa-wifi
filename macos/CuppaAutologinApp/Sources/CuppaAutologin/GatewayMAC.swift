import Foundation

/// Classifies gateway MAC addresses that are NOT unique to one venue.
///
/// Router redundancy protocols hand out a shared *virtual* gateway MAC from a
/// reserved pool, so unrelated venues running the same Cisco/standard gear
/// can present the identical gateway MAC, such as a shared HSRPv2 group address.
///
/// Anything keyed by the gateway MAC as if it were a venue fingerprint — the
/// cached network name, capture folders, "unsupported portal" verdicts — must
/// treat these as non-identifying to avoid leaking one venue's label or state
/// onto another. (Locally administered MACs are deliberately NOT included: a
/// venue's gateway can carry a stable LAA MAC that legitimately identifies
/// it, whereas the virtual-router ranges below never do.)
enum GatewayMAC {
    /// Six MAC octets, or nil if the string isn't a parseable MAC.
    static func octets(_ mac: String?) -> [Int]? {
        guard let mac else { return nil }
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard part.count == 2, let value = Int(part, radix: 16) else {
                return nil
            }
            values.append(value)
        }
        return values
    }

    static func isShared(_ mac: String?) -> Bool {
        guard let octets = octets(mac) else { return false }
        let (o0, o1, o2, o3, o4) = (
            octets[0], octets[1], octets[2], octets[3], octets[4]
        )

        // Cisco HSRP v1 virtual MAC: 00:00:0c:07:ac:XX
        if o0 == 0x00, o1 == 0x00, o2 == 0x0c, o3 == 0x07, o4 == 0xac {
            return true
        }
        // Cisco HSRP v2 virtual MAC: 00:00:0c:9f:fX:XX (0000.0c9f.fXXX)
        if o0 == 0x00, o1 == 0x00, o2 == 0x0c, o3 == 0x9f, (o4 & 0xf0) == 0xf0 {
            return true
        }
        // Cisco GLBP virtual MAC: 00:07:b4:XX:XX:XX
        if o0 == 0x00, o1 == 0x07, o2 == 0xb4 {
            return true
        }
        // VRRP virtual MAC: 00:00:5e:00:01:XX
        if o0 == 0x00, o1 == 0x00, o2 == 0x5e, o3 == 0x00, o4 == 0x01 {
            return true
        }
        return false
    }
}
