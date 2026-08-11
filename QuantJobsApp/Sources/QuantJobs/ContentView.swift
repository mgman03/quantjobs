import SwiftUI
import AppKit

struct ContentView: View {

    @Bindable var model: AppModel

    @State private var sortOrder = [KeyPathComparator(\Job.posted, order: .reverse)]
    @State private var selection: Set<Job.ID> = []
    /// Which columns are showing. Only Progress is driven from here, and only
    /// because it's meaningless outside the Applied list.
    @State private var columns = TableColumnCustomization<Job>()
    @State private var showingFailures = false
    @State private var showingSources = false

    private static let defaultSort = [KeyPathComparator(\Job.posted, order: .reverse)]

    private var rows: [Job] {
        // The default ordering already puts undated roles last; only re-sort
        // once the user has actually clicked a column header.
        sortOrder == Self.defaultSort
            ? model.visibleJobs
            : model.visibleJobs.sorted(using: sortOrder)
    }

    private var selectedJob: Job? {
        guard let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            let rows = rows
            HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let error = model.loadError { banner(error) }
                updateBanner
                if model.loadStalled && !model.isLoaded {
                    banner("macOS is asking whether QuantJobs may read "
                           + "\(ConfigStore.directory.lastPathComponent). Click Allow "
                           + "in that dialog — the board list stays empty until you do. "
                           + "(Rebuilding the app re-signs it, so it asks again.)")
                }
                if model.list == .results {
                    FilterBar(model: model)
                    if model.hiddenInResults > 0 || model.showHidden { hiddenBar }
                } else {
                    listBar
                }
                Divider()
                jobTable(rows)
                Divider()
                statusBar(rows)
            }
            .frame(maxWidth: .infinity)

            // A plain pane rather than .inspector. Inside the detail column,
            // attached to the split view, fixed width, flexible width — every
            // arrangement of .inspector inside a NavigationSplitView added its
            // width to the window instead of taking it out of the table, so the
            // columns totalled more than the window and overflowed at both
            // ends: the sidebar lost its icons and the leading characters of
            // its headings, the panel lost the end of its own title. An HStack
            // can't do that, because the table simply gets what's left.
            //
            // Purely selection-driven: pick a row and it appears, close it and
            // the row deselects.
            if selectedJob != nil {
                Divider()
                JobDetail(job: selectedJob, model: model)
                    // Fresh note state whenever the selection changes.
                    .id(selectedJob?.id)
                    // Flexible, not fixed: at 300 exactly, a narrow window had
                    // nowhere left to take space from and clipped the sidebar.
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 320)
            }
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showBoardEditor) {
            CompaniesView(model: model)
        }
        // Deliberately inside ContentView rather than wrapped around it in
        // App.swift. SwiftUI derives a window's autosave name from its view
        // type, so wrapping ContentView in .onReceive renamed the window and
        // orphaned the saved size and position.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadCompaniesIfChangedOnDisk()
        }
        .onChange(of: model.list, initial: true) {
            columns[visibility: "progress"] = model.list == .applied ? .visible : .hidden
        }
        .onChange(of: model.settingsFingerprint) { model.persistSettings() }
        .onChange(of: model.refreshFingerprint) { model.scheduleRefresh() }
        .task {
            // Deliberately after the window is up: the first read of the config
            // folder can trigger a macOS permission prompt.
            if !model.isLoaded { await model.reload() }
            await model.updater.checkOnLaunch()
            // Refresh on open only when the cache is stale — otherwise the
            // window comes up instantly on last run's results and waits for ⌘R.
            if model.lastRun == nil && model.shouldRefreshOnLaunch { model.scrape() }
        }
    }

    // MARK: - Sidebar

    /// One selection for the whole sidebar. Lists and categories used to carry
    /// separate highlights, which left two rows looking selected at once.
    private var sidebarSelection: Binding<String?> {
        Binding(
            get: {
                model.list == .results
                    ? "cat.\(model.selectedCategoryID)"
                    : "list.\(model.list.rawValue)"
            },
            set: { raw in
                guard let raw else { return }
                if let name = raw.dropPrefixIfPresent("list.") {
                    model.list = AppModel.JobList(rawValue: name) ?? .results
                } else if let name = raw.dropPrefixIfPresent("cat.") {
                    model.list = .results
                    model.selectedCategoryID = name
                }
            })
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            // `.results` deliberately absent: it isn't a list, it's the mode
            // you're in when a category is selected — and the Everything
            // category already means "all roles", so a row for it read as a
            // second, subtly different way to ask for the same thing.
            Section("Lists") {
                ForEach(AppModel.JobList.pickable) { entry in
                    HStack(spacing: 6) {
                        Label(entry.title, systemImage: entry.symbol)
                        Spacer()
                        if let status = entry.status, model.count(status) > 0 {
                            // Same capsule as the stage-section counts and the
                            // Level tag: one treatment for "a small number that
                            // labels a thing", used everywhere.
                            Text("\(model.count(status))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary.opacity(0.6), in: .capsule)
                        }
                    }
                    .tag("list.\(entry.rawValue)")
                }
            }

            Section("Category") {
                // Sub-categories sit indented under their parent — they're slices
                // of it, not peers, and reading them as siblings of "Software
                // Engineering" made "Python" look like a discipline of its own.
                // Disciplines only. cpp/python/frontend describe a stack rather
                // than a place to navigate to — as nav they were exclusive, so
                // choosing one threw away the 87% of roles that name no language.
                // They're an additive filter in the row above instead.
                ForEach(model.navCategories) { category in
                    Label(category.displayName, systemImage: category.symbol)
                        .tag("cat.\(category.name)")
                }
            }

        }
        // Opening the inspector squeezes this column below its stated width,
        // and the List keeps its own width inside it and centres — so both
        // edges clip and "Category" renders as "gory". Pinning the content to
        // the leading edge and letting it actually shrink is what stops it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationSplitViewColumnWidth(min: 180, ideal: 224, max: 280)
        .safeAreaInset(edge: .bottom) {
            // Just context for the selected category now — choosing firms is
            // the tree above, and "where's this from" moved to the status bar.
            if model.list == .results,
               let description = model.selectedCategory?.description {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    /// Sits above the results rather than in a modal: an update is worth
    /// mentioning, not worth interrupting a search for.
    @ViewBuilder
    private var updateBanner: some View {
        switch model.updater.phase {
        case .available(let release) where !model.updater.dismissed:
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("QuantJobs \(release.version) is available.")
                    .font(.callout)
                Link("What's new", destination: release.page)
                    .font(.caption)
                Spacer()
                Button("Update") {
                    Task { await model.updater.install(release) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    model.updater.dismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Not now")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.tint.opacity(0.10))

        case .busy(let what):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(what).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.tint.opacity(0.10))

        case .failed(let why):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Update failed — \(why)").font(.callout)
                Spacer()
                Button("Dismiss") { model.updater.clear() }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.orange.opacity(0.10))

        case .upToDate:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("You're on the latest version (\(Updater.currentVersion)).")
                    .font(.callout)
                Spacer()
                Button("Dismiss") { model.updater.clear() }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

        // Idle, mid-check, or an update the user waved away.
        default:
            EmptyView()
        }
    }

    private func banner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.18))
    }

    // MARK: - Filter bar

    /// The strip that appears once anything is hidden, so hidden roles are
    /// never silently missing from a count.
    private var hiddenBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            // "postings", not "roles": this counts what the filter holds back,
            // which is postings, while the sidebar badge counts the rows the
            // Hidden list will show. A role posted in four cities is four of the
            // first and one of the second, and two different numbers labelled
            // the same way on one screen reads as a bug.
            Text(model.showHidden
                 ? "Showing hidden postings"
                 : "\(model.hiddenInResults) hidden "
                   + (model.hiddenInResults == 1 ? "posting" : "postings"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(model.showHidden ? "Hide Them Again" : "Show Hidden") {
                model.showHidden.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }

    /// Header for the saved / applied / hidden lists.
    private var listBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.list.symbol)
            Text(model.list.title).font(.headline)
            Text("kept even after a board takes the posting down")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            SearchField(model: model)
            Button("Back to Results") { model.list = .results }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Table

    /// A foldable heading for one stage of the Applied list. The whole row is
    /// the hit target, since a chevron alone is a small thing to aim at.
    private func stageHeader(_ group: AppModel.StageGroup) -> some View {
        let collapsed = model.isCollapsed(group.stage)
        return Button {
            model.toggleCollapsed(group.stage)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: group.stage.symbol)
                    .font(.caption)
                    .foregroundStyle(group.stage.tint)
                Text(group.stage.label)
                    .font(.callout.weight(.medium))
                Text("\(group.jobs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.6), in: .capsule)
                if collapsed, let oldest = group.jobs
                    .compactMap({ model.trackedEntry(for: $0)?.lastActivity })
                    .min(), let age = Dates.relative(oldest) {
                    // Folded, the useful thing to still say is how long the
                    // stalest one has been sitting there.
                    Text("oldest \(age)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The columns, lifted out of the Table so both the flat and the
    /// stage-sectioned row builders can share one definition.
    @TableColumnBuilder<Job, KeyPathComparator<Job>>
    private var jobColumns: some TableColumnContent<Job, KeyPathComparator<Job>> {
            // One column for the row actions. Four separate icon columns left
            // four empty header cells and a row of stray dividers.
            TableColumn("") { job in
                HStack(spacing: 7) {
                    Circle()
                        .fill(job.isNew ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                        .frame(width: 6, height: 6)
                        .help(job.isNew ? "Not seen on a previous run" : "")

                    Button { model.setSaved(!model.isSaved(job), for: [job]) } label: {
                        let on = model.isSaved(job)
                        Image(systemName: on ? "star.fill" : "star")
                            .foregroundStyle(on ? AnyShapeStyle(.tint)
                                                : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isSaved(job) ? "Saved" : "Save")
                    .help("Save this role")

                    // A plain Button, not a Menu. A Menu builds its content per
                    // row, and at "All levels" across 54 boards that is tens of
                    // thousands of menus — a `sample` of the spinning app was
                    // entirely inside this column's cells. Choosing a *stage*
                    // lives in the detail panel and the right-click menu; the
                    // row only starts an application, and once one exists the
                    // button goes inert so a stray click can't discard it.
                    let tracked = model.hasApplication(job)
                    Button {
                        if !tracked { model.record(.applied, for: [job]) }
                    } label: {
                        Image(systemName: tracked ? "paperplane.fill" : "paperplane")
                            .foregroundStyle(tracked ? AnyShapeStyle(Color.accentColor)
                                                     : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(tracked)
                    .accessibilityLabel(tracked ? "Application tracked" : "Mark applied")
                    .help(tracked ? "Applied — the detail panel records the stages"
                                  : "Mark as applied today")

                    Button { model.setHidden(!model.isHidden(job), for: [job]) } label: {
                        let on = model.isHidden(job)
                        Image(systemName: on ? "eye.slash.fill" : "eye.slash")
                            .foregroundStyle(on ? AnyShapeStyle(.secondary)
                                                : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isHidden(job) ? "Unhide" : "Hide")
                    .help(model.isHidden(job)
                          ? "Unhide — an application here is kept either way"
                          : "Hide this role")
                }
            }
            .width(84)

            // Hidden outside the Applied list, where every row has one —
            // elsewhere it was a column of "–" taking width from Role, which is
            // the column people read. Done through column customization rather
            // than an `if` in the builder: conditional TableColumns need macOS
            // 14.4 and this ships for 14.0.
            TableColumn("Progress") { job in
                if let entry = model.trackedEntry(for: job), entry.hasApplication {
                    StagePill(entry: entry)
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            // Capped so the table can't hand it all the slack — in the results
            // list, where most rows are untracked, that was 200pt of "–" sitting
            // between the icons and the company name. But wide enough for the
            // widest pill it has to hold, "✈ Applied today": at 104 the Applied
            // list rendered "App... to...", truncated twice over.
            .width(min: 84, ideal: 136, max: 168)
            .customizationID("progress")

            TableColumn("Company", value: \.company) { job in
                HStack(spacing: 5) {
                    Image(systemName: job.tags.contains("bigtech")
                          ? "cube.transparent" : "chart.xyaxis.line")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(job.tags.contains("bigtech") ? "Big Tech" : "Quant")
                    Text(job.company)
                }
                .foregroundStyle(model.isDelisted(job) ? .tertiary : .secondary)
            }
            .width(min: 74, ideal: 116)

            TableColumn("Role", value: \.shortTitle) { job in
                HStack(spacing: 5) {
                    Text(job.shortTitle)
                        // The one thing at full weight and full contrast: this
                        // is the column people actually read down.
                        .fontWeight(.medium)
                        .foregroundStyle(model.isDelisted(job) ? .secondary : .primary)
                        .strikethrough(model.isDelisted(job), color: .secondary)
                    if model.isDelisted(job) {
                        Image(systemName: "xmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("No longer listed on the board")
                    }
                }
                .help(job.title)      // the full posted title on hover
            }
            .width(min: 120, ideal: 230)

            TableColumn("Location", value: \.locationDisplay) { job in
                Text(job.locationDisplay)
                    .foregroundStyle(.secondary)
                    .help(job.places.count > 1
                          ? job.places.map(\.label).joined(separator: " · ")
                          : job.location)
            }
            .width(min: 84, ideal: 128)

            TableColumn("Level", value: \.level) { job in
                if job.levelShort.isEmpty {
                    Text("–").foregroundStyle(.tertiary)
                } else {
                    // A tag, not a word. The table already speaks in capsules —
                    // the Progress pill, the stage-section counts — so this joins
                    // that language instead of being a third treatment for a
                    // short fixed value.
                    HStack(spacing: 3) {
                        Text(job.levelShort)
                        // The intake, when the posting names one. Two digits: the
                        // column is 66pt and "Intern 2027" doesn't fit, while a
                        // stale cycle showing '26 next to '27 is the whole point.
                        if let year = job.intakeYear {
                            Text("'\(String(year).suffix(2))")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                }
            }
            .width(66)

            // Fixed, not a range: a squeezed table was shrinking this below a
            // full date and showing "2026-07".
            TableColumn("Posted", value: \.effectiveDate) { job in
                if let age = Dates.compact(job.effectiveDate) {
                    // Fresh postings earn the accent. What you scan this column
                    // for is what turned up recently, and an ISO date makes you
                    // do that arithmetic yourself — it's on hover instead.
                    let days = Dates.days(since: job.effectiveDate) ?? 99
                    HStack(spacing: 2) {
                        // A tilde where the date is ours rather than the board's:
                        // the number means "no older than this", not "posted then".
                        if job.dateIsInferred {
                            Text("~").foregroundStyle(.tertiary)
                        }
                        Text(age)
                            .monospacedDigit()
                            .foregroundStyle(days <= 3 ? AnyShapeStyle(.tint)
                                                       : AnyShapeStyle(.secondary))
                    }
                    .help(job.dateIsInferred
                          ? "This board states no date — first seen \(job.firstSeen)"
                          : job.posted)
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .width(66)
    }

    private func jobTable(_ rows: [Job]) -> some View {
        Table(of: Job.self, selection: $selection, sortOrder: $sortOrder,
              columnCustomization: $columns) {
            jobColumns
        } rows: {
            if model.list == .applied {
                // One block per stage, foldable, so the list can be narrowed to
                // whatever you're actually waiting on.
                ForEach(model.appliedGroups) { group in
                    Section {
                        if !model.isCollapsed(group.stage) {
                            ForEach(group.jobs) { TableRow($0) }
                        }
                    } header: {
                        stageHeader(group)
                    }
                }
            } else {
                ForEach(rows) { TableRow($0) }
            }
        }
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            let picked = selected(ids, in: rows)
            Button("Open in Browser") { open(ids) }
            Button("Copy Link") { copyLinks(ids) }
            Divider()
            let saved = !picked.isEmpty && picked.allSatisfy(model.isSaved)
            Button(saved ? "Unsave" : "Save") {
                model.setSaved(!saved, for: picked)
            }
            let hidden = !picked.isEmpty && picked.allSatisfy(model.isHidden)
            Button(hidden ? "Unhide" : "Hide") {
                model.setHidden(!hidden, for: picked)
            }
            Menu("Application") {
                ForEach(Stage.allCases) { stage in
                    Button {
                        // Recording a later step on its own would leave a
                        // pipeline with no start; everything implies applying.
                        if stage != .applied { model.record(.applied, for: picked) }
                        model.record(stage, for: picked)
                    } label: {
                        Label("\(stage.label) Today", systemImage: stage.symbol)
                    }
                }
                if picked.contains(where: model.hasApplication) {
                    Divider()
                    Button("Clear Progress", role: .destructive) {
                        model.clearApplication(for: picked)
                    }
                }
            }
            .disabled(picked.isEmpty)
            if picked.contains(where: { model.trackedEntry(for: $0) != nil }) {
                Divider()
                Button("Clear All Marks", role: .destructive) {
                    model.clearAll(for: picked)
                }
            }
            if let firm = picked.first?.company,
               picked.allSatisfy({ $0.company == firm }) {
                Divider()
                Button("Not Interested in \(firm)", role: .destructive) {
                    model.dismissCompany(named: firm)
                }
            }
        } primaryAction: { ids in
            open(ids)
        }
        .overlay {
            if rows.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.isScraping ? "Scraping…" : "No roles yet",
                  systemImage: model.isScraping ? "arrow.trianglehead.2.clockwise" : "tray")
        } description: {
            if model.isScraping {
                Text("\(model.scanned) of \(model.total) boards")
            } else if !model.isLoaded {
                Text("Loading the board list…")
            } else if model.lastRun == nil {
                Text("Pick a category, then press ⌘R.")
            } else if model.hasExtraFilters {
                Text("Nothing matched. Try clearing a filter.")
            } else {
                Text("Nothing matched. Try a wider level, or turn on deep matching.")
            }
        }
    }

    // MARK: - Status bar

    private func statusBar(_ rows: [Job]) -> some View {
        HStack(spacing: 12) {
            if model.isScraping {
                ProgressView(value: Double(model.scanned), total: Double(max(model.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                Text("\(model.scanned)/\(model.total) boards")
            } else {
                HStack(spacing: 4) {
                    Text("\(rows.count)").fontWeight(.medium)
                    Text("roles").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.quaternary)
                    Text("\(Set(rows.map(\.company)).count)").fontWeight(.medium)
                    Text("firms").foregroundStyle(.secondary)
                }
                .monospacedDigit()
                if model.showingCache, let when = model.cacheDate {
                    Label {
                        Text("from \(when, format: .relative(presentation: .numeric))")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(.secondary)
                }
                if model.visibleNewCount > 0 || model.newOnly {
                    Button {
                        model.newOnly.toggle()
                    } label: {
                        Label(model.newOnly ? "showing new only"
                                            : "\(model.visibleNewCount) new",
                              systemImage: model.newOnly ? "sparkles.rectangle.stack.fill"
                                                         : "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("Show only roles you haven't seen before")
                }
            }

            Spacer()

            if !model.failures.isEmpty {
                Button {
                    showingFailures.toggle()
                } label: {
                    Label("\(model.failures.count) failed",
                          systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .popover(isPresented: $showingFailures, arrowEdge: .top) {
                    failureList
                }
            }

            Button {
                showingSources.toggle()
            } label: {
                Label("\(model.selectedFirms.count) sources", systemImage: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showingSources, arrowEdge: .top) {
                SourcesView(model: model)
            }
            .help("Which boards these results came from")

            if let lastRun = model.lastRun {
                Text("checked \(lastRun, format: .dateTime.hour().minute())")
                    .foregroundStyle(.secondary)
                    .help("When the boards were last fetched")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Boards that didn't answer").font(.headline)
            ForEach(model.failures) { failure in
                HStack {
                    Text(failure.company).bold()
                    Text(failure.reason).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(minWidth: 260)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                ForEach(AppModel.ExportFormat.allCases) { format in
                    Button(format.label) { export(format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.visibleJobs.isEmpty)
        }

        ToolbarItem {
            Button {
                model.isScraping ? model.cancel() : model.scrape(full: true)
            } label: {
                Label(model.isScraping ? "Stop" : "Scrape",
                      systemImage: model.isScraping ? "stop.fill" : "arrow.clockwise")
            }
            .keyboardShortcut("r")
        }

        ToolbarItem {
            Button {
                selection.removeAll()
            } label: {
                Label("Close Details", systemImage: "sidebar.trailing")
            }
            .disabled(selectedJob == nil)
            .help("Close the detail panel")
        }
    }

    // MARK: - Actions

    private func selected(_ ids: Set<Job.ID>, in rows: [Job]) -> [Job] {
        rows.filter { ids.contains($0.id) }
    }

    private func urls(for ids: Set<Job.ID>) -> [URL] {
        rows.filter { ids.contains($0.id) }
            .compactMap { URL(string: $0.url) }
    }

    private func open(_ ids: Set<Job.ID>) {
        for url in urls(for: ids) { NSWorkspace.shared.open(url) }
    }

    private func copyLinks(_ ids: Set<Job.ID>) {
        let text = urls(for: ids).map(\.absoluteString).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ format: AppModel.ExportFormat) {
        let panel = NSSavePanel()
        let category = model.selectedCategory?.name ?? "roles"
        panel.nameFieldStringValue = "\(category)-\(model.level.rawValue).\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.exportText(format).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Detail panel

/// The right-hand inspector: everything the board told us about one posting.
struct JobDetail: View {

    let job: Job?
    let model: AppModel

    var body: some View {
        if let job {
            ScrollView {
                JobDetailContent(
                    job: job,
                    tracking: model.trackedEntry(for: job),
                    onToggle: { model.toggleStatus($0, for: [job]) },
                    onRecord: { model.record($0, on: $1, for: [job]) },
                    onRepeat: { model.record($0, on: $1, repeating: true, for: [job]) },
                    onRemove: { model.removeStage($0, for: [job]) },
                    onClear: { model.clearApplication(for: [job]) },
                    onSaveNote: { model.setNote($0, for: job) })
            }
        } else {
            ContentUnavailableView("No Role Selected",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Pick a row to see the details."))
        }
    }
}

/// Where an application has got to and how long ago, small enough for a table
/// cell: `OA · 5d`.
struct StagePill: View {

    let entry: TrackedJob

    var body: some View {
        if let stage = entry.stage {
            HStack(spacing: 4) {
                Image(systemName: stage.symbol).font(.system(size: 9))
                Text(stage.short)
                if let age = Dates.compact(entry.lastActivity) {
                    Text(age)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(stage.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: .capsule)
            .help(summary)
        }
    }

    private var summary: String {
        entry.milestones
            .map { "\($0.stage.label) \($0.relative ?? $0.date)" }
            .joined(separator: " · ")
    }
}

/// The application timeline: one row per step, dated, with a rail down the left
/// so the sequence reads as a sequence.
///
/// Vertical rather than a horizontal stepper because the panel is 300pt wide and
/// every step needs a date next to it — a stepper would have to drop them.
struct ApplicationTimeline: View {

    let entry: TrackedJob
    var onRecord: (Stage, String) -> Void = { _, _ in }
    var onRepeat: (Stage, String) -> Void = { _, _ in }
    var onRemove: (Stage) -> Void = { _ in }
    var onClear: () -> Void = {}

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 2: "2nd"
        case 3: "3rd"
        default: "\(n)th"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entry.milestones.enumerated()), id: \.element.id) { i, step in
                row(step, isLast: i == entry.milestones.count - 1)
            }
            addRow
        }
    }

    private func row(_ step: Milestone, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // The rail: a dot for this step, a line down to the next one.
            VStack(spacing: 0) {
                Image(systemName: step.stage.symbol)
                    .font(.system(size: 11))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(step.stage.tint)
                if !isLast || !step.stage.isClosed {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1)
                        .frame(minHeight: 14)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(step.stage.label).font(.callout)
                HStack(spacing: 5) {
                    Text(step.relative ?? step.date)
                    Text(step.date).foregroundStyle(.tertiary).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                // A date picker in a 300pt panel is more chrome than this
                // deserves; nudging is what correcting a date actually needs.
                Button("Move a Day Earlier") { shift(step, by: -1) }
                Button("Move a Day Later") { shift(step, by: 1) }
                Button("Set to Today") { onRecord(step.stage, Dates.today) }
                Divider()
                Button("Remove", role: .destructive) { onRemove(step.stage) }
            } label: {
                Image(systemName: "ellipsis").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.bottom, isLast ? 0 : 2)
    }

    private func shift(_ step: Milestone, by days: Int) {
        guard let date = Dates.date(step.date),
              let moved = Calendar.current.date(byAdding: .day, value: days, to: date)
        else { return }
        onRecord(step.stage, Dates.iso.string(from: moved))
    }

    private var addRow: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "plus")
                .font(.system(size: 10))
                .frame(width: 16, height: 16)
                .foregroundStyle(.tertiary)
            Menu {
                ForEach(entry.remainingStages) { stage in
                    Button {
                        onRecord(stage, Dates.today)
                    } label: {
                        Label(stage.label, systemImage: stage.symbol)
                    }
                }
                // A stage can happen twice — two online assessments is normal, and
                // recording the second used to just move the first one's date.
                let repeats = TrackedJob.repeatable.filter { entry.count(of: $0) > 0 }
                if !repeats.isEmpty {
                    Section("Again") {
                        ForEach(repeats) { stage in
                            Button {
                                onRepeat(stage, Dates.today)
                            } label: {
                                Label("\(ordinal(entry.count(of: stage) + 1)) "
                                      + stage.label.lowercased(),
                                      systemImage: stage.symbol)
                            }
                        }
                    }
                }
                Divider()
                Button("Clear Progress", role: .destructive) { onClear() }
            } label: {
                Text("Add a step").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// Split out from `JobDetail` so it can be rendered on its own — a ScrollView
/// has no intrinsic height, which makes the panel impossible to snapshot.
struct JobDetailContent: View {

    let job: Job
    let tracking: TrackedJob?
    var onToggle: (JobStatus) -> Void = { _ in }
    var onRecord: (Stage, String) -> Void = { _, _ in }
    var onRepeat: (Stage, String) -> Void = { _, _ in }
    var onRemove: (Stage) -> Void = { _ in }
    var onClear: () -> Void = {}
    var onSaveNote: (String) -> Void = { _ in }

    @State private var note: String

    /// Takes plain values rather than the model: a view that observes
    /// `@Observable` state never settles under ImageRenderer, and the note
    /// state has to be seeded in `init` rather than `onAppear` for the same
    /// reason. Being a dumb view is also just easier to reason about.
    init(job: Job, tracking: TrackedJob?,
         onToggle: @escaping (JobStatus) -> Void = { _ in },
         onRecord: @escaping (Stage, String) -> Void = { _, _ in },
         onRepeat: @escaping (Stage, String) -> Void = { _, _ in },
         onRemove: @escaping (Stage) -> Void = { _ in },
         onClear: @escaping () -> Void = {},
         onSaveNote: @escaping (String) -> Void = { _ in }) {
        self.job = job
        self.tracking = tracking
        self.onToggle = onToggle
        self.onRecord = onRecord
        self.onRepeat = onRepeat
        self.onRemove = onRemove
        self.onClear = onClear
        self.onSaveNote = onSaveNote
        _note = State(initialValue: tracking?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(job)
            statusButtons(job)
            if let entry = tracking, entry.hasApplication { applicationBlock(entry) }
            facts(job)
            if tracking != nil { trackingBlock(job) }
            if !job.tags.isEmpty { tagRow(job) }
            if !job.description.isEmpty { descriptionBlock(job) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The primary action and the three marks, on one row.
    ///
    /// The marks are icon-only. With labels — "Save", "Track Application",
    /// "Hide" — the row wanted about 330pt inside a 268pt panel, so macOS
    /// truncated each one to an ellipsis and the middle button swallowed the
    /// row. Three independent controls, because hiding a role you've applied to
    /// must not overwrite the application.
    /// The panel's actions, each saying what it does.
    ///
    /// They were icon-only, which is right in a table row where space is scarce and
    /// wrong here: the panel has room, and "what does the paperplane do" is not a
    /// question a detail view should leave open. The labels also state the *state* —
    /// "Unsave" when it's saved — so the button says what clicking it will do
    /// rather than what the role currently is.
    ///
    /// Open Posting is no longer full-width prominent. Stretched across the panel it
    /// read as the only thing here, dwarfing three controls that matter as much.
    private func statusButtons(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !job.isMerged, let url = URL(string: job.url) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open Posting", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }

            // One row when the labels fit, stacked when they don't — the panel is
            // as narrow as 250pt and three labelled buttons want about 330.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { actions(job) }
                VStack(alignment: .leading, spacing: 6) { actions(job) }
            }
        }
    }

    @ViewBuilder
    private func actions(_ job: Job) -> some View {
        let saved = tracking?.saved == true
        Button { onToggle(.favorite) } label: {
            Label(saved ? "Unsave" : "Save",
                  systemImage: saved ? "star.fill" : "star")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(saved ? .accentColor : nil)

        if tracking?.hasApplication == true {
            Menu {
                ForEach(tracking?.remainingStages ?? []) { stage in
                    Button {
                        onRecord(stage, Dates.today)
                    } label: {
                        Label(stage.label, systemImage: stage.symbol)
                    }
                }
            } label: {
                Label("Applied", systemImage: "paperplane.fill").font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .help("Pick the next step, or use the timeline below")
        } else {
            Menu {
                ForEach(Stage.allCases) { stage in
                    Button {
                        if stage != .applied { onRecord(.applied, Dates.today) }
                        onRecord(stage, Dates.today)
                    } label: {
                        Label(stage.label, systemImage: stage.symbol)
                    }
                }
            } label: {
                Label("Move to Applied", systemImage: "paperplane").font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .help("Record an application — Applied today, or a later stage if "
                  + "you're already past it")
        }

        let hidden = tracking?.hidden == true
        Button { onToggle(.hidden) } label: {
            Label(hidden ? "Unhide" : "Hide",
                  systemImage: hidden ? "eye.slash.fill" : "eye.slash")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(hidden ? .accentColor : nil)
        .help(hidden ? "Any application here is kept either way" : "")
    }

    private func applicationBlock(_ entry: TrackedJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Text("Application").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StagePill(entry: entry)
            }
            ApplicationTimeline(entry: entry, onRecord: onRecord,
                                onRepeat: onRepeat, onRemove: onRemove,
                                onClear: onClear)
            if entry.hidden {
                Label("Hidden from results — this history is kept regardless",
                      systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Just the note now — "Marked" said little the timeline doesn't say better,
    /// and "Last listed" moved up into the facts grid.
    private func trackingBlock(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            TextField("Notes", text: $note, axis: .vertical)
                .lineLimit(2...6)
                .font(.callout)
                .onSubmit { onSaveNote(note) }
            Button("Save Note") { onSaveNote(note) }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(note == (tracking?.note ?? ""))
        }
    }

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.linkUnverified {
                Label("Link not confirmed — this firm blocks automated checks, "
                      + "so the posting may have closed",
                      systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tracking?.isDelisted == true {
                Label("No longer listed — kept because you saved it",
                      systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if job.isNew {
                Label("New since your last run", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            // Full posted title here; the table shows the tidied one.
            //
            // Still wrong on a merged row: Optiver's reads "Software Engineer
            // Intern (Summer 2027 - Austin)" while the row covers Austin and
            // Chicago, and the postings listed right below say so. Slicing the
            // place off by reusing roleKey's cleaned string doesn't work —
            // roleKey lowercases, so recovering the original casing means
            // slicing by prefix length, which leaves "(Summer 2027" with an
            // unbalanced bracket. It needs its own cleaner that operates on the
            // title directly.
            Text(job.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            // Level rides here rather than in the facts grid: it's one word, and
            // a whole labelled row for it pushed everything else down.
            HStack(spacing: 5) {
                Text(job.company)
                if !job.levelLabel.isEmpty {
                    Text("·")
                    Text(job.levelLabel)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if job.isMerged {
                // Postings, not places: one posting can already name several
                // cities, so the two counts don't match.
                Text("\(job.variants.count + 1) separate postings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    openButton(job.locationLabelForPrimary, job.url, primary: true)
                    ForEach(job.variants, id: \.key) { variant in
                        openButton(variant.locationDisplay.isEmpty
                                   ? variant.location : variant.locationDisplay,
                                   variant.url, primary: false)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// One "open" row per location when a role was merged.
    private func openButton(_ label: String, _ urlString: String,
                            primary: Bool) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right.square")
                        Text(label.isEmpty ? "Open posting" : label)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func facts(_ job: Job) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            if job.places.isEmpty {
                row("Location", job.location.isEmpty ? "—" : job.location)
            } else {
                row("Location", job.places.map(\.label).joined(separator: " · "))
                let continents = job.continents.filter { $0 != "Other" }
                if !continents.isEmpty {
                    row("Region", continents.joined(separator: ", "))
                }
                // Worth showing when the tidy-up moved things around.
                // Only when it differs *and* the row is a single posting — on a
                // merged row it names one office out of several, which reads as a
                // contradiction of the Location line above it.
                if !job.isMerged,
                   job.location != job.places.map(\.label).joined(separator: " · ") {
                    row("As posted", job.location)
                }
            }
            // Relative age only, with the date on hover: "2026-07-28 · 11 days
            // ago" is wider than the value column and wrapped every time.
            // effectiveDate, like the table's column: "not stated" was showing
            // even where we know when we first saw it.
            row("Posted",
                Dates.relative(job.effectiveDate).map {
                    job.dateIsInferred ? "first seen \($0)" : $0
                } ?? "not stated",
                help: job.dateIsInferred
                      ? "This board states no date — first seen \(job.firstSeen)"
                      : job.posted)
            if !job.department.isEmpty { row("Team", job.department) }
            row("Board", job.ats.label)
            // Only meaningful once a posting is tracked, and it belongs with the
            // other facts rather than in a second grid under its own divider.
            if let entry = tracking, !entry.lastSeen.isEmpty {
                row("Last listed", Dates.relative(entry.lastSeen) ?? entry.lastSeen,
                    help: entry.lastSeen)
            }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String,
                     help: String = "") -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .help(help)
        }
    }

    private func tagRow(_ job: Job) -> some View {
        // A simple wrap: tags are short and there are only a handful.
        HStack(spacing: 5) {
            ForEach(job.tags.prefix(4), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        }
    }

    private func descriptionBlock(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Description")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(job.description)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
