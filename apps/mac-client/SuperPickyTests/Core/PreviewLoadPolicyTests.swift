import Testing
import Foundation
import CoreGraphics
@testable import SuperPicky

/// Exhaustive tests for `decidePrimaryLoad`. The function picks one of four
/// load actions for `AsyncPreviewImage.body.task` based on the
/// `NavigationStateMonitor` state, the current zoom scale, and whether
/// either RAM cache currently has the photo.
///
/// Pinning rule from PreviewView.swift:211 — an in-RAM full-res hit ALWAYS
/// wins, regardless of zoom or skim state — because it's free (no decode,
/// no allocation) and full quality.
struct PreviewLoadPolicyTests {

    // MARK: - .useCachedFullRes wins everywhere

    @Test func cachedFullResWinsAtFitNonSkim() {
        let action = decidePrimaryLoad(state: .active, zoomScale: 1.0,
                                       hasFullRes: true, hasPreview: false)
        #expect(action == .useCachedFullRes)
    }

    @Test func cachedFullResWinsZoomedNonSkim() {
        let action = decidePrimaryLoad(state: .dwell, zoomScale: 2.0,
                                       hasFullRes: true, hasPreview: true)
        #expect(action == .useCachedFullRes)
    }

    @Test func cachedFullResWinsEvenInSkim() {
        // PreviewView.swift:211 rule: full-res RAM hit beats the
        // 2000 px preview path even during fast scrubbing.
        let action = decidePrimaryLoad(state: .skim, zoomScale: 2.0,
                                       hasFullRes: true, hasPreview: false)
        #expect(action == .useCachedFullRes)
    }

    // MARK: - Zoomed, not skim → load full-res direct

    @Test func zoomedActiveLoadsFullResDirect() {
        let action = decidePrimaryLoad(state: .active, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadFullResDirect)
    }

    @Test func zoomedDwellLoadsFullResDirect() {
        let action = decidePrimaryLoad(state: .dwell, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .loadFullResDirect)
    }

    @Test func zoomedIdleLoadsFullResDirect() {
        let action = decidePrimaryLoad(state: .idle, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadFullResDirect)
    }

    // MARK: - Skim in zoom → preview-tier path

    @Test func skimZoomedUsesCachedPreview() {
        let action = decidePrimaryLoad(state: .skim, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .useCachedPreview)
    }

    @Test func skimZoomedLoadsPreviewWhenColdCache() {
        let action = decidePrimaryLoad(state: .skim, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadPreview)
    }

    // MARK: - Fit (zoom == 1) → preview-tier path regardless of state

    @Test func fitActiveUsesCachedPreview() {
        let action = decidePrimaryLoad(state: .active, zoomScale: 1.0,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .useCachedPreview)
    }

    @Test func fitSkimLoadsPreview() {
        let action = decidePrimaryLoad(state: .skim, zoomScale: 1.0,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadPreview)
    }

    @Test func fitDwellUsesCachedPreview() {
        let action = decidePrimaryLoad(state: .dwell, zoomScale: 1.0,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .useCachedPreview)
    }
}
