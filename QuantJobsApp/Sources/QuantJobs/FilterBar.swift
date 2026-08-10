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
    private func filterLabel(_ symbol: String, _ text: String,
                             compact: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if !compact {
                Text(text)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
        }
        .font(.callout)
        // The text is gone in compact form, so the tooltip has to carry it.
        .help(compact ? text : "")
    }

    /// Which stacks to leave out. Tick boxes, not a Picker: it's a set of things
    /// you don't want, and every label says so — an include list needed a tick on
    /// everything you'd accept plus one on "unspecified", which is three ticks to
    /// express one exclusion and silently empty if you missed the last.
    private func stackMenu(compact: Bool) -> some View {
        Menu {
            Section("Leave out roles that use") {
                ForEach(model.stackCategories) { stack in
                    Toggle(isOn: Binding(
                        get: { model.excludedStacks.contains(stack.name) },
                        set: { _ in model.toggleStack(stack.name) })) {
                        // Spelled out per row, because a tick box next to a
                        // language reads as "I want this one" unless the row says
                        // otherwise.
                        Text("\(stack.shortName) — hide these")
                    }
                }
            }
            if !model.excludedStacks.isEmpty {
                Divider()
                Button("Show every stack") { model.excludedStacks = [] }
            }
        } label: {
            filterLabel("curlybraces", model.stackLabel, compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        // No .fixedSize(): the filter row can't wrap, so a control that refuses
        // to shrink pushes the detail column past the window width and the
        // sidebar gets squeezed below its stated minimum — which clips its
        // labels rather than narrowing the row. Truncating a label here is the
        // cheaper failure.
        .layoutPriority(-1)
        .help("Tick a stack to remove those roles. Anything that names no stack "
              + "stays — that's most of them, so this narrows rather than empties.")
    }

    /// Roles you've applied to: shown, hidden, or the whole firm hidden.
    ///
    /// A menu rather than a button, for three reasons. It's a three-way choice
    /// now, so a toggle can't express it. It reads as one of the family — the
    /// same bordered label as place, firms and date — instead of a filled blue
    /// pill shouting from the middle of the row. And a menu has room to say what
    /// each option means, which "Hide applied" never did.
    private func appliedMenu(compact: Bool) -> some View {
        Menu {
            // The section header names what the three options are about. Without
            // it the menu opened on "Show roles I've applied to" with nothing
            // saying that's what this control governs.
            Section("Roles you've already applied to") {
                Picker("", selection: $model.appliedFilter) {
                    ForEach(AppliedFilter.allCases) { option in
                        Text(option.label).tag(option).help(option.help)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            filterLabel(model.appliedFilter.symbol, model.appliedFilter.short,
                        compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        // No .fixedSize(): the filter row can't wrap, so a control that refuses
        // to shrink pushes the detail column past the window width and the
        // sidebar gets squeezed below its stated minimum — which clips its
        // labels rather than narrowing the row. Truncating a label here is the
        // cheaper failure.
        .layoutPriority(-1)
        .accessibilityLabel("Applied roles: \(model.appliedFilter.label)")
        // The state lives in the label, so the control doesn't need to change
        // shape to say it's active — but the count is worth having on hover.
        .help(model.appliedFilter.isFiltering
              ? model.appliedFilter.help
                + " — currently holding back \(model.appliedInResults)"
              : model.appliedFilter.help)
    }

    /// Three layouts, widest first: full labels; icon-only filter buttons with the
    /// level picker intact; and icons with the level picker collapsed to a menu.
    ///
    /// ViewThatFits rather than letting the row compress. Compression made every
    /// control degrade at once — the date, stack and applied menus all rendered as
    /// "…" while the level picker kept its width — and worse, a row that still
    /// wanted more than the window took it out of the sidebar, which clips its
    /// labels instead of narrowing. Choosing a layout that *fits* means nothing is
    /// truncated and the sidebar is never squeezed.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false, levelAsMenu: false)
            row(compact: true, levelAsMenu: false)
            row(compact: true, levelAsMenu: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func row(compact: Bool, levelAsMenu: Bool) -> some View {
        HStack(spacing: 8) {
            if levelAsMenu {
                Menu {
                    Picker("", selection: $model.level) {
                        ForEach(Level.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    filterLabel("person.crop.rectangle.stack", model.level.shortLabel,
                                compact: false)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(model.level.hint)
            } else {
            Picker("", selection: $model.level) {
                ForEach(Level.allCases) {
                    Text($0.shortLabel).tag($0).help($0.hint)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // The one control that keeps its intrinsic width. Four segments
            // squeezed to "Int…" would be worse than a narrower search box, and
            // this is the most-used control in the row.
            .fixedSize()
            .help(model.level.hint)
            }

            Button {
                showingPlaces.toggle()
            } label: {
                filterLabel("globe.americas", placesLabel, compact: compact)
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showingPlaces, arrowEdge: .bottom) {
                PlaceFilter(model: model)
            }
            .help("Filter by continent, then drill into cities")

            Button {
                showingFirms.toggle()
            } label: {
                filterLabel("building.2", firmsLabel, compact: compact)
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
                            model.sinceDays.map { "Last \($0)d" } ?? "Any time",
                            compact: compact)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .layoutPriority(-1)
            .help("How recently the role was posted")

            stackMenu(compact: compact)

            appliedMenu(compact: compact)

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
                .frame(minWidth: 70, idealWidth: 150)
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
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(-1)
        .help("Filter the roles already on screen")
    }
}
