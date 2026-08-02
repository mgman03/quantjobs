import SwiftUI

/// The filter controls, as a laid-out panel rather than a menu.
///
/// These lived in a `Menu`, which meant radio lists and a text field crammed
/// into a popup strip — fiddly to read and worse to type into.
struct FilterPanel: View {

    @Bindable var model: AppModel

    private let windows: [(String, Int?)] = [
        ("Any time", nil), ("7 days", 7), ("14 days", 14), ("30 days", 30),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Posted within") {
                Picker("", selection: $model.sinceDays) {
                    ForEach(windows, id: \.0) { label, days in
                        Text(label).tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            section("Location contains") {
                TextField("london, zurich", text: $model.locationFilter)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated. For a proper list, use the places button.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            section("Firm tag") {
                Picker("", selection: $model.tagFilter) {
                    Text("Any tag").tag(String?.none)
                    ForEach(model.allTags, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Only roles I haven't seen", isOn: $model.newOnly)
                Toggle("Merge the same role across offices", isOn: $model.mergeRoles)
                Toggle("Search full descriptions (slower)", isOn: $model.deep)
                Toggle("Record this run in the seen list", isOn: $model.recordState)
            }
            .toggleStyle(.checkbox)

            Divider()

            HStack {
                Button("Reset Filters", action: model.clearFilters)
                    .disabled(!model.hasExtraFilters)
                Spacer()
                Text("\(model.visibleJobs.count) roles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
