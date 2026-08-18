// The window supplies @main on Apple platforms. Off them there is no window, so
// this is the entry point: fetch every board, then write the page the phone reads.
//
// This exists so the scheduled fetch can run somewhere that is not a Mac. It is
// the same adapters, matchers and exporter the app uses — the point of keeping one
// implementation is that the server is not a second one.
#if !canImport(SwiftUI)
import Foundation

@main
struct LinuxMain {
    static func main() async {
        let out = CommandLine.arguments.dropFirst().first ?? "web/index.html"
        let model = await AppModel()
        await model.reload()
        await model.scrape(full: true)

        // scrape() is fire-and-forget so the window can fill in as boards answer;
        // with no window to fill, wait for it to settle before writing anything.
        var quiet = 0
        while quiet < 6 {
            try? await Task.sleep(for: .seconds(5))
            let busy = await model.isScraping
            quiet = busy ? 0 : quiet + 1
        }
        let count = await model.jobs.count
        FileHandle.standardError.write(Data("fetched \(count) postings\n".utf8))
        _ = await WebExport.run(to: out)
    }
}
#endif
