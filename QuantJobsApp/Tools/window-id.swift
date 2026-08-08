// Prints the CoreGraphics window id of an app's main window, or nothing.
//
// Exists so shot.sh can capture a specific window instead of the whole screen:
// capturing by id means the app is never raised and nothing else on the desktop
// leaks into the image. JXA can reach CGWindowListCopyWindowInfo too, but it
// hands back a CFArray that `ObjC.deepUnwrap` won't turn into a JS array.
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Quant Jobs"

guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
        as? [[String: Any]] else { exit(1) }

// The largest layer-0 window: layer 0 excludes tooltips, popovers and menus,
// and "largest" picks the document window over any panel of the same app.
var best = 0, bestArea: CGFloat = 0
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String,
          owner.contains(wanted),
          (w[kCGWindowLayer as String] as? Int) == 0,
          let bounds = w[kCGWindowBounds as String] as? [String: CGFloat]
    else { continue }
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if area > bestArea {
        bestArea = area
        best = w[kCGWindowNumber as String] as? Int ?? 0
    }
}
guard best != 0 else { exit(2) }
print(best)
