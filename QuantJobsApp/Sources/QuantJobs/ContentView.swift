// Wrapped so the package still builds where SwiftUI does not exist —
// the scraper has to run on Linux for the scheduled fetch, and only the
// window needs Apple's UI frameworks.
#if canImport(SwiftUI)
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
    @State private var rowHoverHint: RowHoverHint?
    /// Width of the detail column, which is the window minus the sidebar. Drives
    /// which table columns survive and whether the side panel is worth its space.
    @State private var pane: CGFloat = 1200

    /// Three shapes rather than one that degrades. Dragging the window narrow used
    /// to starve every part at once: the panel kept its 300pt and got clipped, the
    /// table's Company column fell to "TransM…", and the split view gave up and
    /// drew the sidebar *over* the table.
    private enum Shape { case tight, narrow, medium, wide }

    private var shape: Shape {
        if pane < 560 { .tight }
        else if pane < 740 { .narrow }
        else if pane < 1000 { .medium }
        else { .wide }
    }

    /// The narrowest the table can draw itself: the sum of the minimums of the
    /// columns currently showing, plus a little for row insets and the scroller.
    ///
    /// This is the number the old fixed-threshold version was missing. The table
    /// cannot compress below it, so when the panel's width plus this exceeded the
    /// pane, the surplus went off the right-hand edge — which is why the panel
    /// clipped its own values ("North Ame", "Chicago, Il") instead of something
    /// giving way.
    private var tableFloor: CGFloat {
        var w: CGFloat = 84 + 74 + 96          // marks + Company + Role
        if model.list == .applied { w += 84 }  // Progress
        if shape != .tight { w += 66 }         // Level
        if shape == .wide || shape == .medium { w += 66 }   // Posted
        if shape == .wide { w += 84 }          // Location
        return w + 12
    }

    /// What's actually left for the panel once the table has its floor.
    ///
    /// Derived rather than chosen: a fixed 300 had nowhere to take space from,
    /// and fixed steps of 300/260/224 were only a coarser version of the same
    /// mistake. Capped at 300 because the panel gains nothing from being wider,
    /// and dropped entirely below 200, where it would be too narrow to read and
    /// the table is the better use of the pixels.
    private var panelWidth: CGFloat {
        guard selectedJob != nil else { return 0 }
        let spare = pane - tableFloor - 1      // the divider
        return spare < 200 ? 0 : min(300, spare)
    }

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
            GeometryReader { proxy in
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
                    // Screenshotting the detail panel needs a row selected, and
                    // synthetic clicks land on a SwiftUI Table without selecting
                    // anything — it exposes no AXRow to target. One env var beats
                    // guessing at pixel coordinates.
                    .onChange(of: rows.count, initial: true) {
                        guard selection.isEmpty,
                              let want = ProcessInfo.processInfo
                                  .environment["QUANTJOBS_SELECT"]?.lowercased(),
                              let hit = rows.first(where: {
                                  $0.title.lowercased().contains(want)
                                      || $0.company.lowercased().contains(want)
                              })
                        else { return }
                        selection = [hit.id]
                    }
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
            if selectedJob != nil, panelWidth > 0 {
                Divider()
                JobDetail(job: selectedJob, model: model)
                    // Fresh note state whenever the selection changes.
                    .id(selectedJob?.id)
                    // Scaled to what's left rather than fixed: at a hard 300 a
                    // narrow window had nowhere to take space from and clipped
                    // the sidebar instead.
                    .frame(width: panelWidth)
            }
            }
            .onChange(of: proxy.size.width, initial: true) { _, w in
                if abs(w - pane) > 1 { pane = w }
            }
            }
        }
        // Below this the columns can't all have their minimum and the split view
        // responds by drawing the sidebar *over* the table, which loses the row
        // marks and the leading characters of every heading.
        .frame(minWidth: 560)
        .overlay(alignment: .topLeading) {
            if let hint = rowHoverHint {
                Text(hint.text)
                    .font(.system(size: 11))
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary) }
                    .position(x: hint.x, y: hint.y)
                    .allowsHitTesting(false)
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
            rowHoverHint = nil
            columns[visibility: "progress"] = model.list == .applied ? .visible : .hidden
        }
        // Drop the columns you can live without before the ones you can't. Role
        // and Company are what the list is *for*; Location, Level and Posted are
        // context, and context truncated to "Santa Clara,…" is worth less than a
        // Role you can read.
        .onChange(of: shape, initial: true) {
            columns[visibility: "location"] = shape == .wide ? .visible : .hidden
            columns[visibility: "posted"] =
                shape == .wide || shape == .medium ? .visible : .hidden
            columns[visibility: "level"] = shape == .tight ? .hidden : .visible
        }
        .onChange(of: model.settingsFingerprint) {
            model.persistSettings()
            // And send them, or a filter changed here reached the phone only on
            // the next launch — marks were pushed on every edit and filters were
            // not, which made the sync look half-broken.
            model.scheduleSync()
        }
        .onChange(of: model.refreshFingerprint) { model.scheduleRefresh() }
        .task {
            // Deliberately after the window is up: the first read of the config
            // folder can trigger a macOS permission prompt.
            if !model.isLoaded { await model.reload() }
            // Start before any optional network work so sync/update delays
            // cannot leave the window indefinitely showing yesterday's cache.
            model.refreshAfterLaunch()
            await model.mergeSharedLedger()
            // And whatever was starred on the phone since the window was last
            // open. Silent when syncing has not been set up.
            await model.syncMarks()
            await model.updater.checkOnLaunch()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKSPACE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.bottom, 8)

            VStack(spacing: 3) {
                ForEach(AppModel.JobList.allCases) { entry in
                    sidebarDestination(entry)
                }
            }
            Divider().padding(.vertical, 15)
            Text(sidebarExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                // Not .fixedSize(vertical:): the split view measures the
                // sidebar at a near-zero width, where that reported a column of
                // one-word lines taller than a laptop window. The window then
                // overflowed and centred, sliding the sidebar under the
                // traffic lights and the filter buttons under the toolbar.
                .padding(.horizontal, 7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 200)
    }

    private func sidebarDestination(_ entry: AppModel.JobList) -> some View {
        let selected = model.list == entry
        return Button {
            selection = []
            model.list = entry
        } label: {
            HStack(spacing: 9) {
                Image(systemName: entry == .results ? "magnifyingglass" : entry.symbol)
                    .font(.system(size: 14))
                    .frame(width: 19)
                Text(entry == .results ? "Browse Jobs" : entry.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 2)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sidebarExplanation: String {
        switch model.list {
        case .results: "Explore current openings with the filters above the table."
        case .favorite: "Roles you saved for later, even if the posting disappears."
        case .applied: "Your applications, organized by their latest stage."
        case .hidden: "Roles you removed from Browse Jobs. You can show them again here."
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
                // The count that actually needs acting on: steps sitting in
                // this stage that you still owe, rather than ones you're waiting
                // on them for. Only sat stages can have any.
                if group.stage.isSat {
                    let owed = group.jobs.count {
                        model.trackedEntry(for: $0)?.isAwaitingYou == true
                    }
                    if owed > 0 {
                        Text("\(owed) to do")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: .capsule)
                    }
                }
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
                JobRowActions(job: job, model: model, onHoverHint: showRowHoverHint)
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
            .width(min: 74, ideal: 116, max: 190)

            TableColumn("Role", value: \.shortTitle) { job in
                let parts = job.titleParts
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(parts.role)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.isDelisted(job) ? .secondary : .primary)
                            .strikethrough(model.isDelisted(job), color: .secondary)
                            .lineLimit(1)
                        if let detail = parts.detail {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if model.isDelisted(job) {
                        Image(systemName: "xmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("No longer listed on the board")
                    }
                }
                .accessibilityLabel(job.displayTitle)
                .help(job.title)      // the full posted title on hover
            }
            .width(min: 96, ideal: 230)

            TableColumn("Location", value: \.locationDisplay) { job in
                Text(job.locationDisplay)
                    .foregroundStyle(.secondary)
                    .help(job.places.count > 1
                          ? job.places.map(\.label).joined(separator: " · ")
                          : job.location)
            }
            .width(min: 84, ideal: 128, max: 200)
            .customizationID("location")

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
            .customizationID("level")

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
            .customizationID("posted")
    }

    private struct RowHoverHint {
        let text: String
        let x: CGFloat
        let y: CGFloat
    }

    private func showRowHoverHint(_ text: String?) {
        guard let text, let window = NSApp.keyWindow else {
            rowHoverHint = nil
            return
        }
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let content = window.contentLayoutRect
        rowHoverHint = RowHoverHint(text: text, x: mouse.x - content.minX,
                                   y: content.maxY - mouse.y - 24)
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
        // Whenever the space or the set of columns changes. Width and shape
        // alone miss the Applied list, whose Progress column appears without
        // either moving.
        .background(TableFitter(key: [Int(pane), Int(panelWidth),
                                      model.list.hashValue, shape.hashValue]))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.list == .results && model.selectedCategoryIDs.isEmpty
                  ? "Choose categories"
                  : model.isScraping ? "Scraping…" : "No roles yet",
                  systemImage: model.isScraping ? "arrow.trianglehead.2.clockwise" : "tray")
        } description: {
            if model.list == .results && model.selectedCategoryIDs.isEmpty {
                Text("Select one or more categories above to show jobs.")
            } else if model.isScraping {
                Text(model.scanned == 0
                     ? "Connecting to \(model.total) boards…"
                     : "\(model.scanned) of \(model.total) boards")
                // Which one, once it is down to a few. Meta alone is a request
                // per posting and takes minutes; without a name on it, the last
                // board looks like a stall rather than a slow one.
                if !model.outstandingBoards.isEmpty {
                    Text("· waiting on \(model.outstandingBoards.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                }
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
                if model.scanned == 0 {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(model.total) boards…")
                } else {
                    ProgressView(value: Double(model.scanned), total: Double(max(model.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                    Text(model.outstandingBoards.isEmpty
                         ? "\(model.scanned)/\(model.total) boards"
                         : "\(model.scanned)/\(model.total) · \(model.outstandingBoards[0])")
                }
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

/// Fits the job table's columns to the width it actually has.
///
/// Without it the NSTableView behind the SwiftUI Table sized its columns to
/// the whole window, sidebar included, so Location, Level and Posted sat past
/// the right edge behind a horizontal scroll.
private struct TableFitter: NSViewRepresentable {
    let key: [Int]

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // After this layout pass, so hidden columns are already gone and the
        // clip view already has its new width.
        DispatchQueue.main.async {
            if let table = Self.table(near: view) { Self.fit(table) }
        }
    }

    /// The width the columns may use is the clip view's less its insets. On
    /// macOS 26 the detail column runs underneath the sidebar, and the table's
    /// scroll view reports the sidebar as a 188pt leading inset; AppKit's own
    /// column autoresizing ignores that, sizing the columns to the whole
    /// window so the last 188pt of them could only be reached by scrolling.
    ///
    /// Role takes up the difference, being the one column with no maximum and
    /// the one worth the space. A plain sizeToFit scales every column alike,
    /// so undoing a 1700pt Role squeezed Company to "Cloudfl…" as well.
    private static func fit(_ table: NSTableView) {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        let visible = (0..<table.numberOfColumns).filter { !table.tableColumns[$0].isHidden }
        guard let last = visible.last else { return }
        let insets = clip.contentInsets
        let room = clip.bounds.width - insets.left - insets.right
        let spare = room - table.rect(ofColumn: last).maxX
        guard abs(spare) >= 1 else { return }
        let columns = visible.map { table.tableColumns[$0] }
        if let role = columns.max(by: { $0.maxWidth < $1.maxWidth }),
           role.width + spare >= role.minWidth {
            role.width += spare
        } else {
            // Too narrow even with Role at its minimum: take the rest of the
            // cut from the other flexible columns, down to their minimums.
            var cut = -spare
            for column in columns.sorted(by: { $0.maxWidth > $1.maxWidth }) {
                let give = min(cut, column.width - column.minWidth)
                column.width -= give
                cut -= give
                if cut < 1 { break }
            }
        }
    }

    /// The table is a sibling of this view's host, not an ancestor, so climb
    /// until some ancestor contains one.
    private static func table(near view: NSView) -> NSTableView? {
        var node = view.superview
        while let current = node {
            if let found = first(in: current) { return found }
            node = current.superview
        }
        return nil
    }

    private static func first(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = first(in: child) { return found }
        }
        return nil
    }
}

/// The three table marks use the whole icon cell as a hit target. Application
/// progress is chosen explicitly, just as it is in the detail panel.
private struct JobRowActions: View {
    let job: Job
    let model: AppModel
    let onHoverHint: (String?) -> Void
    @State private var showingStages = false

    var body: some View {
        let saved = model.isSaved(job)
        let tracked = model.hasApplication(job)
        let hidden = model.isHidden(job)
        HStack(spacing: 2) {
            Circle()
                .fill(job.isNew ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                .frame(width: 6, height: 6)
                .help(job.isNew ? "Not seen on a previous run" : "")

            Button {
                onHoverHint(nil)
                model.setSaved(!saved, for: [job])
            } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? AnyShapeStyle(.tint)
                                           : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(saved ? "Unsave" : "Save")
            .accessibilityHint(saved ? "Remove from Saved. Application progress is kept."
                                     : "Keep this role in Saved for later.")
            .onHover { onHoverHint($0 ? (saved ? "Remove from Saved" : "Save for later") : nil) }

            Button {
                onHoverHint(nil)
                showingStages.toggle()
            } label: {
                Image(systemName: tracked ? "paperplane.fill" : "paperplane")
                    .foregroundStyle(tracked ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(tracked ? "Update application" : "Track application")
            .accessibilityHint(tracked ? "Choose the next application stage."
                                       : "Choose Applied, assessment, interview, or later.")
            .onHover { onHoverHint($0 ? (tracked ? "Update application"
                                                : "Choose application stage") : nil) }
            .popover(isPresented: $showingStages, arrowEdge: .bottom) {
                ApplicationStagePicker(
                    stages: tracked ? (model.trackedEntry(for: job)?.remainingStages ?? [])
                                    : Stage.allCases,
                    applied: tracked) { stage in
                    if !tracked && stage != .applied {
                        model.record(.applied, for: [job])
                    }
                    model.record(stage, for: [job])
                    showingStages = false
                }
            }

            Button {
                onHoverHint(nil)
                model.setHidden(!hidden, for: [job])
            } label: {
                Image(systemName: hidden ? "eye.slash.fill" : "eye.slash")
                    .foregroundStyle(hidden ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(hidden ? "Unhide" : "Hide")
            .accessibilityHint(hidden ? "Show this role in Browse Jobs again."
                                      : "Hide from Browse Jobs; tracking is kept.")
            .onHover { onHoverHint($0 ? (hidden ? "Show in Browse Jobs"
                                               : "Hide from Browse Jobs") : nil) }
        }
        .buttonStyle(.plain)
    }
}
#endif
