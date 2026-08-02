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
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1440, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scrape") {
                Button(model.isScraping ? "Cancel Scrape" : "Scrape Now") {
                    model.isScraping ? model.cancel() : model.scrape()
                }
                .keyboardShortcut("r")

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
}
