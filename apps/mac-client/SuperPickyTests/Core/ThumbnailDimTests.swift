import Testing
import Foundation
@testable import SuperPicky

@Suite struct ThumbnailDimTests {
    @Test func selectedNotInBurstKeepsEverythingOpaque() {
        let other = UUID()
        #expect(ThumbnailCell.shouldDim(photoBurstGroupID: nil, selectedBurstGroupID: nil) == false)
        #expect(ThumbnailCell.shouldDim(photoBurstGroupID: other, selectedBurstGroupID: nil) == false)
    }

    @Test func sameBurstIsNotDimmed() {
        let burst = UUID()
        #expect(ThumbnailCell.shouldDim(photoBurstGroupID: burst, selectedBurstGroupID: burst) == false)
    }

    @Test func differentBurstIsDimmed() {
        let burstA = UUID()
        let burstB = UUID()
        #expect(ThumbnailCell.shouldDim(photoBurstGroupID: burstA, selectedBurstGroupID: burstB) == true)
    }

    @Test func singletonThumbnailIsDimmedWhenSelectedInBurst() {
        let burst = UUID()
        #expect(ThumbnailCell.shouldDim(photoBurstGroupID: nil, selectedBurstGroupID: burst) == true)
    }
}
