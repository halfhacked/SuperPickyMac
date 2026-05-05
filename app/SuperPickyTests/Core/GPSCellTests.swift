import Testing
import Foundation
import SuperPickyInference

@Suite struct GPSCellTests {
    @Test func sameCellProducesSameKey() {
        let a = GPSCell.key(lat: 47.6062, lon: -122.3321)
        let b = GPSCell.key(lat: 47.6100, lon: -122.3400)
        #expect(a == b)
    }

    @Test func differentCellsProduceDifferentKeys() {
        let seattle = GPSCell.key(lat: 47.6, lon: -122.3)
        let portland = GPSCell.key(lat: 45.5, lon: -122.6)
        #expect(seattle != portland)
    }

    @Test func negativeLatitudesDoNotCollide() {
        let northern = GPSCell.key(lat: 1.05, lon: 0.0)
        let southern = GPSCell.key(lat: -1.05, lon: 0.0)
        #expect(northern != southern)
    }

    @Test func negativeLongitudesDoNotCollide() {
        let eastern = GPSCell.key(lat: 0.0, lon: 1.05)
        let western = GPSCell.key(lat: 0.0, lon: -1.05)
        #expect(eastern != western)
    }

    @Test func antipodalPointsDoNotCollide() {
        let a = GPSCell.key(lat: 10.0, lon: 20.0)
        let b = GPSCell.key(lat: -10.0, lon: -20.0)
        #expect(a != b)
    }
}
