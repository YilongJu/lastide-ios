import SwiftUI
import UIKit
import VisionKit

/// The camera scanner for the pairing QR code, on VisionKit's `DataScannerViewController`.
/// The app does not register the `lastide-pair` scheme, so only this scanner reads the code (protocol section 3.2).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onUnavailable: @MainActor (String) -> Void

    /// True when this device has a camera that can scan and the person allowed the camera.
    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true,
                                                isGuidanceEnabled: true,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    /// Starts the scanner once, in a main actor task after this update, so the scanner is on screen first.
    /// A failure then reaches `onUnavailable` outside the view update.
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        let coordinator = context.coordinator
        guard !coordinator.startRequested else { return }
        coordinator.startRequested = true
        Task { @MainActor in
            do {
                try scanner.startScanning()
            } catch {
                coordinator.cameraFailed("The camera did not start: \(error.localizedDescription)")
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onUnavailable: onUnavailable) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: @MainActor (String) -> Void
        private let onUnavailable: @MainActor (String) -> Void
        private var delivered = false
        /// True once `updateUIViewController` asked the scanner to start.
        var startRequested = false

        init(onCode: @escaping @MainActor (String) -> Void, onUnavailable: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
        }

        func cameraFailed(_ text: String) {
            onUnavailable(text)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    delivered = true
                    dataScanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onUnavailable("The camera stopped: \(error.localizedDescription)")
        }
    }
}
