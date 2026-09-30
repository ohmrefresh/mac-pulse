import CoreWLAN
import Foundation

public struct WiFiReading: Sendable, Equatable {
    /// Signal strength, e.g. -54. Nil when CoreWLAN does not report it.
    public var rssiDBm: Int?
    /// Wi‑Fi generation of the current link, e.g. "Wi‑Fi 6E"; nil for 802.11a/b/g or unknown.
    public var phy: String?

    public init(rssiDBm: Int?, phy: String?) {
        self.rssiDBm = rssiDBm
        self.phy = phy
    }
}

/// Link details of a Wi‑Fi interface via CoreWLAN. Never reads the SSID or BSSID
/// (those need Location Services); only signal strength and PHY mode.
public enum WiFiCollector {
    /// Nil when `interface` is not a Wi‑Fi interface CoreWLAN knows.
    public static func sample(interface name: String) -> WiFiReading? {
        guard let wlan = CWWiFiClient.shared().interface(withName: name) else { return nil }
        let sixGHz = wlan.wlanChannel()?.channelBand == .band6GHz
        return WiFiReading(rssiDBm: rssi(wlan.rssiValue()),
                           phy: phyLabel(mode: wlan.activePHYMode().rawValue, sixGHz: sixGHz))
    }

    /// CoreWLAN reports 0 when the RSSI is unknown (e.g. not associated).
    static func rssi(_ value: Int) -> Int? { value == 0 ? nil : value }

    /// Label from a `CWPHYMode` raw value (11n 4, 11ac 5, 11ax 6, 11be 7). 802.11ax on a
    /// 6 GHz channel is Wi‑Fi 6E. Older modes have no generation name worth showing.
    public static func phyLabel(mode: Int, sixGHz: Bool) -> String? {
        switch mode {
        case 7: "\(NetworkCollector.wifiKind) 7"
        case 6: sixGHz ? "\(NetworkCollector.wifiKind) 6E" : "\(NetworkCollector.wifiKind) 6"
        case 5: "\(NetworkCollector.wifiKind) 5"
        case 4: "\(NetworkCollector.wifiKind) 4"
        default: nil
        }
    }
}
