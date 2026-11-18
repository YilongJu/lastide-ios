import LastideKit
import SwiftUI

/// The Rule detail screen with edit (plan Table 14, protocol Table 23).
/// It shows one draft with its scope, agents and evidence, and the words while the PC is online.
/// Its buttons are Approve, Save Edit, Reject and Delete.
struct DraftDetailView: View {
    @Bindable var model: AppModel
    let draftID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scopeID = ""
    @State private var loadedVersion: Int?
    @State private var message: String?

    var body: some View {
        Group {
            if let draft = model.store.draft(id: draftID) {
                form(draft)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Rule")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.openEvidence(draftID: draftID) }
        .onDisappear { model.closeEvidence() }
        .onChange(of: model.pcOnline) { _, online in
            if online { model.openEvidence(draftID: draftID) }
        }
        .onChange(of: model.store.draft(id: draftID) == nil) { _, gone in
            if gone { dismiss() }
        }
        .alert("Lastide", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .accessibilityIdentifier("screen.draftDetail")
    }

    private func form(_ draft: Draft) -> some View {
        let target = Target(targetType: .draft, id: draft.id)
        let status = model.store.status(of: target)
        let editable = status.allowsActions && !draft.desktopOnly
        return Form {
            Section {
                TextField("Rule", text: $text, axis: .vertical)
                    .lineLimit(1...10)
                    .disabled(!editable)
                    .onChange(of: text) { _, value in
                        if value != draft.text, value.contains(where: \.isNewline) { text = Words.oneLine(value) }
                    }
                Text(ReviewText.draftedOnPC).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Scope") {
                Picker("Applies to", selection: $scopeID) {
                    ForEach(draft.scopeOptions, id: \.id) { option in
                        Text(Words.scope(option.scope)).tag(option.id)
                    }
                }
                .disabled(!editable)
                LabeledContent("Agents", value: Words.agents(draft.agents))
                LabeledContent("Group", value: Words.group(draft.group))
            }
            Section {
                ForEach(draft.evidence, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Words.signal(item.signal))
                        Text(Words.date(item.at) + " · " + item.projectName).font(.footnote).foregroundStyle(.secondary)
                        if let words = evidenceWords(for: item.id) {
                            Text(words).font(.callout).italic()
                        }
                    }
                }
            } header: {
                Text("Evidence")
            } footer: {
                Text(ReviewText.evidenceLine(draft))
            }
            Section("Why your PC drafted it") {
                if let evidence = currentEvidence(draft) {
                    Text(evidence.rationale ?? "Your PC sent no reason.")
                } else {
                    Text(ReviewText.appearsWhileOnline).foregroundStyle(.secondary)
                }
            }
            if currentEvidence(draft) == nil {
                Section("Words") {
                    Text(ReviewText.appearsWhileOnline).foregroundStyle(.secondary)
                }
            }
            Section {
                if draft.desktopOnly {
                    Text(ItemStatus.desktopOnly.displayText!)
                } else {
                    if let line = status.displayText { Text(line).foregroundStyle(.orange) }
                    Button("Approve") { act(draft, .approve) }.disabled(!editable)
                    Button("Save Edit") { act(draft, .saveEdit) }.disabled(!editable || !changed(draft))
                    Button("Reject") { act(draft, .reject) }.disabled(!editable)
                    Button("Delete", role: .destructive) { act(draft, .delete) }.disabled(!editable)
                }
            }
        }
        .onAppear { load(draft) }
        .onChange(of: draft.changedAtStoreVersion) { _, _ in load(draft) }
    }

    private func load(_ draft: Draft) {
        guard loadedVersion != draft.changedAtStoreVersion else { return }
        loadedVersion = draft.changedAtStoreVersion
        text = draft.text
        scopeID = Words.currentOptionID(draft.scope, draft.scopeOptions) ?? draft.scopeOptions[0].id
    }

    private func changed(_ draft: Draft) -> Bool {
        text != draft.text || scopeID != Words.currentOptionID(draft.scope, draft.scopeOptions)
    }

    private func act(_ draft: Draft, _ action: DecisionAction) {
        let target = Target(targetType: .draft, id: draft.id)
        let newText: String? = (action == .approve || action == .saveEdit) && text != draft.text ? text : nil
        let newScope: String? = (action == .approve || action == .saveEdit)
            && scopeID != Words.currentOptionID(draft.scope, draft.scopeOptions) ? scopeID : nil
        message = model.decide(target, action: action, text: newText, scopeOptionId: newScope)
    }

    /// The evidence words of this draft, when they arrived for its current change.
    private func currentEvidence(_ draft: Draft) -> Evidence? {
        guard let state = model.evidence, state.draftID == draft.id, let evidence = state.evidence,
              evidence.changedAtStoreVersion == draft.changedAtStoreVersion
        else { return nil }
        return evidence
    }

    private func evidenceWords(for id: String) -> String? {
        guard let draft = model.store.draft(id: draftID), let evidence = currentEvidence(draft),
              let item = evidence.items.first(where: { $0.evidenceId == id })
        else { return nil }
        switch item.state {
        case .words: return item.words.map { "\u{201C}\($0)\u{201D}" }
        case .removed: return "Removed on your PC"
        case .excluded: return "Left out on your PC"
        }
    }
}
