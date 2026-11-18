import Foundation

/// Decoding rules for individual `nvidia-smi` field values.
///
/// The governing principle: "the driver did not tell us" is `nil`. It is never
/// zero, false, or healthy. Zero utilisation and zero bytes of VRAM are real
/// measurements that must remain distinguishable from silence.
public enum GPUFieldValue {
    /// Spellings the driver uses when it cannot answer.
    ///
    /// The nvidia-smi documentation states unsupported data is reported as
    /// `N/A`; some versions and some fields additionally use bracket forms such
    /// as `[Not Supported]` or `[Unknown Error]`. Empty strings appear when a
    /// field is blank in the output.
    private static let unsupportedTokens: Set<String> = [
        "n/a",
        "na",
        "not supported",
        "unknown",
        "unknown error",
        "insufficient permissions",
        "err!"
    ]

    /// Unwraps bracketed forms, trims whitespace and surrounding quotes, and
    /// reports whether what is left is a real value.
    public static func normalized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // Values can arrive already de-quoted by CSVLine; guard both ways.
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
        }

        if unsupportedTokens.contains(text.lowercased()) { return nil }
        // Any remaining bracketed marker is treated as unsupported rather than
        // guessed at.
        if text.hasPrefix("[") || text.hasSuffix("]") { return nil }
        return text
    }

    public static func string(_ raw: String) -> String? {
        normalized(raw)
    }

    public static func integer(_ raw: String) -> Int? {
        guard let text = normalized(raw) else { return nil }
        // Int( ) rejects "3.0", which nvidia-smi does emit for some fields.
        if let value = Int(text) { return value }
        if let value = Double(text), value.rounded() == value { return Int(value) }
        return nil
    }

    public static func double(_ raw: String) -> Double? {
        guard let text = normalized(raw) else { return nil }
        return Double(text)
    }
}
