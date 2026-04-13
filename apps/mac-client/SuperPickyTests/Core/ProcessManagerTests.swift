import Testing
import Foundation
@testable import SuperPicky

@Suite struct ProcessManagerTests {
    @Test func initialState() {
        let pm = ProcessManager(port: 19999)
        #expect(pm.isRunning == false)
        #expect(pm.isReady == false)
        #expect(pm.port == 19999)
    }

    @Test func defaultPort() {
        let pm = ProcessManager()
        #expect(pm.port == 8420)
    }

    @Test func stopWhenNotRunning() {
        let pm = ProcessManager(port: 19999)
        pm.stop()
        #expect(pm.isRunning == false)
        #expect(pm.isReady == false)
    }
}
