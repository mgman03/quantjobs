#if canImport(SwiftUI)
import SwiftUI

/// The pipeline's colour scale.
///
/// It lives here rather than on `Stage` so the model stays free of SwiftUI: the
/// scraper has to build where SwiftUI does not exist. It is still one definition
/// three views share, which is why it was put on the stage in the first place.
extension Stage {
    var tint: Color {
        switch self {
        case .applied: .secondary
        case .assessment, .interview, .final: .orange
        case .offer: .green
        case .rejected: .red
        case .withdrawn: .secondary
        }
    }
}
#endif
