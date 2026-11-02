import AVFoundation
import HerdrKit
import SwiftUI
import UIKit

/// Add Device → Pair with Mac: scan the code Herdrm shows on the Mac (or
/// paste its link), and the phone pairs through the relay. No IP address,
/// port forwarding or SSH setup on the phone.
struct RelayPairingSections: View {
    @Bindable var model: MobileAppModel
    /// Pairing a link that arrived from outside (`model.pendingPairingLink`:
    /// the system Camera opened a herdrm:// URL) starts on its own.
    let onPaired: () -> Void

    @State private var scanning = false
    @State private var pasted = ""
    @State private var pairing: RelayPairingLink?
    @State private var error: String?

    var body: some View {
        Section {
            Button {
                error = nil
                scanning = true
            } label: {
                Label(String(localized: "Scan the Mac's QR Code"), systemImage: "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
            }
            .disabled(pairing != nil)
            // On a visible row: an empty view in a Form never appears, and
            // its task would never run.
            .task {
                if let link = model.pendingPairingLink, pairing == nil {
                    model.pendingPairingLink = nil
                    run(link)
                }
            }
            .sheet(isPresented: $scanning) {
                QRScannerSheet { value in
                    scanning = false
                    start(value)
                }
            }
        } footer: {
            Text(String(localized: "On the Mac, open Herdrm → Settings → iPhone and click Pair iPhone. Works on any network: the connection goes through Herdrm's relay, end-to-end encrypted."))
        }

        Section {
            TextField(String(localized: "herdrm://pair?…"), text: $pasted)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 13, design: .monospaced))
            Button(String(localized: "Pair with Link")) { start(pasted) }
                .disabled(RelayPairingLink(string: pasted) == nil || pairing != nil)
        } header: {
            Text(String(localized: "Or Paste the Pairing Link"))
        }

        if let pairing {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(String(localized: "Pairing with \(pairing.hostName)…"))
                }
            }
        }
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }

    private func start(_ text: String) {
        guard let link = RelayPairingLink(string: text) else {
            error = String(localized: "That isn't a Herdrm pairing code.")
            return
        }
        run(link)
    }

    private func run(_ link: RelayPairingLink) {
        error = nil
        pairing = link
        Task {
            do {
                let device = try await MobileRelay.pair(link)
                model.addRelayDevice(device)
                pairing = nil
                onPaired()
            } catch {
                pairing = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// A full-screen camera that reports the first herdrm:// QR code it sees.
struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        NavigationStack {
            ZStack {
                if denied {
                    ContentUnavailableView(
                        String(localized: "Camera Access Is Off"),
                        systemImage: "camera.fill",
                        description: Text(String(localized: "Allow camera access for Herdrm in Settings, or paste the pairing link instead.")))
                } else {
                    QRScannerView(onCode: onCode, onDenied: { denied = true })
                        .ignoresSafeArea()
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 240, height: 240)
                        .accessibilityHidden(true)
                    VStack {
                        Spacer()
                        Text(String(localized: "Point at the code on the Mac"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle(String(localized: "Scan Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onDenied = onDenied
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onDenied: (() -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var reported = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() } else { self.onDenied?() }
                }
            }
        }

        private func configure() {
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input)
            else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !reported,
                  let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                      .first(where: { RelayPairingLink(string: $0) != nil })
            else { return }
            reported = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            session.stopRunning()
            onCode?(value)
        }
    }
}
