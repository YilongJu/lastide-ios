import LastideKit
import SwiftUI

/// The Library screen: a searchable list of approved rules with violations since approval and last seen
/// (plan Table 14, protocol Table 23).
struct LibraryView: View {
    @Bindable var model: AppModel
    @Binding var path: [String]
    @State private var search = ""

    private var rules: [Rule] {
        let all = model.store.rules
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.isDemo {
                    Section { Text(AppText.sampleData).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(rules) { rule in
                        NavigationLink(value: rule.id) { RuleRow(rule: rule, status: model.store.status(of: target(rule))) }
                    }
                } footer: {
                    if model.store.omittedRules > 0 { Text(ReviewText.moreOnPC(model.store.omittedRules)) }
                }
            }
            .searchable(text: $search, prompt: "Search rules")
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { id in
                RuleDetailView(model: model, ruleID: id)
            }
            .accessibilityIdentifier("screen.library")
        }
    }

    private func target(_ rule: Rule) -> Target { Target(targetType: .rule, id: rule.id) }
}

/// One rule: its text, "4 before, 1 since" and when an agent last broke it.
struct RuleRow: View {
    let rule: Rule
    let status: ItemStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rule.text).foregroundStyle(rule.state == .off ? .secondary : .primary)
            HStack {
                Text("\(rule.correctionsBeforeApproval) before, \(rule.violationsSinceApproval) since")
                Text(lastSeen)
                if rule.state == .off { Text("Turned off") }
                if let line = rule.desktopOnly ? nil : status.displayText { Text(line).foregroundStyle(.orange) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var lastSeen: String {
        guard let time = rule.lastSeenAt else { return "Not broken since approval" }
        return "Last broken " + Words.date(time)
    }
}

/// One approved rule: the counters, and Turn Off, Edit and Delete.
struct RuleDetailView: View {
    @Bindable var model: AppModel
    let ruleID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scopeID = ""
    @State private var loadedVersion: Int?
    @State private var message: String?

    var body: some View {
        Group {
            if let rule = model.store.rule(id: ruleID) { form(rule) } else { Color.clear }
        }
        .navigationTitle("Rule")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.store.rule(id: ruleID) == nil) { _, gone in
            if gone { dismiss() }
        }
        .alert("Lastide", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .accessibilityIdentifier("screen.ruleDetail")
    }

    private func form(_ rule: Rule) -> some View {
        let target = Target(targetType: .rule, id: rule.id)
        let status = model.store.status(of: target)
        let actionable = status.allowsActions && !rule.desktopOnly
        let editable = actionable && rule.source != .imported
        return Form {
            Section {
                TextField("Rule", text: $text, axis: .vertical)
                    .lineLimit(1...10)
                    .disabled(!editable)
                    .onChange(of: text) { _, value in
                        if value != rule.text, value.contains(where: \.isNewline) { text = Words.oneLine(value) }
                    }
                Picker("Applies to", selection: $scopeID) {
                    ForEach(rule.scopeOptions, id: \.id) { option in
                        Text(Words.scope(option.scope)).tag(option.id)
                    }
                }
                .disabled(!editable)
                if rule.editedOn == .phone { Text("Edited on phone").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Counters") {
                LabeledContent("Corrections before approval", value: "\(rule.correctionsBeforeApproval)")
                LabeledContent("Violations since approval", value: "\(rule.violationsSinceApproval)")
                LabeledContent("Violations in the last 30 days", value: "\(rule.violationsLast30Days)")
                LabeledContent("Last broken", value: rule.lastSeenAt.map(Words.date) ?? "Never")
                LabeledContent("Approved", value: rule.approvedAt.map(Words.date) ?? "Not recorded")
                LabeledContent("Agents", value: Words.agents(rule.agents))
                if rule.folderGone { Text("The project folder of this rule is gone.").foregroundStyle(.secondary) }
            }
            Section {
                if rule.desktopOnly {
                    Text(ItemStatus.desktopOnly.displayText!)
                } else {
                    if let line = status.displayText { Text(line).foregroundStyle(.orange) }
                    Button("Edit") { act(rule, .edit) }.disabled(!editable || !changed(rule))
                    if rule.state == .off {
                        Button("Turn On") { act(rule, .turnOn) }.disabled(!actionable)
                    } else {
                        Button("Turn Off") { act(rule, .turnOff) }.disabled(!actionable)
                    }
                    Button("Delete", role: .destructive) { act(rule, .delete) }.disabled(!actionable)
                }
            }
        }
        .onAppear { load(rule) }
        .onChange(of: rule.changedAtStoreVersion) { _, _ in load(rule) }
    }

    private func load(_ rule: Rule) {
        guard loadedVersion != rule.changedAtStoreVersion else { return }
        loadedVersion = rule.changedAtStoreVersion
        text = rule.text
        scopeID = Words.currentOptionID(rule.scope, rule.scopeOptions) ?? rule.scopeOptions[0].id
    }

    private func changed(_ rule: Rule) -> Bool {
        text != rule.text || scopeID != Words.currentOptionID(rule.scope, rule.scopeOptions)
    }

    private func act(_ rule: Rule, _ action: DecisionAction) {
        let target = Target(targetType: .rule, id: rule.id)
        let newText: String? = action == .edit && text != rule.text ? text : nil
        let newScope: String? = action == .edit && scopeID != Words.currentOptionID(rule.scope, rule.scopeOptions) ? scopeID : nil
        message = model.decide(target, action: action, text: newText, scopeOptionId: newScope)
    }
}
