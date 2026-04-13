import Testing
import Foundation
@testable import SuperPicky

@Suite struct ZoomStateTests {
    // MARK: - Initial state

    @Test func initialStateIsFitToView() {
        let state = ZoomState()
        #expect(state.scale == 1.0)
        #expect(state.offset == .zero)
    }

    // MARK: - Zoom

    @Test func zoomInIncreasesScale() {
        let state = ZoomState()
        state.zoom(by: 1.5)
        #expect(state.scale == 1.5)
    }

    @Test func zoomOutDecreasesScale() {
        let state = ZoomState()
        state.zoom(by: 0.5)
        #expect(state.scale == 0.5)
    }

    @Test func zoomClampsToMinimum() {
        let state = ZoomState()
        state.zoom(by: 0.1) // Would be 0.1, below 0.5 min
        #expect(state.scale == ZoomState.minScale)
    }

    @Test func zoomClampsToMaximum() {
        let state = ZoomState()
        state.zoom(by: 20.0) // Would be 20.0, above 10.0 max
        #expect(state.scale == ZoomState.maxScale)
    }

    @Test func zoomToOneOrBelowResetsOffset() {
        let state = ZoomState()
        state.scale = 2.0
        state.offset = CGSize(width: 100, height: 50)
        state.zoom(by: 0.5) // 2.0 * 0.5 = 1.0
        #expect(state.scale == 1.0)
        #expect(state.offset == .zero)
    }

    // MARK: - Toggle fit / actual pixels

    @Test func toggleFromFitZoomsToActualPixels() {
        let state = ZoomState()
        // Image is 4000px wide, view is 1000px wide → actual = 4.0x
        state.toggleFitActualPixels(imagePixelWidth: 4000, viewWidth: 1000)
        #expect(state.scale == 4.0)
    }

    @Test func toggleFromZoomedReturnsFit() {
        let state = ZoomState()
        state.scale = 4.0
        state.offset = CGSize(width: 50, height: 30)
        state.toggleFitActualPixels(imagePixelWidth: 4000, viewWidth: 1000)
        #expect(state.scale == 1.0)
        #expect(state.offset == .zero)
    }

    @Test func toggleClampsActualPixelsToMax() {
        let state = ZoomState()
        // Image is 20000px, view is 1000px → would be 20x, clamped to 10x
        state.toggleFitActualPixels(imagePixelWidth: 20000, viewWidth: 1000)
        #expect(state.scale == ZoomState.maxScale)
    }

    // MARK: - Pan

    @Test func panUpdatesOffsetWhenZoomed() {
        let state = ZoomState()
        state.scale = 2.0
        state.pan(by: CGSize(width: 10, height: 20))
        #expect(state.offset == CGSize(width: 10, height: 20))
    }

    @Test func panAccumulatesOffset() {
        let state = ZoomState()
        state.scale = 2.0
        state.pan(by: CGSize(width: 10, height: 20))
        state.pan(by: CGSize(width: 5, height: -10))
        #expect(state.offset == CGSize(width: 15, height: 10))
    }

    @Test func panIgnoredWhenAtFitScale() {
        let state = ZoomState()
        state.pan(by: CGSize(width: 100, height: 100))
        #expect(state.offset == .zero)
    }

    @Test func panIgnoredWhenBelowFitScale() {
        let state = ZoomState()
        state.scale = 0.8
        state.pan(by: CGSize(width: 100, height: 100))
        #expect(state.offset == .zero)
    }

    // MARK: - Reset

    @Test func resetRestoresInitialState() {
        let state = ZoomState()
        state.scale = 3.0
        state.offset = CGSize(width: 200, height: -100)
        state.reset()
        #expect(state.scale == 1.0)
        #expect(state.offset == .zero)
    }
}
