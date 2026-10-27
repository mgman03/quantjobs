import Testing
import Foundation
import Observation
@testable import QuantJobs

final class ChangeFlag: @unchecked Sendable { var changed = false }

actor RunCounter {
    var count = 0
    func start() { count += 1 }
}

actor BoardRecorder {
    var ats: [ATS] = []
    func add(_ kind: ATS) { ats.append(kind) }
}

@Suite(.serialized)
struct RegressionTests {
    @Test
    func testLaunchScrapeStartsFastBoardsAlongsideSlowOnes() {
        let slow: [ATS] = [.meta, .citadel, .twosigma, .eightfold, .jibe,
                           .workday, .oracle, .optiver]
        let boards = slow.enumerated().map { Company(name: "slow-\($0.offset)", ats: $0.element) }
            + (0..<12).map { Company(name: "fast-\($0)", ats: .greenhouse) }
        let first = Array(Scraper.orderedForProgress(boards, workers: 10).prefix(10))
        #expect(first.count == 10)
        #expect(first.contains { $0.ats == .meta })
        #expect(first.filter { $0.ats == .greenhouse }.count == 8)
        #expect(Scraper.orderedForProgress(boards, workers: 1).first?.ats == .greenhouse)
    }

    @Test
    func testLaunchScrapeReportsFastBoardBeforeSlowOnesFinish() async {
        let slow = (0..<10).map { Company(name: "slow-\($0)", ats: .meta) }
        let fast = Company(name: "fast", ats: .greenhouse)
        let recorder = BoardRecorder()
        await Scraper.run(slow + [fast], deep: false, workers: 10, fetch: { company, _ in
            if company.ats == .meta { try? await Task.sleep(for: .milliseconds(50)) }
            return BoardResult(company: company, jobs: [])
        }, onBoard: { result in
            await recorder.add(result.company.ats)
        })
        let seen = await recorder.ats
        #expect(seen.first == .greenhouse)
        #expect(seen.count == 11)
    }

    @MainActor
    @Test
    func testAdvancedSettingsResetOnlyItsOwnControls() {
        let model = AppModel()
        model.search = "software"
        model.cityFilter = ["London"]
        model.selectedCategoryIDs = ["swe", "data"]
        model.sinceDays = 30
        model.deep = true
        model.mergeRoles = false
        model.resetAdvancedSettings()
        #expect(model.search == "software")
        #expect(model.cityFilter == ["London"])
        #expect(model.selectedCategoryIDs == ["swe", "data"])
        #expect(model.sinceDays == nil)
        #expect(!model.deep)
        #expect(model.mergeRoles)
    }

    @Test
    func testInternshipClassification() {
        let rejected: [(String, String)] = [
            ("Dean of Students, Academy of Math and Programming (AMP)", "Full-Time: Experienced / Summer Enrichment Program"),
            ("Discovery Program: Trading System Engineer (On-site)", "Student Discovery Program"),
            ("PhD Discovery Summit (On-Site)", "Student Discovery Program"),
            ("Women in Technology Spring Week 2027", ""),
            ("Campus Student Founder / Teacher", ""),
            ("Student Researcher, BS/MS, Fall 2026", ""),
            ("Senior Software Engineer", "Internship Team"),
            ("Software Engineer, New Grad", "Technology"),
            ("Software Engineer II, Co-op and Marketplaces", ""),
            ("Product Engineer, Co-op and Partnerships", ""),
            ("Software Engineer III, Internship Platform", ""),
            ("Internship (No intern program at this time)", ""),
            ("Banking, Investment Banking, Full Time Analyst, London – United Kingdom 2027 - (Applicable for 2026 Citi Summer interns only)", ""),
        ]
        let accepted: [(String, String)] = [
            ("Software Engineering Intern, Summer 2027", ""),
            ("Software Engineer", "Summer Internship / Technology"),
            ("Quantitative Researcher", "Summer Internship"),
            ("2027 Summer Analyst", "Technology"),
            ("Software Engineering Co-op", ""),
            ("Software Engineering Intern", ""),
            ("Software Engineer Intern", ""),
            ("Engineering Program Manager Intern - Shanghai", ""),
            ("Associate Product Manager BS/MS Intern, 2027", ""),
            ("AI & Project Operations Intern – Managing Director Office", ""),
            ("Technology Co-op with Drexel University", ""),
            ("Praktikum Softwareentwicklung", ""),
            ("Industrial Placement Engineer", ""),
            ("Site Reliability Engineering University Co - Op Placement 2027", ""),
            ("Undergraduate Software Intern", ""),
        ]
        let matcher = CategoryMatcher(JobCategory(name: "all", description: "", include: [], exclude: []))
        for (cases, expected) in [(rejected, false), (accepted, true)] {
            for (title, department) in cases {
                #expect(Levels.matches(.intern, title: title, department: department) == expected)
                #expect((Levels.detect(title: title, department: department) == "intern") == expected)
                #expect(matcher.accepts(RawJob(title: title, department: department), level: .intern, deep: false) == expected)
            }
        }
    }

    @Test
    func testCampusHiringStaffAreNotNewGraduates() {
        for title in ["Campus Recruiter", "Campus Recruiting Coordinator",
                      "University Recruiter", "Early Career Talent Partner - Technology",
                      "Talent Acquisition - Campus (Paris)",
                      "Campus Student Founder / Teacher",
                      "Point72 Academy Coffee Chats — Class of 2029 (US)",
                      "EU Campus - Aarhus Hackahton IMCity",
                      "Campus Construction Manager",
                      "Campus Operations Manager",
                      "Associate Banker, 30 Hours, Winston Salem, NC - University Pkwy Branch",
                      "Private Client Banker - University Place - New York, NY",
                      "Personal Banker SAFE Act - University of Chicago Branch",
                      "Quant Talk - University of Oxford (13th of November)"] {
            #expect(!Levels.matches(.newgrad, title: title, department: ""))
            #expect(!Levels.matches(.internOrNewgrad, title: title, department: ""))
        }
        #expect(!Levels.matches(.intern,
                                title: "Expression of Interests | Career Fair Events Internship",
                                department: ""))
        for title in ["Campus Full Time 2027 - Software Developer",
                      "Campus AI Research Engineer (Full-Time)",
                      "Software Engineer, Early Career",
                      "Member of Technical Staff (New Grad)"] {
            #expect(Levels.matches(.newgrad, title: title, department: ""))
        }
        #expect(!Levels.matches(.newgrad,
                                title: "Senior Member of Technical Staff (New Grad)",
                                department: ""))
        #expect(Levels.classification(title: "Member of Technical Staff (New Grad)",
                                      department: "").matches.contains(Level.internOrNewgrad.rawValue))
    }

    @MainActor
    @Test
    func testResearchMatchesBroadTitlesAndReclassifiesCachedJobs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        let previousSettings = AppSettings.store
        ConfigStore.directoryOverride = directory
        AppSettings.useScratchStore("research-regression")
        defer {
            ConfigStore.directoryOverride = previous
            AppSettings.store = previousSettings
            try? FileManager.default.removeItem(at: directory)
        }
        try seedConfig(in: directory)
        let category = try #require(ConfigStore.loadCategories().first { $0.name == "quant-research" })
        #expect(category.displayName == "Research")
        let matcher = CategoryMatcher(category)
        for title in ["Machine Learning Researcher Intern", "Research Intern, Robotics",
                      "Fundamental Researcher", "User Research Intern",
                      "Market Research Analyst", "Applied Scientist Intern",
                      "Marketing Insights Researcher", "Applied Legal Researcher",
                      "Research Science Internship - Science Recruiting"] {
            #expect(matcher.acceptsCategory(RawJob(title: title), deep: false), "\(title)")
        }
        #expect(!matcher.acceptsCategory(RawJob(title: "Software Engineer Intern"), deep: false))
        #expect(!matcher.acceptsCategory(RawJob(title: "Recruiter - AI Research"), deep: false))
        #expect(!matcher.acceptsCategory(RawJob(title: "Recruiting Researcher"), deep: false))
        let software = try #require(ConfigStore.loadCategories().first { $0.name == "swe" })
        let softwareMatcher = CategoryMatcher(software)
        let aiResearch = RawJob(title: "Campus AI Research Engineer (Intern)")
        #expect(matcher.acceptsCategory(aiResearch, deep: false))
        #expect(!softwareMatcher.acceptsCategory(aiResearch, deep: false))
        let researchWithSoftwareBoilerplate = RawJob(
            title: aiResearch.title,
            description: String(repeating: "Build software engineering systems and platforms. ",
                                count: 30))
        #expect(!softwareMatcher.acceptsCategory(researchWithSoftwareBoilerplate, deep: true))
        #expect(softwareMatcher.acceptsCategory(
            RawJob(title: "Campus Software Engineer, AI Research (Intern)"), deep: false))
        #expect(softwareMatcher.acceptsCategory(
            RawJob(title: "Software Research Engineer Intern"), deep: false))
        var cached = job("Research Intern, Robotics")
        cached.matchedCategories = ["all"] // written before Research included broad titles
        var campus = job("Campus AI Research Engineer (Intern)")
        campus.matchedCategories = ["all", "swe", "quant-research"]
        ConfigStore.saveCache(.init(savedAt: Date(), category: "swe", level: "intern",
                                     jobs: [cached, campus]))
        let model = AppModel()
        await model.reload()
        #expect(model.jobs.first?.matchedCategories.contains("quant-research") == true)
        #expect(model.jobs.last?.matchedCategories.contains("quant-research") == true)
        #expect(model.jobs.last?.matchedCategories.contains("swe") == false)
    }

    @Test
    func testParallelParserKeepsSourceOrderAndTags() async {
        let software = CategoryMatcher(JobCategory(name: "swe", description: "",
                                                   include: ["software engineer"], exclude: []))
        let research = CategoryMatcher(JobCategory(name: "quant-research", description: "",
                                                   include: ["research engineer"], exclude: []))
        let jobs = (0..<1_200).map { index in
            Job(company: "Test", title: index.isMultiple(of: 2)
                ? "Software Engineer Intern" : "Research Engineer Intern",
                location: "London", url: "https://example.invalid/\(index)",
                posted: "", department: "", description: "", ats: .greenhouse, tags: [])
        }
        let matchers = [software, research]
        let serial = JobTagger.tagSerial(jobs, matchers: matchers, stackMatchers: [],
                                         deep: false, seen: [:], today: "2026-10-27")
        let parallel = await JobTagger.tag(jobs, matchers: matchers, stackMatchers: [],
                                           deep: false, seen: [:], today: "2026-10-27")
        #expect(parallel.map(\.key) == serial.map(\.key))
        #expect(parallel.map(\.matchedCategories) == serial.map(\.matchedCategories))
        #expect(parallel.map(\.matchedLevels) == serial.map(\.matchedLevels))
        #expect(parallel.count == jobs.count)
    }

    @Test
    func testRoleTitleKeepsQualifiersReadable() {
        let cases: [(String, String, String?)] = [
            ("Software Engineer II, Co-op and Marketplaces", "Software Engineer II", "Co-op and Marketplaces"),
            ("Software Engineer, Intern", "Software Engineer Intern", nil),
            ("Software Engineering - Intern", "Software Engineering Intern", nil),
            ("Software Engineer - New Grad", "Software Engineer New Grad", nil),
            ("Software Engineering Intern - 2027", "Software Engineering Intern", nil),
            ("Verification Engineer - PCIE", "Verification Engineer - PCIE", nil),
            ("Quantic – Quantitative Developer Intern", "Quantitative Developer Intern", "Quantic"),
            ("2027 – Graduate or Internship, Infrastructure Engineer", "Infrastructure Engineer", nil),
            ("Quantitative Researcher", "Quantitative Researcher", nil),
        ]
        for (title, role, detail) in cases {
            let parts = TitleTidy.parts(TitleTidy.shorten(title))
            #expect(parts.role == role)
            #expect(parts.detail == detail)
        }
        #expect(job("Software Engineer, Intern").displayTitle == "Software Engineer Intern")
        #expect(job("Software Engineer II, Co-op and Marketplaces").displayTitle
                == "Software Engineer II — Co-op and Marketplaces")
    }

    @Test
    func testRoleSubtitleOmitsRepeatedLocationAndIntake() {
        LocationParser.gazetteer = ConfigStore.loadGazetteer()
        defer { LocationParser.gazetteer = .empty }
        func parts(_ title: String, location: String) -> (String, String?) {
            var posting = job(title)
            posting.location = location
            posting.places = LocationParser.parse(location)
            posting.level = "intern"
            let result = posting.titleParts
            return (result.role, result.detail)
        }
        #expect(parts("Software Engineer Intern - London", location: "London").1 == nil)
        #expect(parts("Software Engineer Intern - Summer 2027", location: "London").1 == "Summer")
        #expect(parts("Software Engineer Intern (Summer 2027 - Austin)", location: "Austin").0
                == "Software Engineer Intern")
        #expect(parts("Software Engineer Intern (Summer 2027 - Austin)", location: "Austin").1 == "Summer")
        #expect(parts("Software Engineer Intern - Backend - London", location: "London").1
                == "Backend")
        #expect(parts("Research Intern, PhD, Summer 2027", location: "London").1 == "PhD · Summer")
        #expect(parts("Software Engineer Intern - Shanghai", location: "London").1 == "Shanghai")
        #expect(parts("Software Engineer Intern - Privy", location: "NYC-Privy").1 == "Privy")
        #expect(parts("Software Engineer Intern - Remote", location: "Remote").1 == nil)
        #expect(parts("Software Engineering Intern, 2027 (English, Hebrew)", location: "London").1
                == "English, Hebrew")
        #expect(parts("Quantitative Researcher - Intern [2027 Summer]", location: "London").1 == nil)
        #expect(parts("Intern Opportunities - October 2026 to September 2027", location: "London").1
                == "October 2026 to September 2027")
        #expect(parts("Campus Researcher (Off-Cycle - Winter/Spring 2027 Intern)", location: "London").0
                == "Campus Researcher Intern")
        #expect(parts("Campus Researcher (Off-Cycle - Winter/Spring 2027 Intern)", location: "London").1
                == "Off-Cycle - Winter/Spring")
        #expect(parts("System Software Engineer - GPU and SOC (2027 RDSS Intern)", location: "London").0
                == "System Software Engineer Intern")
        #expect(parts("System Software Engineer - GPU and SOC (2027 RDSS Intern)", location: "London").1
                == "GPU and SOC (RDSS)")
        #expect(parts("Customer Growth Associate, Google Customer Solutions, University Graduate, 2027 Start (English)", location: "London").1
                == "Google Customer Solutions, University Graduate (English)")
        #expect(parts("High School Internship, Software Engineering (Summer 2027)", location: "Seattle").0
                == "Software Engineering Internship")
        #expect(parts("High School Internship, Software Engineering (Summer 2027)", location: "Seattle").1
                == "High School · Summer")
        #expect(parts("Quantitative Developer Intern 2027", location: "Jupiter, FL").0
                == "Quantitative Developer Intern")
        #expect(parts("Quantitative Developer Intern 2027", location: "Jupiter, FL").1 == nil)
        #expect(parts("Software Engineering Intern (2027 Start) - London", location: "London").0
                == "Software Engineering Intern")
        #expect(parts("Software Engineering Intern (2027 Start) - London", location: "London").1 == nil)
        #expect(parts("Spring 2027 Software Engineering Internship/Co-op", location: "Palo Alto").0
                == "Software Engineering Internship/Co-op")
        #expect(parts("Spring 2027 Software Engineering Internship/Co-op", location: "Palo Alto").1
                == "Spring")
        #expect(parts("Summer 2027 Software Engineering Internship/Co-op", location: "Palo Alto").1
                == "Summer")
        #expect(parts("Aeon Modeling Software Intern", location: "Munich").0 == "Software Intern")
        #expect(parts("Aeon Modeling Software Intern", location: "Munich").1 == "Aeon Modeling")
        #expect(parts("Internship - Software Engineering - AI-Assisted Baseband Debugging", location: "Munich").0
                == "Software Engineering Internship")
        #expect(parts("Internship - Software Engineering - AI-Assisted Baseband Debugging", location: "Munich").1
                == "AI-Assisted Baseband Debugging")
        #expect(parts("2027 Quantitative Research Intern, London", location: "London").0
                == "Quantitative Research Intern")
        #expect(parts("Intern - Full Stack Engineer", location: "Munich").0
                == "Full Stack Engineer Intern")
        #expect(parts("2027 - Internship, Data Engineering", location: "London").0
                == "Data Engineering Internship")
        #expect(parts("Machine Learning Researcher - PhD Intern", location: "London").0
                == "Machine Learning Researcher Intern")
        #expect(parts("Machine Learning Researcher - PhD Intern", location: "London").1
                == "PhD")
        #expect(parts("NVIDIA 2027 Internships: Software Engineering", location: "London").0
                == "Software Engineering Internship")
        #expect(parts("Mako Summer Internship - Trading", location: "London").0
                == "Trading Internship")
        #expect(parts("Mako Summer Internship - Trading", location: "London").1
                == "Summer")
        #expect(parts("Expressions of Interest - Graduate Software Developer 2027", location: "London").0
                == "Graduate Software Developer")
        #expect(parts("NVIDIA 2027 New College Graduate: Software Engineering - China", location: "London").0
                == "Software Engineering")
        #expect(parts("Data Engineer Internship - 2027 (US)", location: "London").0
                == "Data Engineer Internship")
        #expect(parts("Software Engineer Intern - (Summer 2027)", location: "London").0
                == "Software Engineer Intern")
        #expect(parts("(Physical) Security Specialist Intern - 2027 Internship, DC Security", location: "London").0
                == "(Physical) Security Specialist Intern")
        #expect(parts("【Class of 2029／Internship】Applied Scientists , Amazon Japan", location: "London").0
                == "Applied Scientists Internship")
        #expect(parts("2027 University Graduate - Software Engineer", location: "London").0
                == "Software Engineer")
        #expect(parts("Graduate Talent (Software Application Development Engineer)", location: "London").0
                == "Software Application Development Engineer")
        #expect(parts("Intern (Engineering & IT)", location: "London").0
                == "Engineering & IT Intern")
        #expect(parts("University Grad | Customer Experience Associate", location: "London").0
                == "Customer Experience Associate")
    }

    @Test
    func testFirmSelectionStaysOutOfTheRoster() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        ConfigStore.directoryOverride = directory
        defer { ConfigStore.directoryOverride = previous; try? FileManager.default.removeItem(at: directory) }

        func writeRoster(_ firms: [Company]) throws {
            try JSONEncoder().encode(CompanyFile(comment: nil, companies: firms))
                .write(to: ConfigStore.companiesURL)
        }
        func roster() throws -> [String: Bool] {
            let file = try JSONDecoder().decode(CompanyFile.self,
                                                from: Data(contentsOf: ConfigStore.companiesURL))
            return Dictionary(uniqueKeysWithValues: file.companies.map { ($0.name, $0.enabled) })
        }
        func loaded() throws -> [String: Bool] {
            Dictionary(uniqueKeysWithValues: try ConfigStore.loadCompanies().companies
                .map { ($0.name, $0.enabled) })
        }

        // An install from before the split: what the roster says is the selection.
        try writeRoster([Company(name: "A", ats: .greenhouse, token: "a", enabled: true),
                         Company(name: "B", ats: .greenhouse, token: "b", enabled: false)])
        #expect(try loaded() == ["A": true, "B": false])

        // Switching a firm off is recorded as a choice, not written into the roster.
        var file = try ConfigStore.loadCompanies()
        file.companies[0].enabled = false
        try ConfigStore.saveCompanies(file)
        #expect(try roster() == ["A": true, "B": false])
        #expect(try loaded() == ["A": false, "B": false])

        // A new roster changes defaults and adds a firm: choices stay, the
        // newcomer arrives as shipped.
        try writeRoster([Company(name: "A", ats: .greenhouse, token: "a", enabled: true),
                         Company(name: "B", ats: .greenhouse, token: "b", enabled: true),
                         Company(name: "C", ats: .greenhouse, token: "c", enabled: true)])
        #expect(try loaded() == ["A": false, "B": false, "C": true])
    }

    @MainActor
    @Test
    func testCachedListRemainsObservable() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        ConfigStore.directoryOverride = directory
        defer { ConfigStore.directoryOverride = previous; try? FileManager.default.removeItem(at: directory) }
        let model = AppModel()
        model.list = .favorite
        _ = model.visibleJobs
        let flag = ChangeFlag()
        withObservationTracking { _ = model.visibleJobs } onChange: { flag.changed = true }
        model.setSaved(true, for: [job("Intern")])
        #expect(flag.changed)
        #expect(model.visibleJobs.count == 1)
    }

    @MainActor
    @Test
    func testUnsavedMergedRoleStaysUnsavedAfterReloadAndStaleSync() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        ConfigStore.directoryOverride = directory
        defer {
            ConfigStore.directoryOverride = previous
            try? FileManager.default.removeItem(at: directory)
        }
        try seedConfig(in: directory)
        var london = job("Software Engineering Intern")
        london.url = "https://example.invalid/london"
        var zurich = london
        zurich.url = "https://example.invalid/zurich"
        zurich.location = "Zurich"
        let merged = try #require([london, zurich].mergedByRole().first)
        let model = AppModel()
        model.setSaved(true, for: [merged])
        #expect(model.count(.favorite) == 1)
        model.setSaved(false, for: [merged])
        #expect(model.count(.favorite) == 0)

        for posting in [london, zurich] {
            let cleared = try #require(ConfigStore.loadTracked()[posting.key])
            #expect(!cleared.saved)
            #expect(cleared.isEmpty)
            var stale = SyncMarks()
            stale.saved = true
            stale.updated = "2020-01-01T00:00:00Z"
            stale.job = posting
            model.absorbMarks(SyncDoc(tracked: [posting.key: stale]))
            #expect(!model.isSaved(posting))
        }
        let reloaded = AppModel()
        await reloaded.reload()
        #expect(reloaded.count(.favorite) == 0)
    }

    @MainActor
    @Test
    func testLaunchRefreshAndFailedCacheRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        let previousSettings = AppSettings.store
        ConfigStore.directoryOverride = directory
        AppSettings.useScratchStore("launch-regression")
        defer {
            ConfigStore.directoryOverride = previous
            AppSettings.store = previousSettings
            try? FileManager.default.removeItem(at: directory)
        }
        // Load the same bundled config as the app, but never touch user files.
        try seedConfig(in: directory)
        let old = job("Dean of Students")
        let saved = Date()
        ConfigStore.saveCache(.init(savedAt: saved, category: "swe", level: "intern", jobs: [old]))
        let model = AppModel(runBoards: { companies, _, receive in
            for company in companies {
                await receive(BoardResult(company: company, jobs: [], failure: "offline"))
            }
        })
        await model.reload()
        #expect(model.isLoaded)
        #expect(!(model.companies.isEmpty))
        #expect(model.showingCache)
        #expect(model.shouldRefreshOnLaunch)
        #expect(model.visibleJobs.isEmpty)
        model.refreshAfterLaunch()
        #expect(model.isScraping)
        while model.isScraping { await Task.yield() }
        #expect(model.showingCache)
        #expect(model.jobs.count == 1)
        #expect(model.lastRun == nil)
        #expect(ConfigStore.loadCache()?.jobs.count == 1)
        let scanned = model.scanned
        model.refreshAfterLaunch()
        #expect(!(model.isScraping))
        #expect(model.scanned == scanned)
        model.refreshOnLaunch = false
        #expect(!(model.shouldRefreshOnLaunch))
    }

    @MainActor
    @Test
    func testRefreshReplacesCacheAndCategoryUnionPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        let previousSettings = AppSettings.store
        ConfigStore.directoryOverride = directory
        AppSettings.useScratchStore("successful-refresh-regression")
        defer {
            ConfigStore.directoryOverride = previous
            AppSettings.store = previousSettings
            try? FileManager.default.removeItem(at: directory)
        }
        try seedConfig(in: directory)
        let cached = job("Old Intern")
        ConfigStore.saveCache(.init(savedAt: Date(), category: "swe", level: "intern", jobs: [cached]))
        let model = AppModel(runBoards: { companies, _, receive in
            guard let company = companies.first else { return }
            let jobs = ["Software Engineer Intern", "Data Scientist Intern", "Operations Intern"].enumerated().map { i, title in
                Job(company: company.name, title: title, location: "London", url: "https://example.invalid/new/\(i)", posted: "", department: "", description: "", ats: company.ats, tags: [])
            }
            await receive(BoardResult(company: company, jobs: jobs))
        })
        await model.reload()
        #expect(model.visibleJobs.count == 1)
        model.refreshAfterLaunch()
        while model.isScraping { await Task.yield() }
        #expect(!model.showingCache)
        #expect(model.lastRun != nil)
        #expect(!model.jobs.contains { $0.title == "Old Intern" })
        #expect(model.visibleJobs.count == 1)
        model.toggleCategory("data")
        #expect(model.selectedCategoryIDs == ["swe", "data"])
        #expect(model.visibleJobs.count == 2)
        #expect(!model.isScraping)
        model.currentSettings.save()
        let reloaded = AppModel()
        await reloaded.reload()
        #expect(reloaded.selectedCategoryIDs == ["swe", "data"])
        #expect(reloaded.visibleJobs.count == 2)
        #expect(!model.navCategories.contains { $0.name == "all" })
        #expect(model.navCategories.contains { $0.displayName == "Others" })
        model.toggleCategory("swe")
        #expect(model.selectedCategoryIDs == ["data"])
        model.toggleCategory("data")
        #expect(model.selectedCategoryIDs.isEmpty)
        #expect(model.visibleJobs.isEmpty)
        model.currentSettings.save()
        let noCategories = AppModel()
        await noCategories.reload()
        #expect(noCategories.selectedCategoryIDs.isEmpty)
        #expect(noCategories.visibleJobs.isEmpty)
        noCategories.toggleCategory("others")
        #expect(noCategories.visibleJobs.map(\.title) == ["Operations Intern"])
        // A saved setting from the older UI used an empty selection to mean
        // every category. Convert it once to an explicit broad selection.
        var legacy = noCategories.currentSettings
        legacy.categoryID = "all"
        legacy.categoryIDs = []
        legacy.save()
        let migrated = AppModel()
        await migrated.reload()
        #expect(migrated.selectedCategoryIDs == Set(migrated.navCategories.map(\.name)))
        #expect(migrated.visibleJobs.count == 3)
    }

    @MainActor
    @Test
    func testCancelIgnoresLateCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        let previousSettings = AppSettings.store
        ConfigStore.directoryOverride = directory
        AppSettings.useScratchStore("cancel-regression")
        defer {
            ConfigStore.directoryOverride = previous
            AppSettings.store = previousSettings
            try? FileManager.default.removeItem(at: directory)
        }
        try seedConfig(in: directory)
        let runs = RunCounter()
        let model = AppModel(runBoards: { companies, _, receive in
            await runs.start()
            // Simulate a board callback that still arrives after cancellation.
            try? await Task.sleep(for: .milliseconds(50))
            if let company = companies.first {
                await receive(BoardResult(company: company, jobs: []))
            }
        })
        await model.reload()
        model.refreshAfterLaunch()
        while await runs.count == 0 { await Task.yield() }
        model.scrape() // The delayed initial filter observer requests this too.
        model.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.isScraping)
        #expect(await runs.count == 1)
        #expect(model.scanned == 0)
        #expect(model.lastRun == nil)
        #expect(ConfigStore.loadCache() == nil)
    }

    @Test
    func testSearchMatchesAcrossFieldsIgnoringCase() {
        var q = ScrapeQuery(category: JobCategory(name: "all", description: "", include: [], exclude: []))
        var zurich = job("Quant Researcher")
        zurich.company = "Jane Street"
        zurich.location = "Zürich"
        for (search, hit) in [("", true), ("QUANT", true), ("jane street", true), ("zürich", true),
                              ("ZÜRICH", true), ("Zu\u{308}rich", true),
                              ("researcher jane", true), ("trader", false)] {
            q.search = search
            #expect(q.matchesSearch(zurich) == hit, "\(search)")
            #expect(q.matchesSearch(zurich, searchText: ScrapeQuery.searchText(of: zurich)) == hit,
                    "\(search), precomputed")
        }
    }

    @MainActor
    @Test
    func testSearchFollowsResultsAsTheyChange() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ConfigStore.directoryOverride
        ConfigStore.directoryOverride = directory
        defer { ConfigStore.directoryOverride = previous; try? FileManager.default.removeItem(at: directory) }
        let model = AppModel()
        model.list = .favorite
        model.search = "intern"
        #expect(model.visibleJobs.isEmpty)
        // The saved list is built from snapshots, so a search there has to see
        // a role saved after the search was typed.
        model.setSaved(true, for: [job("Software Intern")])
        #expect(model.visibleJobs.map(\.title) == ["Software Intern"])
        model.search = "trader"
        #expect(model.visibleJobs.isEmpty)
    }

    private func seedConfig(in directory: URL) throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QuantJobs/Resources")
        for file in ["companies.json", "categories.json", "locations.json"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(file),
                                             to: directory.appendingPathComponent(file))
        }
    }

    private func job(_ title: String) -> Job {
        var job = Job(company: "Test", title: title, location: "London", url: "https://example.invalid/job", posted: "", department: "", description: "", ats: .greenhouse, tags: [])
        job.matchedCategories = ["swe"]
        job.matchedLevels = ["intern"]
        return job
    }
}
