import SwiftUI

/// Read-only: where the results came from.
///
/// Choosing *which* firms to scrape now lives in the sidebar tree, so this is
/// purely "what am I looking at" — platforms, counts, and anything that failed.
/// Nothing here changes state.
struct SourcesView: View {

    let model: AppModel

    private var live: [Company] { model.selectedFirms }

    /// Boards grouped by the platform they're served from.
    private var byPlatform: [(ats: ATS, firms: [Company])] {
        Dictionary(grouping: live, by: \.ats)
            .map { (ats: $0.key, firms: $0.value.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending }) }
            .sorted { $0.firms.count == $1.firms.count
                ? $0.ats.label < $1.ats.label
                : $0.firms.count > $1.firms.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.failures.isEmpty { failureBlock }

                    ForEach(byPlatform, id: \.ats) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(entry.ats.label)
                                    .font(.callout.weight(.semibold))
                                Text("\(entry.firms.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.firms.map(\.displayName).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Config").font(.caption.weight(.semibold))
                        Text(ConfigStore.directory.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 380, height: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Where this data comes from").font(.headline)
            Text("\(live.count) boards · \(byPlatform.count) platforms"
                 + (model.lastRun == nil ? "" : " · \(model.cacheAgeDescription ?? "")"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Pick which firms to scrape in the Firms list on the left.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    private var failureBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(model.failures.count) didn't answer last run",
                  systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(model.failures) { failure in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(failure.company)
                    Text(failure.reason).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Divider()
        }
    }
}
