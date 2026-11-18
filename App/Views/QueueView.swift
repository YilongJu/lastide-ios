import LastideKit
import SwiftUI

/// The Queue screen: the drafts that wait for review (plan Table 14, protocol Table 23).
/// A right swipe approves, and a left swipe deletes.
struct QueueView: View {
    @Bindable var model: AppModel
    @Binding var path: [String]
    @State private var filter: QueueFilter = .all
    @State private var message: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.isDemo {
                    Section { Text(AppText.sampleData).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    filterChips
                }
                Section {
                    ForEach(model.store.drafts(filter)) { draft in
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
                } footer: {
                    if model.store.omittedDrafts > 0 { Text(ReviewText.moreOnPC(model.store.omittedDrafts)) }
                }
            }
            .navigationTitle("Review")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(model.store.badgeCount)")
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .accessibilityLabel("\(model.store.badgeCount) drafts")
                }
            }
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

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QueueFilter.allCases, id: \.self) { chip in
                    Button(chip.label) { filter = chip }
                        .buttonStyle(.bordered)
                        .tint(chip == filter ? Color.accentColor : Color.secondary)
                        .accessibilityAddTraits(chip == filter ? .isSelected : [])
                }
            }
        }
    }

    private func act(_ target: Target, _ action: DecisionAction) {
        message = model.decide(target, action: action, text: nil, scopeOptionId: nil)
    }
}

/// One draft in the queue: the rule, "3 corrections, 2 projects", the scope and the age.
struct DraftCard: View {
    let draft: Draft
    let status: ItemStatus
    let now: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.text).font(.body)
            Text(ReviewText.evidenceLine(draft) + " · " + Words.scope(draft.scope))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(AppText.age(ms: max(0, now - draft.createdAt)))
                if let text = draft.desktopOnly ? ItemStatus.desktopOnly.displayText : status.displayText {
                    Text(text).foregroundStyle(.orange)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
