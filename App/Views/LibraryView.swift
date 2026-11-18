import LastideKit
import SwiftUI

/// The Library screen: a searchable list of approved rules with violations since approval and last seen
/// (plan Table 14, protocol Table 23).
struct LibraryView: View {
    @Bindable var model: AppModel
    @Binding var path: [String]
    /// Opens the Settings tab from the demo banner.
    let onPair: () -> Void
    @State private var search = ""

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var rules: [Rule] {
        let all = model.store.rules
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.isDemo {
                    Section { DemoBanner(text: AppText.sampleRules, onPair: onPair) }
                }
                Section {
                    if model.store.rules.isEmpty {
                        ContentUnavailableView("No approved rules", systemImage: "books.vertical",
                                               description: Text("Rules you approve appear here."))
                    } else if rules.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    ForEach(rules) { rule in
                        NavigationLink(value: rule.id) { RuleRow(rule: rule, status: model.store.status(of: target(rule))) }
                    }
                } footer: {
                    if model.store.omittedRules > 0 { Text(ReviewText.moreOnPC(model.store.omittedRules)) }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search rules")
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { id in
                RuleDetailView(model: model, ruleID: id)
            }
            .accessibilityIdentifier("screen.library")
        }
    }

    private func target(_ rule: Rule) -> Target { Target(targetType: .rule, id: rule.id) }
}

/// One rule: its text, "3 corrections · 1 violation since approval", when an agent last broke it, and its badges.
struct RuleRow: View {
    let rule: Rule
    let status: ItemStatus
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rule.text).foregroundStyle(rule.state == .off ? .secondary : .primary)
            Text(Words.counters(rule)).font(.footnote).foregroundStyle(.secondary)
            Text(lastSeen).font(.footnote).foregroundStyle(.secondary)
            if rule.state == .off || badge != nil {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) { badges }
                } else {
                    HStack(spacing: 6) { badges }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var badges: some View {
        if rule.state == .off { OffBadge() }
        if let badge { StatusBadge(text: badge, systemImage: status.symbol) }
    }

    private var badge: String? { rule.desktopOnly ? nil : status.displayText }

    private var lastSeen: String {
        guard let time = rule.lastSeenAt else { return "Not broken since approval" }
        return "Last broken " + Words.date(time)
    }
}

/// One approved rule: the counters, the Active switch (Turn Off and Turn On), Save Edit once the text changed, and Delete.
struct RuleDetailView: View {
    @Bindable var model: AppModel
    let ruleID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scopeID = ""
    @State private var loadedVersion: Int?
    @State private var message: String?
    @State private var confirmDelete = false

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
                    .accessibilityIdentifier("ruleText")
                    .onChange(of: text) { _, value in
                        if value != rule.text, value.contains(where: \.isNewline) { text = Words.oneLine(value) }
                    }
            } header: {
                if editable { Label("Rule text", systemImage: "pencil") } else { Text("Rule text") }
            } footer: {
                if editable && !changed(rule) {
                    Text("Change the text or the scope, then tap Save Edit.")
                } else if rule.editedOn == .phone {
                    Text("Edited on phone")
                }
            }
            Section("Scope") {
                Picker("Applies to", selection: $scopeID) {
                    ForEach(rule.scopeOptions, id: \.id) { option in
                        Text(Words.scope(option.scope)).tag(option.id)
                    }
                }
                .disabled(!editable)
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
                    StatusBadge(text: ItemStatus.desktopOnly.displayText!, systemImage: ItemStatus.desktopOnly.symbol)
                } else {
                    if let line = status.displayText { StatusBadge(text: line, systemImage: status.symbol) }
                    // Turn On and Turn Off (protocol Table 23) as one switch.
                    Toggle("Active", isOn: Binding(get: { rule.state != .off },
                                                   set: { on in act(rule, on ? .turnOn : .turnOff) }))
                        .disabled(!actionable)
                    Button("Delete Rule", role: .destructive) { confirmDelete = true }.disabled(!actionable)
                }
            }
        }
        .toolbar {
            if !rule.desktopOnly && changed(rule) {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Edit") { act(rule, .edit) }.disabled(!editable)
                }
            }
        }
        .confirmationDialog("Delete this rule?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { act(rule, .delete) }
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
