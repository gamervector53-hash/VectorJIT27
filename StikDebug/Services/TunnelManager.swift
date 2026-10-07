//
//  TunnelManager.swift
//  StikDebug
//

import Foundation

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false

    private var isStarting = false

    private init() {}

    func markDisconnected() {
        JITEnableContext.shared.invalidateTunnel()
        runOnMain {
            self.isConnected = false
        }
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        guard !isStarting else {
            return
        }

        isStarting = true

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result = self.connectWithRetry()

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func connectWithRetry() -> Result<Void, NSError> {
        let maximumAttempts = 3
        var finalError = NSError(
            domain: "StikDebug",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Tunnel connection failed."]
        )

        for attempt in 1...maximumAttempts {
            do {
                try JITEnableContext.shared.startTunnel()
                return .success(())
            } catch {
                finalError = error as NSError
                guard attempt < maximumAttempts, isRetryableTunnelError(finalError) else {
                    break
                }

                let delay = TimeInterval(attempt)
                LogManager.shared.addWarningLog(
                    "Tunnel attempt \(attempt) failed; retrying in \(Int(delay))s: \(finalError.localizedDescription)"
                )
                JITEnableContext.shared.invalidateTunnel()
                Thread.sleep(forTimeInterval: delay)
            }
        }

        return .failure(finalError)
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false

        switch result {
        case .success:
            isConnected = true
            LogManager.shared.addInfoLog("Tunnel connected successfully")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        guard DeveloperDiskImageService.filesAreReady else { return }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: "Connection Error",
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("Pairing file reported invalid; keeping existing file")

        showAlert(
            title: "Invalid Pairing File",
            message: "The pairing file may be invalid or expired. You can import a new pairing file to replace it.",
            showOk: true,
            showTryAgain: false,
            primaryButtonText: "Select New File"
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = "\(DeviceConnectionContext.targetIPAddress):49152"
    return "Tunnel connection failed for \(target): \(error.localizedDescription) (Domain: \(error.domain), Code: \(error.code), Raw: \(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    let targetIP = DeviceConnectionContext.targetIPAddress
    let rawMessage = error.localizedDescription
    let lowercasedMessage = rawMessage.lowercased()

    let likelyCause: String
    let recoverySteps: [String]

    if error.code == 48 || lowercasedMessage.contains("address already in use") || lowercasedMessage.contains("port already in use") {
        likelyCause = "A port needed for the tunnel is already in use."
        recoverySteps = [
            "Close other JIT, debugging, proxy, or VPN apps that may be using the tunnel.",
            "Disconnect and reconnect LocalDevVPN.",
            "Restart StikDebug, then try again.",
            "If it keeps happening, reboot the device to clear the stuck port."
        ]
    } else if error.code == 54 || lowercasedMessage.contains("connection reset") {
        likelyCause = "The device or VPN closed the tunnel connection before setup finished."
        recoverySteps = [
            "Open LocalDevVPN and confirm the VPN is connected.",
            "Make sure LocalDevVPN is using the default \(DeviceConnectionContext.defaultTargetIPAddress) address.",
            "Reconnect Wi-Fi and LocalDevVPN, then try again.",
            "If this keeps happening, select a fresh pairing file."
        ]
    } else if error.code == -18 || lowercasedMessage.contains("parse target ip") {
        likelyCause = "The configured target IP address is not valid."
        recoverySteps = [
            "Open Settings and check the target IP address.",
            "Use the default \(DeviceConnectionContext.defaultTargetIPAddress)."
        ]
    } else if lowercasedMessage.contains("missing field") &&
                (lowercasedMessage.contains("public_key") ||
                 lowercasedMessage.contains("private_key") ||
                 lowercasedMessage.contains("identifier")) {
        likelyCause = "A classic MobileDevice pairing file was mistaken for an RPPairing identity."
        recoverySteps = [
            "VectorJIT27 keeps the classic file separate and generates a fresh remote pairing identity.",
            "Tap Try Again once LocalDevVPN is connected.",
            "If the regenerated identity still fails, disconnect and reconnect LocalDevVPN before retrying."
        ]
    } else if lowercasedMessage.contains("timed out") || lowercasedMessage.contains("timeout") {
        likelyCause = "The app could not reach the device before the connection timed out."
        recoverySteps = [
            "Confirm Wi-Fi and LocalDevVPN are both connected.",
            "Wake and unlock the target device.",
            "Confirm LocalDevVPN is exposing the device at \(targetIP)."
        ]
    } else if lowercasedMessage.contains("network is unreachable") || lowercasedMessage.contains("no route") {
        likelyCause = "The VPN route to the device is not available."
        recoverySteps = [
            "Disconnect and reconnect LocalDevVPN.",
            "Confirm iOS shows the VPN indicator.",
            "Try switching Wi-Fi off and on."
        ]
    } else {
        likelyCause = "The tunnel could not be created."
        recoverySteps = [
            "Confirm Wi-Fi and LocalDevVPN are connected.",
            "Wake and unlock the target device.",
            "Reconnect LocalDevVPN, then try again."
        ]
    }

    let steps = recoverySteps.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")

    return """
    \(likelyCause)

    Target: \(targetIP):49152
    Expected LocalDevVPN IP: \(DeviceConnectionContext.defaultTargetIPAddress)

    Try this:
    \(steps)

    Technical details:
    Code \(error.code): \(rawMessage)
    """
}


private func isRetryableTunnelError(_ error: NSError) -> Bool {
    let message = error.localizedDescription.lowercased()
    if error.code == -19 || error.code == 54 {
        return true
    }

    let transientMarkers = [
        "timeout",
        "timed out",
        "connect:",
        "device socket",
        "connection reset",
        "connection refused",
        "network is unreachable",
        "tls tunnel"
    ]
    return transientMarkers.contains { message.contains($0) }
}
