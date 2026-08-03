import SwiftUI

/// Choosing which firms to scrape, laid out like the location picker: the
/// grouping on the left, the individual names on the right.
///
/// Clicking a group's *name* focuses it, narrowing the list beside it.
/// Clicking its *checkbox* turns that whole block on or off.
struct FirmFilter: View {

    @Bindable var model: AppModel
    @State private var focused: Set<String> = []
    @State private var search = ""

    /// Left-hand rows: every segment, under its group heading.
    private var groups: [(group: String, segments: [AppModel.FirmTierNode])] {
        model.firmTree.map { ($0.group, $0.tiers) }
    }

    /// Right-hand rows: firms in the focused segments, or all of them.
    private var firms: [Company] {
        let ids: [Company.ID] = model.firmTree.flatMap { node in
            node.tiers.flatMap { seg -> [Company.ID] in
                let key = "\(node.group)|\(seg.segment)"
                return focused.isEmpty || focused.contains(key) ? seg.ids : []
            }
        }
        var out = ids.compactMap { model.company($0) }
        if !search.isEmpty {
            let needle = search.lowercased()
            out = out.filter { $0.name.lowercased().contains(needle) }
        }
        // Sorted across the whole list, not per segment — concatenating each
        // group's A-Z left the combined list looking unsorted.
        return out.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            groupColumn
            Divider()
            firmColumn
        }
        .frame(width: 560, height: 420)
    }

    // MARK: - Groups

    private var groupColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Group", trailing: {
                Button("All On") {
                    model.setEnabled(true, for: model.companies.map(\.id))
                }
                Button("All Off") {
                    model.setEnabled(false, for: model.companies.map(\.id))
                }
            })

            List {
                ForEach(groups, id: \.group) { entry in
                    Section {
                        ForEach(entry.segments) { seg in
                            let key = "\(entry.group)|\(seg.segment)"
                            segmentRow(key: key, seg: seg)
                        }
                    } header: {
                        Text(AppModel.groupLabel(entry.group).uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.6)
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 230)
    }

    private func segmentRow(key: String, seg: AppModel.FirmTierNode) -> some View {
        let state = model.checkState(seg.ids, usable: seg.usable)
        let on = model.enabledCount(seg.ids)
        return HStack(spacing: 7) {
            Button {
                model.toggleBranch(seg.ids, usable: seg.usable)
            } label: {
                Image(systemName: symbol(state))
                    .foregroundStyle(state == .off ? AnyShapeStyle(.tertiary)
                                                   : AnyShapeStyle(.tint))
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(state == .on ? "Turn all \(seg.usable) off"
                               : "Turn all \(seg.usable) on")

            Button {
                if focused.contains(key) { focused.remove(key) } else { focused.insert(key) }
            } label: {
                HStack(spacing: 4) {
                    Text(seg.segment)
                    Spacer(minLength: 4)
                    Text("\(on)/\(seg.usable)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.vertical, 1)
        .listRowBackground(
            focused.contains(key)
                ? AnyView(RoundedRectangle(cornerRadius: 5).fill(.selection))
                : AnyView(Color.clear))
    }

    // MARK: - Firms

    private var firmColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(focused.isEmpty ? "Firm" : "Firm in selection", trailing: {
                Button("All") { model.setEnabled(true, for: firms.map(\.id)) }
                    .disabled(firms.isEmpty)
                Button("None") { model.setEnabled(false, for: firms.map(\.id)) }
                    .disabled(firms.isEmpty)
            })

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Find a firm", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            List {
                ForEach(firms) { firm in
                    Button {
                        model.setEnabled(!firm.enabled, for: firm.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: firm.enabled ? "checkmark.square.fill"
                                                           : "square")
                                .foregroundStyle(firm.enabled ? AnyShapeStyle(.tint)
                                                              : AnyShapeStyle(.tertiary))
                            Text(firm.name)
                                .foregroundStyle(firm.isConfigured ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if !firm.isConfigured {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                    .help(firm.note ?? "No reachable board yet")
                            }
                            Text(firm.ats.label)
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.vertical, 1)
                    .disabled(!firm.isConfigured)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Pieces

    private func header<T: View>(_ title: String,
                                 @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            Spacer()
            trailing()
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func symbol(_ state: AppModel.Checked) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "square.lefthalf.filled"
        case .off: "square"
        }
    }
}
