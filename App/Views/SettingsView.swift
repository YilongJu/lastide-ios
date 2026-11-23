import LastideKit
import SwiftUI
import UIKit

/// The Pair and Settings screen (plan Table 14, protocol Table 23).
/// It holds the paired PCs with Revoke and the "Pair a PC" button, the pairing steps with the disclosure sheet and
/// the check code, and a link to the diagnostics block with its one Copy button.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var pendingRevoke: PairingRecord?

    var body: some View {
        let flow = model.pairingFlow!
        NavigationStack {
            List {
                pairedSection(flow)
                if PairingSection.showsSteps(flow.step) {
                    PairingSection(model: model, flow: flow)
                }
                NotificationsSection(model: model)
                Section {
                    NavigationLink {
                        DiagnosticsView(model: model)
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
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
            .sheet(isPresented: Binding(get: { flow.step == .disclosure },
                                        set: { shown in if !shown && flow.step == .disclosure { flow.cancel() } })) {
                DisclosureSheet(model: model, flow: flow)
            }
            .accessibilityIdentifier("screen.settings")
        }
    }

    private var revokeTitle: String { "Revoke \(pendingRevoke?.pcName ?? "")?" }

    private func pairedSection(_ flow: PairingFlow) -> some View {
        Section {
            ForEach(model.records, id: \.pairingId) { record in
                recordRow(record)
                Button("Revoke", role: .destructive) { pendingRevoke = record }
            }
            if !PairingSection.showsSteps(flow.step) {
                Button { flow.begin() } label: {
                    Label("Pair a PC", systemImage: "qrcode.viewfinder")
                }
            }
        } header: {
            Text("Paired PCs")
        } footer: {
            if model.records.isEmpty {
                Text("No PC yet. Demo mode shows sample data until you pair a PC.")
            }
        }
    }

    private func recordRow(_ record: PairingRecord) -> some View {
        let broken = model.brokenIDs.contains(record.pairingId)
        let selected = record.pairingId == model.selectedID
        return HStack {
            VStack(alignment: .leading, spacing: 6) {
                if broken {
                    Text(record.pcName)
                    StatusBadge(text: AppText.pairAgain, systemImage: "exclamationmark.triangle")
                } else {
                    Text(AppText.pairedWith(record.pcName) + ", "
                         + AppText.lastSeen(online: selected && model.pcOnline, at: record.pcLastSeenAt,
                                            now: currentTimeMs()))
                    if selected && model.roomGone {
                        StatusBadge(text: AppText.roomGone, systemImage: "exclamationmark.triangle")
                    }
                    if model.registeredIDs.contains(record.pairingId) {
                        StatusBadge(text: AppText.notificationsRegistered, systemImage: "bell")
                    }
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").accessibilityLabel("Shown") }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("pairedPC")
        .onTapGesture {
            guard !broken, !selected else { return }
            do { try model.select(record.pairingId) } catch { model.notice = "This PC could not open: \(error)" }
        }
    }
}

/// The diagnostics block of protocol Table 23 on its own page, with one Copy button.
struct DiagnosticsView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            Section {
                Text(diagnosticsText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            } footer: {
                Text("Copy this block into a support message when pairing or syncing fails.")
            }
            Section {
                Button("Copy") { UIPasteboard.general.string = diagnosticsText }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.diagnostics")
    }

    private var diagnosticsText: String {
        model.diagnostics.text(build: model.facts.app, pairingState: pairingState, relayOrigin: model.selectedRecord?.relayOrigin,
                               push: model.pushFacts)
    }

    /// The selected PC and its socket, and the pairing step while a pairing runs.
    private var pairingState: String {
        let pc: String
        if let record = model.selectedRecord {
            let connection: String
            switch model.connection {
            case .closed: connection = "socket closed"
            case .connecting: connection = "socket connecting"
            case .open: connection = "socket open"
            }
            pc = "paired with \(record.pcName), \(connection), PC \(model.pcOnline ? "online" : "offline"), "
                + "outbox \(model.store.outbox.count)"
        } else {
            pc = model.isDemo ? "demo mode, no PC" : "no PC shown"
        }
        guard let step = PairingSection.diagnosticsWords(model.pairingFlow.step) else { return pc }
        return pc + "; pairing step: " + step
    }
}

/// The Notifications section of design section 6.8: what iOS allows, a button that fixes it, and the switch
/// "Show rule text in notifications".
struct NotificationsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            LabeledContent("Notifications", value: model.permission.label)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notificationsState")
            switch model.permission {
            case .off:
                Button("Open iOS Settings") {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            case .notAsked:
                Button(AppText.turnOn) { Task { await model.answerNotificationQuestion(turnOn: true) } }
            case .on, .unknown:
                EmptyView()
            }
            Toggle(AppText.showRuleText, isOn: Binding(get: { model.groupSettings.showRuleText },
                                                       set: { model.setShowRuleText($0) }))
        } header: {
            Text("Notifications")
        } footer: {
            Text(AppText.showRuleTextNote)
        }
    }
}

/// The disclosure of protocol section 4.3, step 4, as a sheet with one primary button.
struct DisclosureSheet: View {
    @Bindable var model: AppModel
    @Bindable var flow: PairingFlow

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(LastideProtocol.disclosureText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Before you pair")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    Button {
                        do { try model.acceptDisclosure() } catch { model.notice = "The agreement was not saved: \(error)" }
                    } label: {
                        Text("Agree and Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("Not Now") { flow.cancel() }
                        .controlSize(.large)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}

/// The pairing steps of protocol section 4.3 after the disclosure, from the phone's side.
struct PairingSection: View {
    @Bindable var model: AppModel
    @Bindable var flow: PairingFlow
    @State private var pasted = ""
    @State private var cameraProblem: String?

    /// True while a step after the disclosure shows. The idle step offers "Pair a PC", and the disclosure is a sheet.
    static func showsSteps(_ step: PairingStep) -> Bool {
        switch step {
        case .idle, .disclosure: return false
        case .scan, .connecting, .waitingForPC, .checkCode, .paired, .failed: return true
        }
    }

    /// The step as the diagnostics block names it, or nil while no pairing runs.
    static func diagnosticsWords(_ step: PairingStep) -> String? {
        switch step {
        case .idle: return nil
        case .disclosure: return "disclosure shown"
        case .scan: return "waiting for a pairing code"
        case .connecting: return "connecting to the relay"
        case .waitingForPC: return "pair request sent, waiting for the PC"
        case .checkCode: return "check code shown, waiting for the PC to accept"
        case .paired: return "paired"
        case .failed(let text): return "failed: \(text)"
        }
    }

    var body: some View {
        Section("Pair a PC") {
            switch flow.step {
            case .idle, .disclosure:
                EmptyView()
            case .scan:
                Text("Open Lastide Settings on your PC, choose Pair a Phone, and scan the code it shows.")
                if QRScannerView.isAvailable && cameraProblem == nil {
                    QRScannerView(onCode: { flow.submit(code: $0) }, onUnavailable: { cameraProblem = $0 })
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Label(cameraProblem ?? AppText.scannerUnavailable, systemImage: "camera")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Or paste the pairing code", text: $pasted, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("pastedCode")
                Button("Use Pasted Code") { flow.submit(code: pasted) }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { flow.cancel() }
            case .connecting:
                ProgressView(AppText.connecting)
            case .waitingForPC:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(AppText.waitingForPC)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pairingWaiting")
                Button("Cancel", role: .cancel) { flow.cancel() }
            case .checkCode(let code):
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppText.typeThisCode)
                    Text(code)
                        .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("checkCode")
                }
                HStack(spacing: 10) {
                    ProgressView()
                    Text(AppText.waitingForPC).foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { flow.cancel() }
            case .paired(let pcName):
                Text(AppText.pairedWith(pcName))
                Button("Done") { flow.cancel() }
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("pairingFailed")
                Button("Try Again") {
                    pasted = ""
                    flow.begin()
                }
                Button("Cancel", role: .cancel) { flow.cancel() }
            }
        }
    }
}
