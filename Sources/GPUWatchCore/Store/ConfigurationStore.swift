import Foundation

/// Something the store wants the operator to know about the files on disk.
public struct StoreIssue: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A file exists but could not be decoded.
        case corrupt
        /// A file was written by a newer schema than this build understands.
        case newerSchema(found: Int, supported: Int)
        /// The file could not be read or written for an OS-level reason.
        case ioFailure
    }

    public var id: String { path + String(describing: kind) }
    public let kind: Kind
    public let path: String
    public let detail: String
    /// Where the unreadable file was preserved, when it was moved aside.
    public let quarantinedTo: String?

    public var message: String {
        switch kind {
        case .corrupt:
            return "Could not read \(lastComponent). \(detail)"
                + (quarantinedTo.map { " The original was kept at \($0)." } ?? " It was left untouched.")
        case let .newerSchema(found, supported):
            return "\(lastComponent) was written by a newer version of GPU Watch (format \(found), this build reads \(supported)). It was left untouched."
        case .ioFailure:
            return "\(lastComponent): \(detail)"
        }
    }

    private var lastComponent: String {
        (path as NSString).lastPathComponent
    }
}

public enum StoreError: Error, LocalizedError, Sendable {
    case directoryUnavailable(String)
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .directoryUnavailable(detail): return "Storage folder unavailable: \(detail)"
        case let .readFailed(detail): return "Could not read the configuration: \(detail)"
        case let .writeFailed(detail): return "Could not save: \(detail)"
        }
    }
}

/// Reads and writes GPU Watch's files under
/// `~/Library/Application Support/GPUWatch/`.
///
/// Two behaviours matter more than the mechanics:
///
/// - Writes are atomic. A crash mid-save leaves the previous file intact rather
///   than a half-written one.
/// - A file we cannot decode is **never** overwritten. It is preserved, either
///   in place or moved to a timestamped sibling, and the failure is reported so
///   the operator decides what happens next. Losing a host list to a bad parse
///   would be a worse outcome than showing an error.
public final class ConfigurationStore: @unchecked Sendable {
    public static let applicationSupportFolderName = "GPUWatch"

    public let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var issues: [StoreIssue] = []

    public var configurationURL: URL { directory.appendingPathComponent("config.json") }
    public var baselineURL: URL { directory.appendingPathComponent("baseline.json") }
    public var lastKnownURL: URL { directory.appendingPathComponent("last-known.json") }

    /// Default location. Overridable so tests get a clean folder.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    public init(
        directory: URL = ConfigurationStore.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    // MARK: - Issues

    public var currentIssues: [StoreIssue] {
        lock.lock()
        defer { lock.unlock() }
        return issues
    }

    public func clearIssues() {
        lock.lock()
        issues = []
        lock.unlock()
    }

    private func record(_ issue: StoreIssue) {
        lock.lock()
        issues.append(issue)
        lock.unlock()
    }

    // MARK: - Directory

    public func ensureDirectory() throws {
        if fileManager.fileExists(atPath: directory.path) {
            // Host names, usernames and key paths live in here. If the folder was
            // created by something else with looser permissions, tighten it.
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            let detail = error.localizedDescription
            record(StoreIssue(kind: .ioFailure, path: directory.path, detail: detail, quarantinedTo: nil))
            throw StoreError.directoryUnavailable(detail)
        }
    }

    // MARK: - Configuration

    /// Loads configuration. A missing file is a fresh install, not an error.
    public func loadConfiguration() -> AppConfiguration {
        load(
            AppConfiguration.self,
            from: configurationURL,
            fallback: AppConfiguration()
        )
    }

    public func saveConfiguration(_ configuration: AppConfiguration) throws {
        try write(configuration, to: configurationURL)
    }

    // MARK: - Baselines

    public func loadBaselines() -> BaselineFile {
        load(BaselineFile.self, from: baselineURL, fallback: BaselineFile())
    }

    public func saveBaselines(_ file: BaselineFile) throws {
        try write(file, to: baselineURL)
    }

    // MARK: - Last known readings

    public func loadLastKnown() -> LastKnownFile {
        load(LastKnownFile.self, from: lastKnownURL, fallback: LastKnownFile())
    }

    public func saveLastKnown(_ file: LastKnownFile) throws {
        try write(file, to: lastKnownURL)
    }

    /// Removes the cached readings. Used when the operator switches to demo mode
    /// or wants a clean slate.
    public func clearLastKnown() {
        try? fileManager.removeItem(at: lastKnownURL)
    }

    // MARK: - Quarantine

    /// Moves an unreadable file aside so a corrected version can be written
    /// without destroying whatever the user had.
    @discardableResult
    public func quarantine(_ url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = (url.lastPathComponent as NSString).pathExtension
        let target = directory
            .appendingPathComponent("\(name).corrupt-\(stamp)")
            .appendingPathExtension(ext)
        try fileManager.moveItem(at: url, to: target)
        return target
    }

    // MARK: - Generic load / write

    private func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        fallback: T
    ) -> T {
        guard fileManager.fileExists(atPath: url.path) else { return fallback }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            record(StoreIssue(
                kind: .ioFailure, path: url.path,
                detail: error.localizedDescription, quarantinedTo: nil
            ))
            return fallback
        }

        // Read the version before the full decode so a future format gets a
        // specific message rather than a generic parse error.
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           probe.schemaVersion > StoreSchema.currentVersion {
            record(StoreIssue(
                kind: .newerSchema(found: probe.schemaVersion, supported: StoreSchema.currentVersion),
                path: url.path,
                detail: "ahead of this build",
                quarantinedTo: nil
            ))
            return fallback
        }

        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            // Preserve the file by moving it aside, then report both paths.
            let quarantined = try? quarantine(url)
            record(StoreIssue(
                kind: .corrupt,
                path: url.path,
                detail: Self.describeDecodingFailure(error),
                quarantinedTo: quarantined?.path
            ))
            return fallback
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try ensureDirectory()
            let data = try Self.encoder.encode(value)
            // `.atomic` writes to a sibling temporary file and renames it into
            // place, so an interrupted save cannot truncate the real file.
            try data.write(to: url, options: [.atomic])
        } catch let error as StoreError {
            throw error
        } catch {
            let detail = error.localizedDescription
            record(StoreIssue(kind: .ioFailure, path: url.path, detail: detail, quarantinedTo: nil))
            throw StoreError.writeFailed(detail)
        }
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    /// Turns a `DecodingError` into something a person can act on.
    static func describeDecodingFailure(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { key -> String in
                if let index = key.intValue { return "[\(index)]" }
                return key.stringValue
            }
            return parts.isEmpty ? "the file root" : parts.joined(separator: ".")
        }
        switch decodingError {
        case let .typeMismatch(_, context):
            return "unexpected value at \(path(context))"
        case let .valueNotFound(_, context):
            return "missing value at \(path(context))"
        case let .keyNotFound(key, context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case let .dataCorrupted(context):
            // The path matters as much here as anywhere: "invalid UUID string"
            // is not actionable until it says which entry it came from.
            let location = context.codingPath.isEmpty ? "" : " at \(path(context))"
            return "\(context.debugDescription)\(location)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
