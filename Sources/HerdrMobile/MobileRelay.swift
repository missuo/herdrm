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

    static func forget(_ deviceID: UUID) { keychain.remove("psk.\(deviceID.uuidString)") }

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
        let (sshEnd, pumpEnd) = try RelayPump.socketPair()
        let stream = connection.stream
        Task.detached { await RelayPump.run(descriptor: pumpEnd, stream: stream) }
        do {
            let ssh = try await SSHConnection.connect(overDescriptor: sshEnd, timeout: .seconds(15))
            let blob = connection.host.sshHostKey.flatMap { key -> Data? in
                let parts = key.split(separator: " ")
                return parts.count >= 2 ? Data(base64Encoded: String(parts[1])) : nil
            }
            return RelayedSSH(connection: ssh, stream: stream, hostKeyBlob: blob)
        } catch {
            stream.close()
            throw error
        }
    }
}
