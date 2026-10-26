#if canImport(SwiftUI)
import SwiftUI

/// Compact, single-row controls with a separate panel for advanced choices.
struct FilterBar: View {
    private enum Density: Equatable { case wide, compact, icons }
    @Bindable var model: AppModel
    @State private var showingPlaces = false
    @State private var showingFirms = false
    @State private var showingSettings = false

    private var placesLabel: String {
        if !model.cityFilter.isEmpty {
            return model.cityFilter.count == 1 ? model.cityFilter.first! : "\(model.cityFilter.count) cities"
        }
        if model.continentFilter.count == 1 { return model.continentFilter.first! }
        return model.continentFilter.isEmpty ? "Anywhere" : "\(model.continentFilter.count) regions"
    }

    @ViewBuilder
    private func label(_ title: String, _ symbol: String, density: Density) -> some View {
        if density == .icons {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .frame(width: 18)
                .accessibilityLabel(title)
        } else if density == .compact {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: symbol)
                .font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func categoryMenu(_ density: Density, width: CGFloat) -> some View {
        Menu {
            Section("Choose one or more job categories") {
                ForEach(model.navCategories) { category in
                    Toggle(isOn: Binding(
                        get: { model.selectedCategoryIDs.contains(category.name) },
                        set: { _ in model.toggleCategory(category.name) }
                    )) {
                        Label(category.displayName, systemImage: category.symbol)
                    }
                    .help(category.description)
                }
            }
            if model.selectedCategoryIDs.isEmpty {
                Text("No selection shows all categories")
            } else {
                Divider()
                Button("Show all categories") { model.selectedCategoryIDs = [] }
            }
        } label: { label("Categories", "square.grid.2x2", density: density) }
        .modifier(FilterControlSurface(width: width))
        .help("Choose one or more categories. With none selected, all jobs are shown.")
    }

    private func level(_ density: Density, width: CGFloat) -> some View {
        Menu {
            ForEach(Level.allCases) { choice in
                Button {
                    model.level = choice
                } label: {
                    if model.level == choice {
                        Label(choice.shortLabel, systemImage: "checkmark")
                    } else {
                        Text(choice.shortLabel)
                    }
                }
            }
        } label: { label(model.level.shortLabel, "graduationcap", density: density) }
        .modifier(FilterControlSurface(width: width))
    }
    private func places(_ density: Density, width: CGFloat) -> some View {
        Button { showingPlaces.toggle() } label: {
            label(density == .compact ? "Locations" : placesLabel, "globe", density: density)
        }
            .modifier(FilterControlSurface(width: width))
            .popover(isPresented: $showingPlaces) { PlaceFilter(model: model) }
            .help(placesLabel)
    }
    private func firms(_ density: Density, width: CGFloat) -> some View {
        Button { showingFirms.toggle() } label: {
            label(density == .compact ? "Firms" : "\(model.selectedFirms.count) firms",
                  "building.2", density: density)
        }
            .modifier(FilterControlSurface(width: width))
            .popover(isPresented: $showingFirms) { FirmFilter(model: model) }
            .help("\(model.selectedFirms.count) firms")
    }
    private func more(_ density: Density, width: CGFloat) -> some View {
        Button { showingSettings.toggle() } label: {
            label(density == .compact ? "Settings" : "Advanced Settings",
                  "gearshape", density: density)
        }
        .modifier(FilterControlSurface(width: width))
        .accessibilityLabel("Advanced Settings")
        .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
            AdvancedSettingsPanel(model: model)
        }
        .help("Dates, intake year, exclusions, matching, and how roles are shown")
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let density: Density = geometry.size.width < 420 ? .icons
                    : geometry.size.width < 760 ? .compact : .wide
                let width = density == .wide ? CGFloat(146)
                    : (geometry.size.width - 24) / 5
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        categoryMenu(density, width: width)
                        level(density, width: width)
                        places(density, width: width)
                        firms(density, width: width)
                        more(density, width: width)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
            }
            .frame(height: 32)
            HStack(spacing: 8) {
                SearchField(model: model)
                if model.hasExtraFilters {
                    Button(action: model.clearFilters) {
                        Label("Clear", systemImage: "xmark").font(.system(size: 12))
                    }
                    .modifier(FilterControlSurface(width: 70))
                }
            }
        }
        .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden)
        .controlSize(.regular)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

private struct FilterControlSurface: ViewModifier {
    let width: CGFloat
    func body(content: Content) -> some View {
        content.frame(width: width, height: 32)
            .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct AdvancedSettingsPanel: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Advanced Settings", systemImage: "gearshape")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Narrow results") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Date posted") {
                                Picker("Date posted", selection: $model.sinceDays) {
                                    Text("Any date").tag(Int?.none)
                                    ForEach([7, 14, 30, 90], id: \.self) {
                                        Text("Last \($0) days").tag(Int?.some($0))
                                    }
                                }
                                .labelsHidden()
                            }
                            LabeledContent("Intake year") {
                                Picker("Intake year", selection: $model.intakeFilter) {
                                    Text("Any year").tag(Int?.none)
                                    ForEach(model.availableIntakes, id: \.year) {
                                        Text(String($0.year)).tag(Int?.some($0.year))
                                    }
                                }
                                .labelsHidden()
                            }
                            LabeledContent("Previously applied") {
                                Picker("Previously applied", selection: $model.appliedFilter) {
                                    ForEach(AppliedFilter.allCases) { Text($0.label).tag($0) }
                                }
                                .labelsHidden()
                            }
                            Toggle("Only roles new to me", isOn: $model.newOnly)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    GroupBox("Exclude roles") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Roles requiring a PhD", isOn: $model.excludePhD)
                            if !model.stackCategories.isEmpty {
                                Divider()
                                Text("Technology stacks").font(.subheadline.weight(.medium))
                                ForEach(model.stackCategories) { stack in
                                    Toggle("Hide \(stack.shortName)", isOn: Binding(
                                        get: { model.excludedStacks.contains(stack.name) },
                                        set: { _ in model.toggleStack(stack.name) }))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    GroupBox("Matching and display") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Search full job descriptions", isOn: $model.deep)
                            Toggle("Combine the same role across offices", isOn: $model.mergeRoles)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }
            }
            HStack {
                Button("Reset Settings", action: model.resetAdvancedSettings)
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 390, height: 490)
        .controlSize(.small)
    }
}

struct SearchField: View {
    @Bindable var model: AppModel
    /// What's typed, handed to the model once typing pauses. Every change to
    /// `model.search` re-filters every posting, so binding the field straight to
    /// it made each keystroke wait for a pass over the whole scrape.
    @State private var text: String

    init(model: AppModel) {
        self.model = model
        // Seeded, or the first pass below would wipe out a restored search.
        _text = State(initialValue: model.search)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search roles, firms or locations", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .task(id: text) {
            // Clearing is one change, not a run of them, so it needn't wait.
            if !text.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            if model.search != text { model.search = text }
        }
        // Clear Filters, a restored filter set, the other copy of this field.
        .onChange(of: model.search) { _, search in
            if search != text { text = search }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(minHeight: 34)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
    }
}
#endif
