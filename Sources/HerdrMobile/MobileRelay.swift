import CryptoKit
import Foundation
import HerdrKit
import HerdrSSH
import UIKit

/// The phone's side of Herdrm's relay: pairing from a Mac's QR code, and
/// opening SSH to a paired Mac through an end-to-end encrypted session.
///
/// Secrets stay in this device's Keychain: the phone's relay key (one for all
/// Macs) and each Mac's PSK. The device list only holds what is public.
enum MobileRelay {
    private static let keychain = RelayKeychain(service: "dev.bybee.herdrm.ios.relay")

    static var phoneKey: Curve25519.KeyAgreement.PrivateKey { keychain.agreementKey("phone.noise") }

    static func psk(for deviceID: UUID) -> Data? { keychain.data("psk.\(deviceID.uuidString)") }

    static func forget(_ deviceID: UUID) {
        keychain.remove("psk.\(deviceID.uuidString)")
        UserDefaults.standard.removeObject(forKey: directKey(deviceID))
        UserDefaults.standard.removeObject(forKey: hostKeyKey(deviceID))
    }

    // What the Mac last reported over the encrypted channel: its direct
    // address (if the user set one) and its SSH host key.
    private static func directKey(_ id: UUID) -> String { "relay.direct.\(id.uuidString)" }
    private static func hostKeyKey(_ id: UUID) -> String { "relay.sshHostKey.\(id.uuidString)" }

    private static func remember(_ host: RelayMessage.HostInfo, for id: UUID) {
        UserDefaults.standard.set(host.direct, forKey: directKey(id))
        if let blob = hostKeyBlob(host.sshHostKey) {
            UserDefaults.standard.set(blob, forKey: hostKeyKey(id))
        }
    }

    private static func hostKeyBlob(_ line: String?) -> Data? {
        guard let parts = line?.split(separator: " "), parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    /// The Mac's public address, as `SSHEndpoint`, when it has one.
    static func directEndpoint(for id: UUID) -> SSHEndpoint? {
        guard let text = UserDefaults.standard.string(forKey: directKey(id)), !text.isEmpty else { return nil }
        if let colon = text.lastIndex(of: ":"), !text.hasPrefix("["), text.filter({ $0 == ":" }).count == 1,
           let port = UInt16(text[text.index(after: colon)...]) {
            return SSHEndpoint(host: String(text[..<colon]), port: port)
        }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? 22 : 22
            return SSHEndpoint(host: host, port: port)
        }
        return SSHEndpoint(host: text, port: 22)
    }

    static func expectedHostKey(for id: UUID) -> Data? { UserDefaults.standard.data(forKey: hostKeyKey(id)) }

    /// Direct SSH to a paired Mac's public address, accepted only when sshd
    /// presents the host key the Mac vouched for over the relay. Nil when
    /// there is no address, it doesn't answer quickly, or the key differs:
    /// then the relay carries the session.
    static func openDirect(device: MobileDevice) async -> SSHConnection? {
        guard let endpoint = directEndpoint(for: device.id),
              let expected = expectedHostKey(for: device.id),
              let connection = try? await SSHConnection.connect(to: endpoint, timeout: .seconds(4))
        else { return nil }
        guard connection.hostKey.key == expected else {
            try? await connection.close(timeout: .seconds(1))
            return nil
        }
        return connection
    }

    /// What the phone introduces itself with: its name and the SSH key the
    /// Mac installs for it.
    static var hello: RelayMessage.Hello {
        RelayMessage.Hello(
            name: UIDevice.current.name,
            sshKey: DeviceKey.authorizedKeysLine(DeviceKey.ensure(), comment: "herdrm-ios"))
    }

    /// Pairs with the Mac behind `link` (the first session proves the code and
    /// installs this phone's SSH key there) and returns the new device.
    static func pair(_ link: RelayPairingLink) async throws -> MobileDevice {
        let connection = try await RelayClient.connect(
            relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
            psk: link.psk, phoneKey: phoneKey, hello: hello, pairing: true)
        connection.stream.close()
        let device = MobileDevice(
            kind: .relay,
            name: connection.host.name.isEmpty ? link.hostName : connection.host.name,
            host: link.hostID,
            port: 22,
            username: connection.host.user.isEmpty ? link.userName : connection.host.user,
            authMethod: .deviceKey,
            relay: .init(url: link.relay, hostID: link.hostID, hostStatic: link.hostStatic))
        guard keychain.set(link.psk, for: "psk.\(device.id.uuidString)") else {
            throw RelayError.refused(String(localized: "Couldn't save the pairing in the Keychain."))
        }
        remember(connection.host, for: device.id)
        return device
    }

    struct RelayedSSH {
        let connection: SSHConnection
        let stream: RelayStream
        /// The SSH host key blob the Mac reported, to check against sshd's.
        let hostKeyBlob: Data?
    }

    /// An SSH connection to a paired Mac's own sshd, carried by a relay
    /// session: libssh2 gets one end of a socketpair, the session pumps the
    /// other.
    static func openSSH(device: MobileDevice) async throws -> RelayedSSH {
        guard let relay = device.relay, let psk = psk(for: device.id) else {
            throw RelayError.refused(String(localized: "This Mac's pairing is missing. Remove it and scan the Mac's code again."))
        }
        let connection = try await RelayClient.connect(
            relay: relay.url, hostID: relay.hostID, hostStatic: relay.hostStatic,
            psk: psk, phoneKey: phoneKey, hello: hello)
        remember(connection.host, for: device.id)
        let (sshEnd, pumpEnd) = try RelayPump.socketPair()
        let stream = connection.stream
        Task.detached { await RelayPump.run(descriptor: pumpEnd, stream: stream) }
        do {
            let ssh = try await SSHConnection.connect(overDescriptor: sshEnd, timeout: .seconds(15))
            return RelayedSSH(connection: ssh, stream: stream, hostKeyBlob: hostKeyBlob(connection.host.sshHostKey))
        } catch {
            stream.close()
            throw error
        }
    }
}
