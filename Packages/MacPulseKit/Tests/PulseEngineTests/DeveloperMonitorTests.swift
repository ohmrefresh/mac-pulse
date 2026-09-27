import Foundation
import Testing
import PulseCore
import PulseCollectors
@testable import PulseEngine

@Suite struct DeveloperMonitorTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func c(_ id: String, _ state: String) -> DockerContainer {
        DockerContainer(id: id, name: "svc-\(id)", image: "img", state: state, status: "")
    }

    @Test func containerStartStopEvents() {
        let old = [c("a", "running"), c("b", "exited")]
        let new = [c("a", "exited"), c("b", "running"), c("n", "running"), c("m", "exited")]
        #expect(DeveloperMonitor.containerEvents(old: old, new: new, at: t).map(\.title)
                == ["Container svc-a stopped", "Container svc-b started", "Container svc-n started"])
    }

    @Test func noEventsWhenDockerAppearsOrDisappears() {
        #expect(DeveloperMonitor.containerEvents(old: nil, new: [c("a", "running")], at: t).isEmpty)
        #expect(DeveloperMonitor.containerEvents(old: [c("a", "running")], new: nil, at: t).isEmpty)
    }

    @MainActor
    @Test func liveMetricsPostsContainerEvents() {
        let m = LiveMetrics()
        m.apply(DeveloperSnapshot(containers: [c("a", "exited")]))
        m.apply(DeveloperSnapshot(containers: [c("a", "running")]))
        #expect(m.recentEvents.last?.title == "Container svc-a started")
        #expect(m.developer.containers?.first?.isRunning == true)
    }
}
