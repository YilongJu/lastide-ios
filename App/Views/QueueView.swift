import LastideKit
import SwiftUI

/// The Queue screen: the drafts that wait for review (plan Table 14, protocol Table 23).
/// A right swipe approves, and a left swipe deletes. The Review tab's badge carries the count.
struct QueueView: View {
    @Bindable var model: AppModel
    @Binding var path: [String]
    /// Opens the Settings tab from the demo banner.
    let onPair: () -> Void
    @State private var filter: QueueFilter = .all
    @State private var message: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.isDemo {
                    Section { DemoBanner(text: AppText.sampleDrafts, onPair: onPair) }
                }
                if model.store.drafts.isEmpty {
                    Section {
                        ContentUnavailableView("No drafts to review", systemImage: "tray",
                                               description: Text("New drafts from your PC appear here."))
                            .accessibilityIdentifier("queueEmpty")
                    } footer: {
                        if model.store.omittedDrafts > 0 { Text(ReviewText.moreOnPC(model.store.omittedDrafts)) }
                    }
                } else {
                    draftsSection
                }
            }
            .navigationTitle("Review")
            .navigationDestination(for: String.self) { id in
                DraftDetailView(model: model, draftID: id)
            }
            .alert("Lastide", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .accessibilityIdentifier("screen.queue")
        }
    }

    private var draftsSection: some View {
        Section {
            let drafts = model.store.drafts(filter)
            if drafts.isEmpty {
                Text("No drafts of this kind.").foregroundStyle(.secondary)
            }
            ForEach(drafts) { draft in
                let target = Target(targetType: .draft, id: draft.id)
                let status = model.store.status(of: target)
                NavigationLink(value: draft.id) {
                    DraftCard(draft: draft, status: status, now: currentTimeMs())
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if status.allowsActions && !draft.desktopOnly {
                        Button("Approve") { act(target, .approve) }.tint(.green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if status.allowsActions && !draft.desktopOnly {
                        Button("Delete", role: .destructive) { act(target, .delete) }
                    }
                }
            }
        } header: {
            Picker("Filter", selection: $filter) {
                ForEach(QueueFilter.allCases, id: \.self) { chip in
                    Text(chip.label).tag(chip)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .textCase(nil)
            .padding(.bottom, 6)
            .accessibilityIdentifier("queueFilter")
        } footer: {
            if model.store.omittedDrafts > 0 { Text(ReviewText.moreOnPC(model.store.omittedDrafts)) }
        }
    }

    private func act(_ target: Target, _ action: DecisionAction) {
        message = model.decide(target, action: action, text: nil, scopeOptionId: nil)
    }
}

/// One draft in the queue: the rule, "3 corrections, 2 projects", the scope with the age, and a status badge.
struct DraftCard: View {
    let draft: Draft
    let status: ItemStatus
    let now: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.text).font(.body)
            Text(ReviewText.evidenceLine(draft))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Words.scope(draft.scope) + " · " + AppText.age(ms: max(0, now - draft.createdAt)))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if draft.desktopOnly {
                StatusBadge(text: ItemStatus.desktopOnly(.draft).displayText!, systemImage: ItemStatus.desktopOnly(.draft).symbol)
            } else if let text = status.displayText {
                StatusBadge(text: text, systemImage: status.symbol)
            }
        }
        .padding(.vertical, 4)
    }
}
