import Testing
@testable import PulseCollectors

@Suite struct WiFiCollectorTests {
    // CWPHYMode raw values: none 0, 11a 1, 11b 2, 11g 3, 11n 4, 11ac 5, 11ax 6, 11be 7.
    @Test func phyLabels() {
        #expect(WiFiCollector.phyLabel(mode: 7, sixGHz: false) == "Wi‑Fi 7")
        #expect(WiFiCollector.phyLabel(mode: 7, sixGHz: true) == "Wi‑Fi 7")
        #expect(WiFiCollector.phyLabel(mode: 6, sixGHz: true) == "Wi‑Fi 6E")
        #expect(WiFiCollector.phyLabel(mode: 6, sixGHz: false) == "Wi‑Fi 6")
        #expect(WiFiCollector.phyLabel(mode: 5, sixGHz: false) == "Wi‑Fi 5")
        #expect(WiFiCollector.phyLabel(mode: 4, sixGHz: false) == "Wi‑Fi 4")
        for older in 0...3 { #expect(WiFiCollector.phyLabel(mode: older, sixGHz: false) == nil) }
        #expect(WiFiCollector.phyLabel(mode: 99, sixGHz: false) == nil)
    }

    /// Labels use the same non-breaking hyphen as the interface kind, so they never wrap mid-word.
    @Test func labelsShareTheInterfaceKindSpelling() {
        #expect(WiFiCollector.phyLabel(mode: 6, sixGHz: false)!.hasPrefix(NetworkCollector.wifiKind))
    }

    @Test func zeroRSSIMeansUnknown() {
        #expect(WiFiCollector.rssi(0) == nil)
        #expect(WiFiCollector.rssi(-54) == -54)
    }

    /// No Wi‑Fi on CI: an absent interface reads as nil; a present one reports a plausible RSSI.
    @Test func livePlausibility() {
        guard let name = NetworkCollector.primaryInterface(),
              NetworkCollector.interfaceKind(name) == NetworkCollector.wifiKind,
              let reading = WiFiCollector.sample(interface: name) else { return }
        if let rssi = reading.rssiDBm { #expect((-120 ... -1).contains(rssi)) }
    }

    @Test func localIPv4SkipsLinkLocal() {
        #expect(NetworkConfigCollector.localIPv4(["169.254.3.4", "192.168.1.42"]) == "192.168.1.42")
        #expect(NetworkConfigCollector.localIPv4(["169.254.3.4"]) == nil)
        #expect(NetworkConfigCollector.localIPv4([]) == nil)
    }

    @Test func liveLocalIPv4IsAnAddressOfThePrimaryInterface() {
        var collector = NetworkCollector()
        let reading = collector.sample()
        guard let name = reading.interface, let ip = reading.localIPv4 else { return }
        #expect(NetworkConfigCollector.ipv4Addresses()[name]?.contains(ip) == true)
    }
}
