import Foundation

/// What the Mac calls a paired phone.
///
/// Since iOS 16 an app only sees the phone's own name ("Pat's iPhone") with a special entitlement
/// from Apple; otherwise `UIDevice.current.name` is just "iPhone". So the phone also sends its
/// hardware model ("iPhone17,1"), and the user can give it a name in the phone's Settings. The Mac
/// shows that name, or the real device name when it gets one, and otherwise the model ("iPhone 16 Pro").
public enum CompanionDeviceName {
    /// The generic names iOS hands out instead of the user's device name.
    static let generic: Set<String> = ["iphone", "ipad", "ipod touch", ""]

    public static func isGeneric(_ name: String) -> Bool {
        generic.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The label for a phone that said hello with `name` and hardware `model` (an identifier like
    /// "iPhone17,1", or nil from older phones).
    public static func label(name: String, model: String?) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isGeneric(trimmed) { return trimmed }
        return model.map(marketingName) ?? (trimmed.isEmpty ? "iPhone" : trimmed)
    }

    /// "iPhone17,1" → "iPhone 16 Pro". Unknown identifiers fall back to the family ("iPhone", "iPad").
    public static func marketingName(_ identifier: String) -> String {
        if let known = models[identifier] { return known }
        if identifier.hasPrefix("iPad") { return "iPad" }
        if identifier.hasPrefix("iPod") { return "iPod touch" }
        if identifier.hasPrefix("iPhone") { return "iPhone" }
        return identifier
    }

    static let models: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
    ]
}
