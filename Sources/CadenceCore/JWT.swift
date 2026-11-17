import Foundation

/// Reads claims from an ID token returned directly by Google's token endpoint over TLS.
/// No signature check: the token never passes through anyone else, it's only used as a display label.
public enum JWT {
    public static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func email(in token: String) -> String? {
        payload(token)?["email"] as? String
    }
}
