// Wrapped so the package still builds where SwiftUI does not exist —
// the scraper has to run on Linux for the scheduled fetch, and only the
// window needs Apple's UI frameworks.
#if canImport(SwiftUI)
import SwiftUI

/// Continent on the left, cities on the right, both multi-select.
///
/// Everything on offer is derived from the current results, so you can't pick a
/// place that would return nothing, and each row says how many roles it holds.
struct PlaceFilter: View {

    @Bindable var model: AppModel
    @State private var citySearch = ""

    private var continents: [(name: String, count: Int)] { model.availableContinents }

    private var cities: [(name: String, country: String, count: Int)] {
        let all = model.availableCities
        guard !citySearch.isEmpty else { return all }
        let needle = citySearch.lowercased()
        return all.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        HStack(spacing: 0) {
            continentColumn
            Divider()
            cityColumn
        }
        .frame(width: 520, height: 380)
    }

    // MARK: - Continents

    private var continentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("Continent", selected: model.continentFilter.count,
                         total: continents.count,
                         selectAll: { model.continentFilter = Set(continents.map(\.name)) },
                         clear: { model.continentFilter = []; model.cityFilter = [] })

            List {
                ForEach(continents, id: \.name) { entry in
                    row(title: entry.name,
                        subtitle: nil,
                        count: entry.count,
                        isOn: model.continentFilter.contains(entry.name)) {
                        model.toggleContinent(entry.name)
                    }
                }
            }
            .listStyle(.plain)

            if continents.isEmpty {
                hint("Scrape first — ⌘R")
            } else if model.citiesOverrideContinents {
                hint("Narrowing the city list only — your chosen cities are "
                     + "doing the filtering.")
            }
        }
        .frame(width: 210)
    }

    // MARK: - Cities

    private var cityColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader(model.continentFilter.isEmpty ? "City" : "City in region",
                         selected: model.cityFilter.count,
                         total: cities.count,
                         selectAll: { model.cityFilter = Set(cities.map(\.name)) },
                         clear: { model.cityFilter = [] })

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Find a city", text: $citySearch)
                    .textFieldStyle(.plain)
                if !citySearch.isEmpty {
                    Button { citySearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            List {
                ForEach(cities, id: \.name) { entry in
                    row(title: entry.name,
                        subtitle: entry.country,
                        count: entry.count,
                        isOn: model.cityFilter.contains(entry.name)) {
                        model.toggleCity(entry.name)
                    }
                }
            }
            .listStyle(.plain)

            if cities.isEmpty && !citySearch.isEmpty { hint("No city matches that.") }
        }
    }

    // MARK: - Pieces

    private func columnHeader(_ title: String, selected: Int, total: Int,
                              selectAll: @escaping () -> Void,
                              clear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if selected > 0 {
                Text("\(selected)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.tint, in: .capsule)
                    .foregroundStyle(.white)
            }
            Spacer()
            Button("All", action: selectAll)
                .disabled(total == 0 || selected == total)
            Button("None", action: clear)
                .disabled(selected == 0)
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func row(title: String, subtitle: String?, count: Int,
                     isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint)
                                          : AnyShapeStyle(.secondary))
                Text(title).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }
}
#endif
