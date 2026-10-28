import Foundation

/// Encode illegal URL characters before Foundation sees them. Its permissive
/// initializer can otherwise double-encode existing escapes when a raw space
/// appears elsewhere in the same portal query.
public enum PortalRequestURL {
    public static func url(_ raw: String, relativeTo base: URL? = nil) -> URL? {
        var allowed = CharacterSet.urlPathAllowed.union(.urlQueryAllowed).union(.urlFragmentAllowed)
        allowed.insert(charactersIn: "%[]:/?#@!$&'()*+,;=")
        guard let escaped = raw.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: escaped, relativeTo: base)
    }
}
