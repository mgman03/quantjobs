import SwiftUI
import AppKit

/// The board manager: which firms get scraped, plus the two tools that make
/// adding one bearable — verify and discover.
struct CompaniesView: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<Company.ID> = []
    @State private var editing: EditTarget?
    @State private var showingVerify = false
    @State private var showingDiscover = false
    @State private var boardSearch = ""

    @State private var tierFilter: Int? = nil

    /// The rows on screen: tier first, then name, after search and tier filter.
    private var shown: [Company] {
        var out = model.companies
        if let tierFilter { out = out.filter { $0.tier == tierFilter } }
        if !boardSearch.isEmpty {
            let needle = boardSearch.lowercased()
            out = out.filter {
                $0.name.lowercased().contains(needle)
                    || $0.identifier.lowercased().contains(needle)
                    || $0.tags.contains { $0.contains(needle) }
            }
        }
        return out.sorted {
            $0.tier == $1.tier
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.tier < $1.tier
        }
    }

    /// Bound to the model by id, so the checkbox writes a value instead of
    /// flipping whatever it happens to be looking at.
    private func enabledBinding(_ company: Company) -> Binding<Bool> {
        Binding(
            get: { model.companies.first { $0.id == company.id }?.enabled ?? false },
            set: { model.setEnabled($0, for: company.id) })
    }

    private var targetIDs: [Company.ID] {
        selection.isEmpty ? shown.map(\.id) : Array(selection)
    }

    /// Wraps the company being edited so `.sheet(item:)` can drive the form,
    /// with nil `original` meaning "this one is new".
    struct EditTarget: Identifiable {
        var company: Company
        var original: String?
        var id: String { original ?? "new" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(width: 720, height: 460)
        .sheet(item: $editing) { target in
            CompanyEditor(company: target.company, original: target.original) { saved in
                model.upsert(saved, replacing: target.original)
            }
        }
        .sheet(isPresented: $showingVerify) { VerifyView(model: model) }
        .sheet(isPresented: $showingDiscover) {
            DiscoverView { hit, name in
                model.upsert(hit.company(named: name), replacing: nil)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Job Boards").font(.headline)
                Spacer()
                Text(ConfigStore.directory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.head)
                    .lineLimit(1)
                    .help("companies.json and categories.json live here")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a board", text: $boardSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Picker("", selection: $tierFilter) {
                    Text("All tiers").tag(Int?.none)
                    Text("Tier 1").tag(Int?.some(1))
                    Text("Tier 2").tag(Int?.some(2))
                    Text("Tier 3").tag(Int?.some(3))
                }
                .labelsHidden()
                .frame(width: 110)
                .help("Tier 1 is the names people target first; tier 3 ships off")

                Divider().frame(height: 16)

                // These act on what's on screen straight away. "Select All"
                // used to only highlight rows, leaving you to hunt for a second
                // menu to actually switch anything on.
                Text(selection.isEmpty ? "\(shown.count) shown:"
                                       : "\(selection.count) selected:")
                    .foregroundStyle(.secondary)
                Button("Turn On") { model.setEnabled(true, for: targetIDs) }
                Button("Turn Off") { model.setEnabled(false, for: targetIDs) }
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 16)

                Menu {
                    Section("Presets — replaces the whole selection") {
                        Button("Only Tier 1") { onlyTier(1) }
                        Button("Tier 1 + 2 (default)") { onlyTier(2) }
                        Button("Only Quant") { onlyGroup("quant") }
                        Button("Only Big Tech") { onlyGroup("bigtech") }
                        Button("Everything On") {
                            model.setEnabled(true, for: model.companies.map(\.id))
                        }
                    }
                } label: {
                    Label("Presets", systemImage: "checklist")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
            }
            .font(.callout)
        }
        .padding(12)
    }

    /// Turn one group on and everything else off, in a single pass.
    private func onlyGroup(_ group: String) {
        model.setEnabled(true, for: model.ids(inGroup: group))
        let others = model.companies
            .filter { !$0.tags.contains(group) }.map(\.id)
        model.setEnabled(false, for: others)
    }

    /// Everything up to and including `tier` on, the rest off.
    private func onlyTier(_ tier: Int) {
        model.setEnabled(true, for: model.companies.filter { $0.tier <= tier }.map(\.id))
        model.setEnabled(false, for: model.companies.filter { $0.tier > tier }.map(\.id))
    }

    private var table: some View {
        Table(shown, selection: $selection) {
            TableColumn("On") { company in
                Toggle("", isOn: enabledBinding(company))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!company.isConfigured)
                    .help(company.isConfigured ? "Scrape this board"
                                               : "Needs configuring before it can run")
            }
            .width(32)

            TableColumn("Tier") { company in
                Text("\(company.tier)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(company.tier == 1 ? AnyShapeStyle(.tint)
                                                       : AnyShapeStyle(.secondary))
                    .help(company.tierLabel)
            }
            .width(30)

            TableColumn("Firm", value: \.name)
                .width(min: 120, ideal: 170)

            TableColumn("ATS") { Text($0.ats.label) }
                .width(min: 90, ideal: 110)

            TableColumn("Board") { company in
                Text(company.identifier.isEmpty ? "—" : company.identifier)
                    .foregroundStyle(company.isConfigured ? Color.secondary : Color.orange)
                    .help(company.isConfigured ? company.identifier
                                               : "Missing configuration for this ATS")
            }
            .width(min: 120, ideal: 200)

            TableColumn("Tags") { Text($0.tags.joined(separator: ", ")) }
                .width(min: 80, ideal: 130)
        }
        .contextMenu(forSelectionType: Company.ID.self) { ids in
            if ids.count > 1 {
                Button("Turn On \(ids.count) Boards") { model.setEnabled(true, for: ids) }
                Button("Turn Off \(ids.count) Boards") { model.setEnabled(false, for: ids) }
                Divider()
                Button("Delete \(ids.count) Boards", role: .destructive) {
                    for id in ids { if let c = company(id) { model.delete(c) } }
                }
            } else if let id = ids.first, let company = company(id) {
                Button("Edit…") { editing = EditTarget(company: company, original: company.name) }
                Button(company.enabled ? "Turn Off" : "Turn On") {
                    model.setEnabled(!company.enabled, for: company.id)
                }
                .disabled(!company.isConfigured)
                Button("Delete", role: .destructive) { model.delete(company) }
                if let note = company.note, !note.isEmpty {
                    Divider()
                    Text(note)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let company = company(id) {
                editing = EditTarget(company: company, original: company.name)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                editing = EditTarget(company: Company(name: "", ats: .greenhouse),
                                     original: nil)
            } label: {
                Label("Add", systemImage: "plus")
            }

            Button {
                for id in selection { if let c = company(id) { model.delete(c) } }
                selection = []
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selection.isEmpty)

            Divider().frame(height: 16)

            Button("Verify…") { showingVerify = true }
            Button("Discover…") { showingDiscover = true }

            Spacer()

            if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Text("\(model.companies.filter(\.enabled).count) of \(model.companies.count) on")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func company(_ id: Company.ID) -> Company? {
        model.companies.first { $0.id == id }
    }
}

// MARK: - Editor

struct CompanyEditor: View {

    @State var company: Company
    let original: String?
    let onSave: (Company) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Firm", text: $company.name)

                Picker("Job board", selection: $company.ats) {
                    ForEach(ATS.allCases) { Text($0.label).tag($0) }
                }

                switch company.ats.configStyle {
                case .token:
                    TextField("Board slug", text: Binding(
                        get: { company.token ?? "" },
                        set: { company.token = $0 }))
                    .help("The identifier in the board URL, e.g. boards.greenhouse.io/<slug>")

                case .workday:
                    TextField("Host", text: Binding(
                        get: { company.host ?? "" }, set: { company.host = $0 }))
                    .help("tenant.wdN.myworkdayjobs.com")
                    TextField("Tenant", text: Binding(
                        get: { company.tenant ?? "" }, set: { company.tenant = $0 }))
                    TextField("Site", text: Binding(
                        get: { company.site ?? "" }, set: { company.site = $0 }))
                    .help("Usually External or a careers-site name")

                case .query:
                    TextField("Search terms", text: Binding(
                        get: { company.query ?? "" }, set: { company.query = $0 }),
                        prompt: Text("intern"))
                    .help("This board is one big search index; these terms narrow "
                          + "it before the category filter runs.")
                }

                TextField("Tags", text: $tagText)
                    .help("Comma separated, e.g. hft, prop, london")

                Toggle("Scrape this board", isOn: $company.enabled)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    company.tags = tagText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onSave(company)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(company.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || !company.isConfigured)
            }
            .padding(12)
        }
        .frame(width: 420)
        .onAppear { tagText = company.tags.joined(separator: ", ") }
    }
}

// MARK: - Verify

struct VerifyView: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeDisabled = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Board Check").font(.headline)
                Spacer()
                Toggle("Include disabled", isOn: $includeDisabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(12)

            Divider()

            List(model.verifyResults) { result in
                HStack(spacing: 8) {
                    Image(systemName: result.ok ? "checkmark.circle.fill"
                                                : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                    Text(result.company).bold()
                    Text("\(result.ats.label)/\(result.identifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(result.ok ? "\(result.count) roles" : (result.failure ?? ""))
                        .font(.caption)
                        .foregroundStyle(result.ok ? Color.secondary : Color.red)
                }
            }

            Divider()

            HStack {
                if model.isVerifying { ProgressView().controlSize(.small) }
                let broken = model.verifyResults.filter { !$0.ok }.count
                Text(model.isVerifying
                     ? "Checking…"
                     : "\(model.verifyResults.count - broken) working, \(broken) broken")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Run") { model.verify(includeDisabled: includeDisabled) }
                    .disabled(model.isVerifying)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 420)
        .onAppear { model.verify(includeDisabled: includeDisabled) }
    }
}

// MARK: - Discover

struct DiscoverView: View {

    let onAdd: (Discovery.Hit, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var hits: [Discovery.Hit] = []
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Find a Board").font(.headline)
                Text("Point this at a firm's careers page and it'll sniff out the "
                     + "job-board token hiding in the page source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("https://firm.com/careers", text: $urlText)
                        .onSubmit(run)
                    Button("Search", action: run)
                        .disabled(busy || urlText.isEmpty)
                }
            }
            .padding(12)

            Divider()

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List(hits) { hit in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.token).bold()
                        Text(hit.ats.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add") {
                        onAdd(hit, suggestedName)
                        dismiss()
                    }
                }
                .help(hit.snippet)
            }

            Divider()

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 400)
    }

    /// "https://www.headlandstech.com/careers" → "Headlandstech"
    private var suggestedName: String {
        guard let host = URL(string: urlText)?.host() else { return "New Firm" }
        let core = host.replacingOccurrences(of: "www.", with: "")
            .split(separator: ".").first.map(String.init) ?? host
        return core.capitalized
    }

    private func run() {
        busy = true
        status = nil
        hits = []
        Task {
            do {
                let found = try await Discovery.run(urlText)
                hits = found
                if found.isEmpty {
                    status = "No board fingerprint in the raw HTML — the careers page "
                        + "is probably rendered client-side. Open it in a browser, check "
                        + "DevTools → Network → Fetch/XHR, and look for a JSON request."
                }
            } catch {
                let reason = (error as? FetchError)?.errorDescription
                    ?? error.localizedDescription
                status = "Couldn't fetch that page: \(reason)."
                    + (reason.contains("403")
                       ? " The site is blocking scripted requests; try View Source by hand."
                       : "")
            }
            busy = false
        }
    }
}

extension Discovery.Hit {
    func company(named name: String) -> Company {
        ats == .workday
            ? Company(name: name, ats: .workday, host: token, tenant: "", site: "External",
                      enabled: false, note: "Fill in tenant before enabling")
            : Company(name: name, ats: ats, token: token, enabled: true)
    }
}
