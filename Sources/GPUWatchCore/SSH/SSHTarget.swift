import Foundation

/// A validated, injection-safe description of where to point `/usr/bin/ssh`.
///
/// The only way to obtain an `SSHTarget` is `make(from:)`, which rejects
/// anything that could be mistaken for an option or that would be interpreted
/// by a shell. Nothing downstream re-derives or re-validates these values, so
/// the arguments handed to `Process` are always literal and already checked.
public struct SSHTarget: Equatable, Sendable {
    public let destination: String
    public let username: String?
    public let port: Int?
    /// Expanded absolute path, or `nil` when the user did not specify one.
    public let identityFile: String?

    /// A field the user typed that we refused to use.
    public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
        public enum Field: String, Sendable {
            case destination = "host"
            case username = "username"
            case port = "port"
            case identityFile = "identity file"
            case displayName = "display name"
        }
        public let field: Field
        public let reason: String

        public var errorDescription: String? {
            "Invalid \(field.rawValue): \(reason)"
        }
    }

    // MARK: - Validation

    /// Characters allowed in a hostname, IP literal, or SSH config alias.
    /// Deliberately conservative: no whitespace, no shell metacharacters, no
    /// control characters, no `@` (the username is a separate field).
    private static let destinationAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
    ).union(CharacterSet(charactersIn: "[]:%"))

    private static let usernameAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    // MARK: - Construction

    /// Validates user input and produces a target safe to hand to `ssh`.
    ///
    /// - Throws: `ValidationError` describing exactly which field was rejected
    ///   and why, so the settings UI can put the message next to the field.
    public static func make(from host: HostConfig) throws -> SSHTarget {
        var rawDestination = host.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        var rawUsername = host.username?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawDestination.isEmpty else {
            throw ValidationError(field: .destination, reason: "cannot be empty")
        }

        // Convenience: accept `user@host` typed into the host field, but only
        // when the username field is empty. The username is peeled off here and
        // validated like any other, so this never widens what reaches ssh.
        if let atIndex = rawDestination.lastIndex(of: "@") {
            let prefix = String(rawDestination[rawDestination.startIndex..<atIndex])
            let suffix = String(rawDestination[rawDestination.index(after: atIndex)...])
            if rawUsername?.isEmpty ?? true {
                rawUsername = prefix
                rawDestination = suffix
                if rawUsername?.isEmpty ?? true {
                    throw ValidationError(field: .destination, reason: "missing username before '@'")
                }
            } else {
                throw ValidationError(
                    field: .destination,
                    reason: "must not contain '@' when a username is set separately"
                )
            }
        }

        let destination = try validateDestination(rawDestination)
        let username = try rawUsername.map { try validateUsername($0) }
        let port = try host.port.map { try validatePort($0) }
        let identityFile = try host.identityFile
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { try validateIdentityFile($0) }

        return SSHTarget(
            destination: destination,
            username: username,
            port: port,
            identityFile: identityFile
        )
    }

    private static func validateDestination(_ value: String) throws -> String {
        // A leading '-' would be parsed by ssh as an option. This is the single
        // most important check in this file.
        guard !value.hasPrefix("-") else {
            throw ValidationError(
                field: .destination,
                reason: "must not start with '-' (it would be read as an ssh option)"
            )
        }
        guard !value.contains("@") else {
            throw ValidationError(field: .destination, reason: "must not contain '@'")
        }
        guard value.rangeOfCharacter(from: destinationAllowed.inverted) == nil else {
            throw ValidationError(
                field: .destination,
                reason: "contains characters that are not valid in a hostname"
            )
        }
        // Reject lone separators and a bare IPv6 bracket pair.
        guard value.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw ValidationError(field: .destination, reason: "must contain a letter or digit")
        }
        return value
    }

    private static func validateUsername(_ value: String) throws -> String {
        guard !value.hasPrefix("-") else {
            throw ValidationError(field: .username, reason: "must not start with '-'")
        }
        guard !value.isEmpty, value.rangeOfCharacter(from: usernameAllowed.inverted) == nil else {
            throw ValidationError(
                field: .username,
                reason: "only letters, digits, '.', '_' and '-' are allowed"
            )
        }
        return value
    }

    private static func validatePort(_ value: Int) throws -> Int {
        guard (1...65535).contains(value) else {
            throw ValidationError(field: .port, reason: "must be between 1 and 65535")
        }
        return value
    }

    private static func validateIdentityFile(_ value: String) throws -> String {
        guard !value.hasPrefix("-") else {
            throw ValidationError(field: .identityFile, reason: "must not start with '-'")
        }
        guard !value.contains("\n"), !value.contains("\0") else {
            throw ValidationError(field: .identityFile, reason: "must be a single-line path")
        }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ValidationError(field: .identityFile, reason: "must be an absolute path")
        }
        return expanded
    }

    // MARK: - Argument construction

    /// The argument vector handed to `/usr/bin/ssh`, excluding the remote
    /// command. Every element is a literal already validated above; no shell is
    /// involved at any point.
    public var baseArguments: [String] {
        var args: [String] = []

        // Non-interactive: never prompt, never allocate a TTY, never wait for a
        // password we cannot type.
        args += ["-o", "BatchMode=yes"]
        args += ["-o", "ConnectTimeout=\(CheckTimeoutBudget.connectTimeoutSeconds)"]
        args += ["-o", "ConnectionAttempts=1"]
        args += ["-o", "NumberOfPasswordPrompts=0"]
        args += ["-T"]

        // Keepalives let us distinguish a hung server from a slow one inside
        // the whole-check budget.
        args += ["-o", "ServerAliveInterval=5"]
        args += ["-o", "ServerAliveCountMax=2"]

        // Host key verification stays on and we never write to known_hosts.
        // An unknown or changed key is reported to the user, never accepted.
        args += ["-o", "StrictHostKeyChecking=yes"]
        args += ["-o", "UpdateHostKeys=no"]
        args += ["-o", "LogLevel=ERROR"]

        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile {
            args += ["-i", identityFile]
            // Only offer the key the user chose, so a wrong agent key cannot
            // exhaust the server's authentication attempt limit first.
            args += ["-o", "IdentitiesOnly=yes"]
        }

        return args
    }

    /// The `user@host` destination, or bare host.
    public var destinationArgument: String {
        guard let username else { return destination }
        return "\(username)@\(destination)"
    }

    /// Full argv for a probe: options, `--`, destination, then the remote
    /// program as a single element.
    ///
    /// `--` belt-and-braces ends option parsing; `validateDestination` already
    /// guarantees the destination cannot look like an option.
    public func probeArguments(remoteCommand: String) -> [String] {
        baseArguments + ["--", destinationArgument, remoteCommand]
    }

    /// Display form for logs and the UI. Never includes key material.
    public var displayTarget: String {
        var text = destinationArgument
        if let port { text += ":\(port)" }
        return text
    }
}
