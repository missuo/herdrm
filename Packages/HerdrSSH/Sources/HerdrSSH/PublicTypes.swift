import Foundation

public struct SSHEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 22) {
        self.host = host
        self.port = port
    }
}

public struct SSHHostKey: Sendable, Equatable {
    public let algorithm: String
    public let key: Data

    public init(algorithm: String, key: Data) {
        self.algorithm = algorithm
        self.key = key
    }
}

public struct SSHExecResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitStatus: Int32
    public let reachedEOF: Bool

    public init(stdout: Data, stderr: Data, exitStatus: Int32, reachedEOF: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.reachedEOF = reachedEOF
    }
}

/// Synchronously signs the SSH authentication challenge supplied by libssh2.
/// The private key remains owned by the caller; the package receives only the
/// resulting signature bytes.
public typealias SSHSigningClosure = @Sendable (Data) throws -> Data

public enum SSHError: Error, Sendable, Equatable {
    case invalidEndpoint
    case connectionFailed
    case algorithmNegotiationFailed
    case authenticationFailed
    /// The private key couldn't be read: wrong passphrase, or a format this
    /// build doesn't understand. The connection stays usable.
    case privateKeyUnreadable
    case timedOut
    case cancelled
    case channelFailed
    case forwardingDenied
    case targetUnreachable
    case streamLocalOpenFailed
    case unexpectedEOF
    case responseTooLarge(limit: Int)
    case sftpUnavailable
    case sftpFailure(status: UInt64)
    case connectionInvalidated
}

public struct SSHSFTPAttributes: Sendable, Equatable {
    public let size: UInt64?
    public let permissions: UInt32?
}
