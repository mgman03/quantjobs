// The panel beside the table: what a posting says, and where your application
// to it stands. Wrapped like ContentView, which is the only thing that shows it.
#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// Shared by the table's paperplane and the detail panel's application button.
struct ApplicationStagePicker: View {
    let stages: [Stage]
    let applied: Bool
    let onChoose: (Stage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(applied ? "Record the next step" : "Record where you are")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            if stages.isEmpty {
                Text("Nothing left to record")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            ForEach(stages) { stage in
                Button { onChoose(stage) } label: {
                    Label(stage.label, systemImage: stage.symbol)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
        .frame(width: 210)
    }
}

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
                    onDone: { model.markDone($0, dated: $1, on: $2, for: [job]) },
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
        if let m = entry.currentMilestone {
            let stage = m.stage
            HStack(spacing: 4) {
                Image(systemName: stage.symbol).font(.system(size: 9))
                Text(stage.short)
                // The word that separates "this landed in my inbox" from "I've
                // sat it". Without it the pill said "OA · 5d" for both, which
                // are opposite situations: one is a deadline you still owe.
                if stage.isSat {
                    Text(m.isDone ? "done" : "to do")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(m.isDone ? AnyShapeStyle(.quaternary)
                                             : AnyShapeStyle(Color.accentColor.opacity(0.25)),
                                    in: .capsule)
                }
                if let age = Dates.compact(entry.lastActivityOrDone) {
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
            .map { "\($0.stage.label) \($0.summary)" }
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
    /// (stage, the date it arrived, the date it was sat or nil to undo)
    var onDone: (Stage, String, String?) -> Void = { _, _, _ in }

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
                    // For a sat step the bare date is ambiguous, so it says
                    // which of the two dates this is.
                    Text(step.stage.isSat
                         ? "\(step.stage.receivedVerb) \(step.relative ?? step.date)"
                         : (step.relative ?? step.date))
                    Text(step.date).foregroundStyle(.tertiary).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if step.stage.isSat {
                    if let done = step.done {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text("\(step.stage.doneVerb) \(Dates.relative(done) ?? done)")
                            Text(done).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        // The one thing you'd want to press on a step you still
                        // owe, rather than buried in the ellipsis menu.
                        Button("Mark \(step.stage.doneVerb)") {
                            onDone(step.stage, step.date, Dates.today)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Record that you sat this, so it stops reading as "
                              + "something still owed")
                    }
                }
            }
            Spacer(minLength: 4)
            Menu {
                // A date picker in a 300pt panel is more chrome than this
                // deserves; nudging is what correcting a date actually needs.
                Button("Move a Day Earlier") { shift(step, by: -1) }
                Button("Move a Day Later") { shift(step, by: 1) }
                Button("Set to Today") { onRecord(step.stage, Dates.today) }
                if step.stage.isSat {
                    Divider()
                    if step.isDone {
                        Button("Not \(step.stage.doneVerb.capitalized) After All") {
                            onDone(step.stage, step.date, nil)
                        }
                    } else {
                        Button("Mark \(step.stage.doneVerb.capitalized) Today") {
                            onDone(step.stage, step.date, Dates.today)
                        }
                    }
                }
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
    /// (stage, the date it arrived, the date it was sat or nil to undo)
    var onDone: (Stage, String, String?) -> Void = { _, _, _ in }
    var onSaveNote: (String) -> Void = { _ in }

    @State private var showingStages = false
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
         onDone: @escaping (Stage, String, String?) -> Void = { _, _, _ in },
         onSaveNote: @escaping (String) -> Void = { _ in }) {
        self.job = job
        self.tracking = tracking
        self.onToggle = onToggle
        self.onRecord = onRecord
        self.onRepeat = onRepeat
        self.onRemove = onRemove
        self.onClear = onClear
        self.onDone = onDone
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

    /// The stages offered by the Applied button. Recording one that isn't
    /// `applied` fills in the application itself, so a role you're already
    /// interviewing for takes one click rather than two.
    private func stagePicker(applied: Bool) -> some View {
        let stages = applied ? (tracking?.remainingStages ?? []) : Stage.allCases
        return ApplicationStagePicker(stages: stages, applied: applied) { stage in
            if !applied && stage != .applied { onRecord(.applied, Dates.today) }
            onRecord(stage, Dates.today)
            showingStages = false
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
        .frame(maxWidth: .infinity)

        let applied = tracking?.hasApplication == true
        // A Button with a popover rather than a Menu. A Menu sizes itself to its
        // content and a frame around it only recentres it, so it sat visibly
        // narrower than the Save and Hide buttons either side of it. This matches
        // them exactly, and the popover has room to date each step.
        Button { showingStages.toggle() } label: {
            HStack(spacing: 4) {
                Label(applied ? "Applied" : "Move to Applied",
                      systemImage: applied ? "paperplane.fill" : "paperplane")
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(applied ? .accentColor : nil)
        .frame(maxWidth: .infinity)
        .popover(isPresented: $showingStages, arrowEdge: .bottom) {
            stagePicker(applied: applied)
        }
        .help(applied ? "Pick the next step, or use the timeline below"
                      : "Record an application — Applied today, or a later stage "
                        + "if you're already past it")

        let hidden = tracking?.hidden == true
        Button { onToggle(.hidden) } label: {
            Label(hidden ? "Unhide" : "Hide",
                  systemImage: hidden ? "eye.slash.fill" : "eye.slash")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(hidden ? .accentColor : nil)
        .frame(maxWidth: .infinity)
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
                                onClear: onClear, onDone: onDone)
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
#endif
