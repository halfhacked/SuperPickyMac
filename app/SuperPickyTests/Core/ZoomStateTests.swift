import Testing
import Foundation
@testable import SuperPicky

@Suite struct ZoomStateTests {

    /// Convert a view-space point to the image-space point it maps to.
    private func imagePoint(viewPoint: CGPoint, viewSize: CGSize, scale: CGFloat, offset: CGSize) -> CGPoint {
        let cx = viewSize.width / 2
        let cy = viewSize.height / 2
        return CGPoint(
            x: (viewPoint.x - cx - offset.width) / scale,
            y: (viewPoint.y - cy - offset.height) / scale
        )
    }

    @Test func zoomAtCenter_pointStaysFixed() {
        let state = ZoomState()
        let viewSize = CGSize(width: 800, height: 600)
        let mouse = CGPoint(x: 400, y: 300)

        let before = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)
        state.toggleFitActualPixelsAt(imagePixelWidth: 3200, viewSize: viewSize, mouseInView: mouse)
        let after = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)

        #expect(abs(before.x - after.x) < 0.01)
        #expect(abs(before.y - after.y) < 0.01)
        #expect(state.scale == 4.0)
    }

    @Test func zoomAtTopLeft_pointStaysFixed() {
        let state = ZoomState()
        let viewSize = CGSize(width: 800, height: 600)
        let mouse = CGPoint(x: 100, y: 50)

        let before = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)
        state.toggleFitActualPixelsAt(imagePixelWidth: 2400, viewSize: viewSize, mouseInView: mouse)
        let after = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)

        #expect(abs(before.x - after.x) < 0.01)
        #expect(abs(before.y - after.y) < 0.01)
    }

    @Test func zoomAtBottomRight_pointStaysFixed() {
        let state = ZoomState()
        let viewSize = CGSize(width: 800, height: 600)
        let mouse = CGPoint(x: 750, y: 550)

        let before = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)
        state.toggleFitActualPixelsAt(imagePixelWidth: 4000, viewSize: viewSize, mouseInView: mouse)
        let after = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)

        #expect(abs(before.x - after.x) < 0.01)
        #expect(abs(before.y - after.y) < 0.01)
    }

    @Test func zoomAtArbitraryPoint_pointStaysFixed() {
        let state = ZoomState()
        let viewSize = CGSize(width: 1200, height: 800)
        let mouse = CGPoint(x: 273, y: 519)

        let before = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)
        state.toggleFitActualPixelsAt(imagePixelWidth: 6000, viewSize: viewSize, mouseInView: mouse)
        let after = imagePoint(viewPoint: mouse, viewSize: viewSize, scale: state.scale, offset: state.offset)

        #expect(abs(before.x - after.x) < 0.01)
        #expect(abs(before.y - after.y) < 0.01)
    }

    @Test func zoomOut_resetsToFit() {
        let state = ZoomState()
        let viewSize = CGSize(width: 800, height: 600)
        let mouse = CGPoint(x: 200, y: 150)

        state.toggleFitActualPixelsAt(imagePixelWidth: 3200, viewSize: viewSize, mouseInView: mouse)
        #expect(state.scale == 4.0)

        state.toggleFitActualPixelsAt(imagePixelWidth: 3200, viewSize: viewSize, mouseInView: mouse)
        #expect(state.scale == 1.0)
        #expect(state.offset == .zero)
    }

    @Test func doubleToggle_returnsToOriginal() {
        let state = ZoomState()
        let viewSize = CGSize(width: 800, height: 600)
        let mouse = CGPoint(x: 350, y: 420)

        state.toggleFitActualPixelsAt(imagePixelWidth: 4800, viewSize: viewSize, mouseInView: mouse)
        state.toggleFitActualPixelsAt(imagePixelWidth: 4800, viewSize: viewSize, mouseInView: mouse)

        #expect(state.scale == 1.0)
        #expect(state.offset.width == 0)
        #expect(state.offset.height == 0)
    }
}
