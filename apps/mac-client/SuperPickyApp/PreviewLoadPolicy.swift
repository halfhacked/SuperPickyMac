import Foundation
import CoreGraphics

/// One of four load strategies `AsyncPreviewImage.body.task` chooses
/// between for the *primary* image load on a selection change. The
/// dwell-preload tail and the zoom/state `onChange` upgrade handlers
/// run separately in the same view; this enum only governs the first
/// pass.
enum LoadAction: Equatable, Sendable {
    /// In-RAM full-res cache hit. Take it regardless of zoom/skim — it
    /// is free (no decode, no allocation) and full quality.
    case useCachedFullRes
    /// Zoom > 1 with no skim signal: decode straight to full resolution
    /// so a deliberate zoomed inspection isn't soft-then-sharp.
    case loadFullResDirect
    /// 2000 px preview-tier RAM hit.
    case useCachedPreview
    /// 2000 px preview-tier decode (skim-in-zoom or fit-mode default).
    case loadPreview
}

/// Decide which load path `AsyncPreviewImage.body.task` should take for
/// the next photo. Pure: takes only observable inputs, returns a tagged
/// enum. Lets the policy be exhaustively tested without SwiftUI or
/// ImageIO.
///
/// Decision order (each rule short-circuits):
/// 1. Full-res RAM hit → reuse it (free, sharp). Wins even in skim.
/// 2. Zoom > 1 and not in skim → take the full-res decode path.
/// 3. Preview-tier RAM hit → reuse it.
/// 4. Otherwise → 2000 px decode (skim-in-zoom takes this; so does fit).
func decidePrimaryLoad(
    state: NavigationStateMonitor.State,
    zoomScale: CGFloat,
    hasFullRes: Bool,
    hasPreview: Bool
) -> LoadAction {
    if hasFullRes { return .useCachedFullRes }
    if zoomScale > 1.0 && state != .skim { return .loadFullResDirect }
    if hasPreview { return .useCachedPreview }
    return .loadPreview
}
