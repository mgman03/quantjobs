//  QuantJobs — a native macOS front end for the quantjobs scraper.
//
//  Author:  Mykhaylo Gershman <mgershman@ethz.ch>
//  License: MIT (see LICENSE)

import SwiftUI
import AppKit

@main
struct QuantJobsApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        // `--check` runs a scrape in the terminal instead of opening a window,
        // which is how the port gets diffed against the Python CLI.
        if CommandLine.arguments.contains("--check") { HeadlessCheck.run() }
    }

    var body: some Scene {
        WindowGroup("Quant Jobs") {
            ContentView(model: model)
                // 900 plus a 224 sidebar and a 260 inspector overruns a
                // 1440 window, which is what forced the sidebar to be clipped.
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1440, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updater.check(quietly: false) }
                }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scrape") {
                Button(model.isScraping ? "Cancel Scrape" : "Refresh All Boards") {
                    model.isScraping ? model.cancel() : model.scrape(full: true)
                }
                .keyboardShortcut("r")

                Divider()

                Toggle("Merge the same role across offices", isOn: $model.mergeRoles)
                Toggle("Search full descriptions (slower)", isOn: $model.deep)
                Toggle("Record this run in the seen list", isOn: $model.recordState)

                Divider()

                Picker("Firm tag", selection: $model.tagFilter) {
                    Text("Any tag").tag(String?.none)
                    ForEach(model.allTags, id: \.self) { Text($0).tag(String?.some($0)) }
                }

                Divider()

                Button("Clear All Filters", action: model.clearFilters)
                    .disabled(!model.hasExtraFilters)

                Divider()

                Button("Manage Boards…") { model.showBoardEditor = true }

                Divider()

                Button("Reload Config") { Task { await model.reload() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Forget Seen Postings", action: model.resetSeen)
            }
        }
    }
}

/// A SwiftUI app built as an SPM executable launches without a dock presence
/// unless we ask for one.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    /// We don't take part in window restoration — see NSQuitAlwaysKeepsWindows
    /// in the Info.plist. Answering this keeps AppKit from logging about it.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }
}
