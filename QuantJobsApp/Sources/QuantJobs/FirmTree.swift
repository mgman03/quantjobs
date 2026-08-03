import SwiftUI

/// The firm list as a collapsible tree in the sidebar: group → tier → firm,
/// with a checkbox at every level so you can flip a whole block or one name.
///
/// The Boards sheet is still there for editing a board's configuration; this
/// is for the thing you do constantly, which is choosing who to scrape.
struct FirmTree: View {

    @Bindable var model: AppModel
    @State private var expandedGroups: Set<String> = []
    @State private var expandedTiers: Set<String> = []

    var body: some View {
        ForEach(model.firmTree) { node in
            let open = expandedGroups.contains(node.group)

            branchRow(
                title: AppModel.groupLabel(node.group),
                state: model.checkState(node.ids, usable: node.usable),
                on: model.enabledCount(node.ids), usable: node.usable,
                indent: 0,
                isOpen: open,
                toggleOpen: { flip(&expandedGroups, node.group) },
                toggleCheck: { model.toggleBranch(node.ids, usable: node.usable) })

            if open {
                ForEach(node.tiers) { tierNode in
                    let key = "\(node.group).\(tierNode.segment)"
                    let tierOpen = expandedTiers.contains(key)

                    branchRow(
                        title: tierNode.segment,
                        state: model.checkState(tierNode.ids, usable: tierNode.usable),
                        on: model.enabledCount(tierNode.ids), usable: tierNode.usable,
                        indent: 1,
                        isOpen: tierOpen,
                        toggleOpen: { flip(&expandedTiers, key) },
                        toggleCheck: {
                            model.toggleBranch(tierNode.ids, usable: tierNode.usable)
                        })

                    if tierOpen {
                        ForEach(tierNode.ids, id: \.self) { id in
                            if let firm = model.company(id) { firmRow(firm) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func branchRow(title: String, state: AppModel.Checked,
                           on: Int, usable: Int, indent: CGFloat,
                           isOpen: Bool, toggleOpen: @escaping () -> Void,
                           toggleCheck: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button(action: toggleOpen) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            checkbox(state, hint: hint(state, on, usable), action: toggleCheck)

            Button(action: toggleOpen) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(indent == 0 ? .callout.weight(.medium) : .callout)
                    Spacer(minLength: 4)
                    Text("\(on)/\(usable)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, indent * 14)
    }

    private func firmRow(_ firm: Company) -> some View {
        HStack(spacing: 5) {
            Spacer().frame(width: 14)
            checkbox(firm.enabled ? .on : .off,
                     hint: firm.isConfigured
                        ? (firm.enabled ? "Stop scraping \(firm.name)"
                                        : "Scrape \(firm.name)")
                        : "No reachable board for \(firm.name) yet") {
                model.setEnabled(!firm.enabled, for: firm.id)
            }
            .disabled(!firm.isConfigured)

            Text(firm.name)
                .font(.callout)
                .foregroundStyle(firm.isConfigured ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !firm.isConfigured {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(firm.note ?? "No reachable board for this firm yet")
            }
        }
        .padding(.leading, 28)
    }

    private func checkbox(_ state: AppModel.Checked, hint: String = "",
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol(state))
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state == .off ? AnyShapeStyle(.tertiary)
                                               : AnyShapeStyle(.tint))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(hint.isEmpty ? "" : hint)
    }

    /// A filled tick for all-on, a dash for some-on, an empty box for none.
    private func symbol(_ state: AppModel.Checked) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "square.lefthalf.filled"
        case .off: "square"
        }
    }

    /// Says what clicking will do, because a part-selected branch turning
    /// fully on is otherwise a surprise.
    private func hint(_ state: AppModel.Checked, _ on: Int, _ usable: Int) -> String {
        switch state {
        case .on: "Turn all \(usable) off"
        case .mixed: "\(on) of \(usable) on — click to turn all on"
        case .off: "Turn all \(usable) on"
        }
    }

    private func flip(_ set: inout Set<String>, _ key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }
}
