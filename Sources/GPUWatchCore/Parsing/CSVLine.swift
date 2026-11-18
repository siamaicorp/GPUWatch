import Foundation

/// A small RFC 4180-style splitter for one CSV record.
///
/// nvidia-smi quotes a field when it contains a comma, a quote or leading or
/// trailing whitespace, and escapes an embedded quote by doubling it. Splitting
/// on `,` would therefore mangle board names such as `"Tesla V100, 32GB"`, so
/// the quoting has to be honoured properly.
public enum CSVLine {
    public enum Field: Equatable, Sendable {
        /// The value as written, with surrounding quotes removed and doubled
        /// quotes collapsed.
        case value(String)
        /// A field that opened a quote and never closed it, including the
        /// remainder of the record.
        case unterminatedQuote(String)
    }

    /// Splits one record into fields.
    ///
    /// A trailing carriage return is dropped so output from a host that
    /// translated line endings still parses.
    public static func split(_ line: String) -> [Field] {
        var fields: [Field] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]

            if inQuotes {
                if character == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        // Escaped quote inside a quoted field.
                        current.append("\"")
                        index = line.index(after: next)
                        continue
                    }
                    inQuotes = false
                    index = line.index(after: index)
                    continue
                }
                current.append(character)
                index = line.index(after: index)
                continue
            }

            switch character {
            case "\"" where current.isEmpty || current.allSatisfy(\.isWhitespace):
                // nvidia-smi separates fields with ", " and quotes a value only
                // when it needs to, so a quoted field is normally preceded by a
                // space: `, "Tesla V100, 32GB",`. The separator whitespace is
                // not part of the value, so it is dropped here.
                inQuotes = true
                current = ""
            case ",":
                fields.append(.value(current))
                current = ""
            case "\r":
                break
            default:
                current.append(character)
            }
            index = line.index(after: index)
        }

        if inQuotes {
            fields.append(.unterminatedQuote(current))
        } else {
            fields.append(.value(current))
        }
        return fields
    }

    /// Convenience for callers that only care about well-formed records.
    /// Returns `nil` if any field had an unterminated quote.
    public static func values(_ line: String) -> [String]? {
        var result: [String] = []
        for field in split(line) {
            switch field {
            case let .value(text): result.append(text)
            case .unterminatedQuote: return nil
            }
        }
        return result
    }
}
