import SwiftUI

/// The row of controls above the table: level, place, firms, date, applied,
/// search. Its own view so `--check --render` can snapshot it — "do these
/// controls look like one family?" is a question only a picture answers.
struct FilterBar: View {

    @Bindable var model: AppModel

    @State private var showingPlaces = false
    @State private var showingFirms = false

    /// "All firms" / "Quant" / "62 firms" — the state at a glance.
    private var firmsLabel: String {
        let on = model.selectedFirms.count
        let total = model.companies.count { $0.isConfigured }
        if on == total { return "All firms" }
        for node in model.firmTree where model.checkState(node.ids,
                                                          usable: node.usable) == .on {
            let others = model.firmTree.filter { $0.group != node.group }
            if others.allSatisfy({ model.enabledCount($0.ids) == 0 }) {
                return AppModel.groupLabel(node.group)
            }
        }
        return "\(on) firms"
    }

    /// "Anywhere" / "Europe" / "3 places" — enough to see the state at a glance.
    private var placesLabel: String {
        let continents = model.continentFilter, cities = model.cityFilter
        if continents.isEmpty && cities.isEmpty { return "Anywhere" }
        if !cities.isEmpty {
            return cities.count == 1 ? cities.first! : "\(cities.count) cities"
        }
        if continents.count == 1, let only = continents.first { return only }
        return "\(continents.count) regions"
    }

    /// Every filter control wears the same label and the same button style.
    /// The date filter used to be a borderless Menu next to bordered Buttons,
    /// which made one of four look like a different kind of control.
    private func filterLabel(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .font(.callout)
    }

    /// The one filter that is on or off rather than a choice, so it has to *look*
    /// on or off. Two button styles rather than a tint: `.bordered` with an accent
    /// tint draws blue text in a washed-out capsule, which reads as a link sitting
    /// between three bordered buttons — the same inconsistency the Toggle had,
    /// reached from the other direction. Prominent when on, plain when off: same
    /// shape family either way, unmistakable state.
    @ViewBuilder
    private var hideAppliedButton: some View {
        Button { model.hideApplied.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: model.hideApplied
                      ? "paperplane.slash.fill" : "paperplane")
                Text("Hide applied")
            }
            .font(.callout)
        }
        .modifier(ProminentWhen(on: model.hideApplied))
        .fixedSize()
        .help(model.hideApplied
              ? "Holding back \(model.appliedInResults) posting(s) you've applied "
                + "to — they're still in the Applied list"
              : "Leave out roles you've already applied to")
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.level) {
                ForEach(Level.allCases) {
                    Text($0.shortLabel).tag($0).help($0.hint)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(model.level.hint)


            Button {
                showingPlaces.toggle()
            } label: {
                filterLabel("globe.americas", placesLabel)
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showingPlaces, arrowEdge: .bottom) {
                PlaceFilter(model: model)
            }
            .help("Filter by continent, then drill into cities")

            Button {
                showingFirms.toggle()
            } label: {
                filterLabel("building.2", firmsLabel)
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showingFirms, arrowEdge: .bottom) {
                FirmFilter(model: model)
            }
            .help("Choose which firms to scrape")

            Menu {
                Picker("", selection: $model.sinceDays) {
                    Text("Any time").tag(Int?.none)
                    Text("Last 7 days").tag(Int?.some(7))
                    Text("Last 14 days").tag(Int?.some(14))
                    Text("Last 30 days").tag(Int?.some(30))
                    Text("Last 90 days").tag(Int?.some(90))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                filterLabel("calendar",
                            model.sinceDays.map { "Last \($0)d" } ?? "Any time")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How recently the role was posted")

            hideAppliedButton

            Spacer(minLength: 8)

            SearchField(model: model)

            // The controls above show their own state, so there are no chips to
            // clear one by one — but a filter restored from a previous session
            // still needs one way out, and `deep` and `tag` have no control of
            // their own at all.
            if model.hasExtraFilters {
                Button("Clear", action: model.clearFilters)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Turn every filter off")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Pulled out of the filter row because the saved-list header needs it too.
struct SearchField: View {

    @Bindable var model: AppModel

    /// Lives in the filter row rather than the window toolbar. In the toolbar it
    /// was drawn across the top of the inspector, so the field's capsule and the
    /// panel's rounded corner overlapped whenever a role was selected.
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Filter roles", text: $model.search)
                .textFieldStyle(.plain)
                .frame(width: 150)
            if !model.search.isEmpty {
                Button { model.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        .fixedSize()
        .help("Filter the roles already on screen")
    }
}

/// Swaps between two button styles. A conditional `.buttonStyle` can't be written
/// inline — the two styles are different types — and branching the whole Button
/// duplicates its label and its action.
private struct ProminentWhen: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
