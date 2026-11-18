import LastideKit
import SwiftUI
import UIKit

/// The Pair and Settings screen (plan Table 14, protocol Table 23).
/// It holds pairing with the disclosure and the check code, and the paired PCs with Revoke.
/// It also holds the diagnostics block with one Copy button.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var pendingRevoke: PairingRecord?

    var body: some View {
        NavigationStack {
            List {
                pairedSection
                PairingSection(model: model, flow: model.pairingFlow)
                diagnosticsSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(revokeTitle, isPresented: Binding(get: { pendingRevoke != nil },
                                                                  set: { if !$0 { pendingRevoke = nil } }),
                                titleVisibility: .visible) {
                Button("Revoke", role: .destructive) {
                    guard let record = pendingRevoke else { return }
                    pendingRevoke = nil
                    Task { await model.revoke(record.pairingId) }
                }
            } message: {
                Text("This phone stops syncing with the PC and deletes its copy of the drafts and rules.")
            }
            .accessibilityIdentifier("screen.settings")
        }
    }

    private var revokeTitle: String { "Revoke \(pendingRevoke?.pcName ?? "")?" }

    @ViewBuilder
    private var pairedSection: some View {
        Section("Paired PCs") {
            if model.records.isEmpty {
                Text("No PC yet. Demo mode shows sample data until you pair a PC.").foregroundStyle(.secondary)
            }
            ForEach(model.records, id: \.pairingId) { record in
                let broken = model.brokenIDs.contains(record.pairingId)
                let selected = record.pairingId == model.selectedID
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if broken {
                            Text(record.pcName)
                            Text(AppText.pairAgain).font(.footnote).foregroundStyle(.orange)
                        } else {
                            Text(AppText.pairedWith(record.pcName) + ", "
                                 + AppText.lastSeen(online: selected && model.pcOnline, at: record.pcLastSeenAt,
                                                    now: currentTimeMs()))
                            if selected && model.roomGone {
                                Text(AppText.roomGone).font(.footnote).foregroundStyle(.orange)
                            }
                        }
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").accessibilityLabel("Shown") }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !broken, !selected else { return }
                    do { try model.select(record.pairingId) } catch { model.notice = "This PC could not open: \(error)" }
                }
                Button("Revoke", role: .destructive) { pendingRevoke = record }
            }
        }
    }

    private var diagnosticsText: String {
        model.diagnostics.text(build: model.facts.app, pairingState: pairingState, relayOrigin: model.selectedRecord?.relayOrigin)
    }

    private var pairingState: String {
        guard let record = model.selectedRecord else {
            return model.isDemo ? "demo mode, no PC" : "no PC shown"
        }
        let connection: String
        switch model.connection {
        case .closed: connection = "socket closed"
        case .connecting: connection = "socket connecting"
        case .open: connection = "socket open"
        }
        return "paired with \(record.pcName), \(connection), PC \(model.pcOnline ? "online" : "offline"), "
            + "outbox \(model.store.outbox.count)"
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Text(diagnosticsText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Button("Copy") { UIPasteboard.general.string = diagnosticsText }
        }
    }
}

/// The pairing steps of protocol section 4.3, from the phone's side.
struct PairingSection: View {
    @Bindable var model: AppModel
    @Bindable var flow: PairingFlow
    @State private var pasted = ""
    @State private var cameraProblem: String?

    var body: some View {
        Section("Pair a PC") {
            switch flow.step {
            case .idle:
                Button("Pair a PC") { flow.begin() }
            case .disclosure:
                Text(LastideProtocol.disclosureText)
                Button("Agree and Continue") {
                    do { try model.acceptDisclosure() } catch { model.notice = "The agreement was not saved: \(error)" }
                }
                Button("Cancel", role: .cancel) { flow.cancel() }
            case .scan:
                Text("Open Lastide Settings on your PC, choose Pair a Phone, and scan the code it shows.")
                if QRScannerView.isAvailable && cameraProblem == nil {
                    QRScannerView(onCode: { flow.submit(code: $0) }, onUnavailable: { cameraProblem = $0 })
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let cameraProblem {
                    Text(cameraProblem).font(.footnote).foregroundStyle(.secondary)
                }
                TextField("Or paste the pairing code", text: $pasted, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use Pasted Code") { flow.submit(code: pasted) }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { flow.cancel() }
            case .connecting:
                ProgressView(AppText.connecting)
            case .waitingForPC:
                ProgressView(AppText.waitingForPC)
                Button("Cancel", role: .cancel) { flow.cancel() }
            case .checkCode(let code):
                Text(AppText.typeThisCode)
                Text(code)
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("checkCode")
                Button("Cancel", role: .cancel) { flow.cancel() }
            case .paired(let pcName):
                Text(AppText.pairedWith(pcName))
                Button("Done") { flow.cancel() }
            case .failed(let text):
                Text(text)
                Button("Try Again") {
                    pasted = ""
                    flow.begin()
                }
            }
        }
    }
}
