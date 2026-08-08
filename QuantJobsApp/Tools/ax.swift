// Inspect and drive the running app through the Accessibility API.
//
//   ax list              every control, indented, with role, label and frame
//   ax click <text>      press the first pressable control whose label matches
//   ax select <n>        select row n of the first table
//
// Written against AXUIElement rather than AppleScript because System Events'
// `entire contents` can't be indexed on a SwiftUI window — it returns
// references that fail to coerce, so a repeat loop over it yields nothing.
//
// Needs Accessibility permission for the *responsible* process, which is the
// terminal this runs from, not this binary.
import ApplicationServices
import AppKit

let bundleID = "local.quantjobs.app"

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
    else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute as String),
          let s = attribute(element, kAXSizeAttribute as String) else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

/// Whatever a human would call this control. SwiftUI puts the useful text in
/// different attributes depending on the control, and `help` is where a
/// `.help()` modifier lands — which is the only label an icon-only button has.
func label(_ element: AXUIElement) -> String {
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                 kAXHelpAttribute] as [String] {
        if let s = string(element, name), !s.isEmpty { return s }
    }
    return ""
}

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
else { FileHandle.standardError.write(Data("app not running\n".utf8)); exit(1) }

let axApp = AXUIElementCreateApplication(app.processIdentifier)
// The main window specifically. Falling back to `children.first` picked up the
// menu bar instead whenever the window wasn't the first child, which silently
// walked the wrong tree — 900 menu items and none of the app's own controls.
guard let window = children(axApp).first(where: {
        string($0, kAXRoleAttribute as String) == kAXWindowRole as String })
else {
    FileHandle.standardError.write(Data(
        "no AXWindow — the app may be hidden or have no open window\n".utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
let verb = args.first ?? "list"

// MARK: - list

func walk(_ element: AXUIElement, depth: Int, into out: inout [String]) {
    let role = string(element, kAXRoleAttribute as String) ?? "?"
    let text = label(element)
    let acts = actions(element).filter { $0 != kAXShowMenuAction as String }
    // Only rows worth acting on or reading: containers with no label are noise.
    let interesting = !text.isEmpty || acts.contains(kAXPressAction as String)
    if interesting {
        let box = frame(element).map {
            String(format: " [%.0f,%.0f %.0fx%.0f]", $0.minX, $0.minY, $0.width, $0.height)
        } ?? ""
        let pressable = acts.contains(kAXPressAction as String) ? " ⏎" : ""
        out.append(String(repeating: "  ", count: depth)
                   + "\(role)\(pressable)  \(text)\(box)")
    }
    for child in children(element) {
        walk(child, depth: interesting ? depth + 1 : depth, into: &out)
    }
}

/// Whether this element or anything under it shows the given text.
func describes(_ element: AXUIElement, _ needle: String) -> Bool {
    if label(element).lowercased().contains(needle) { return true }
    return children(element).contains { describes($0, needle) }
}

/// Every pressable control, flattened, for matching by label.
func pressables(_ element: AXUIElement, into out: inout [(AXUIElement, String, String)]) {
    let role = string(element, kAXRoleAttribute as String) ?? "?"
    if actions(element).contains(kAXPressAction as String) {
        out.append((element, role, label(element)))
    }
    for child in children(element) { pressables(child, into: &out) }
}

switch verb {
case "list":
    var out: [String] = []
    walk(window, depth: 0, into: &out)
    print(out.joined(separator: "\n"))

case "controls":
    var found: [(AXUIElement, String, String)] = []
    pressables(window, into: &found)
    for (element, role, text) in found where !text.isEmpty {
        let box = frame(element).map { String(format: "%.0fx%.0f", $0.width, $0.height) } ?? ""
        print("\(role)\t\(box)\t\(text)")
    }

case "click":
    guard args.count > 1 else { exit(2) }
    let needle = args[1].lowercased()
    var found: [(AXUIElement, String, String)] = []
    pressables(window, into: &found)
    // Exact label first, then a contains match, so "Both" can't hit "Bothell".
    let hit = found.first { $0.2.lowercased() == needle }
           ?? found.first { $0.2.lowercased().contains(needle) }
    guard let (element, role, text) = hit else {
        print("no pressable control matching \"\(args[1])\"")
        exit(3)
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    print(result == .success ? "pressed \(role) \"\(text)\""
                             : "press failed on \"\(text)\" (\(result.rawValue))")

case "select":
    guard args.count > 1, let n = Int(args[1]) else { exit(2) }
    func firstTable(_ element: AXUIElement) -> AXUIElement? {
        if string(element, kAXRoleAttribute as String) == kAXTableRole as String {
            return element
        }
        for child in children(element) {
            if let t = firstTable(child) { return t }
        }
        return nil
    }
    guard let table = firstTable(window) else { print("no table"); exit(3) }
    let rows = children(table).filter {
        string($0, kAXRoleAttribute as String) == kAXRowRole as String }
    guard n >= 0, n < rows.count else { print("row \(n) of \(rows.count)"); exit(3) }
    AXUIElementSetAttributeValue(rows[n], kAXSelectedAttribute as CFString,
                                 kCFBooleanTrue)
    print("selected row \(n) of \(rows.count)")

case "pick":
    // Sidebar list rows carry their label in a nested AXStaticText and expose no
    // press action, so match on the text and select the row that contains it.
    guard args.count > 1 else { exit(2) }
    let needle = args[1].lowercased()
    func rowContaining(_ element: AXUIElement) -> AXUIElement? {
        let isRow = string(element, kAXRoleAttribute as String) == kAXRowRole as String
        if isRow, describes(element, needle) { return element }
        for child in children(element) {
            if let hit = rowContaining(child) { return hit }
        }
        return nil
    }
    guard let row = rowContaining(window) else {
        print("no row containing \"\(args[1])\""); exit(3)
    }
    AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    print("picked row containing \"\(args[1])\"")

default:
    print("verbs: list | controls | click <text> | select <n> | pick <text>")
    exit(2)
}
