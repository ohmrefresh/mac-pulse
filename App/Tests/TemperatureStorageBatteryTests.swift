import Foundation
import Testing
import PulseCore
import PulseCollectors
import PulseEngine
@testable import MacPulse

/// Temperature unit conversion and the wording the Sensors, Battery and Storage pages build.
@MainActor
@Suite struct TemperatureStorageBatteryTests {
    // MARK: Temperature unit

    @Test func convertsBothWays() {
        let f = TemperatureUnit.fahrenheit
        #expect(f.fromCelsius(0) == 32)
        #expect(f.fromCelsius(100) == 212)
        #expect(f.fromCelsius(-40) == -40)
        #expect(abs(f.toCelsius(212) - 100) < 1e-9)
        #expect(TemperatureUnit.celsius.fromCelsius(45) == 45)
        #expect(TemperatureUnit.celsius.toCelsius(45) == 45)
    }

    @Test func formatsTemperatureInEitherUnit() {
        #expect(Format.temperature(45.4, .celsius) == "45°C")
        #expect(Format.temperature(45, .fahrenheit) == "113°F")
        #expect(Format.temperatureFigure(52, .fahrenheit) == ("126", "°F"))
    }

    /// A difference scales by 9/5 and is never offset by 32.
    @Test func changesScaleWithoutOffset() {
        #expect(Format.temperatureChange(2, .celsius) == "2°C")
        #expect(Format.temperatureChange(-5, .fahrenheit) == "9°F")
        #expect(TemperatureUnit.fahrenheit.scale(10) == 18)
    }

    /// The editor shows °F rounded to whole degrees; what it stores converts back to the typed value.
    @Test func fahrenheitThresholdRoundTripsWithoutDrift() {
        let f = TemperatureUnit.fahrenheit
        for typed in [150.0, 199, 200, 203] {
            #expect(f.fromCelsius(f.toCelsius(typed)).rounded() == typed)
        }
    }

    @Test func menuBarTemperatureSegmentFollowsUnit() {
        let inputs = MenuBarInputs(cpuCelsius: 45)
        let segments = MenuBarFormatter.segments([.cpu, .temperature], inputs)
        let f = Format.menuBarSegments(segments, cpuCelsius: 45, unit: .fahrenheit)
        #expect(f.map(\.text) == ["CPU --", "113°F"])
        #expect(Format.menuBarSegments(segments, cpuCelsius: 45, unit: .celsius).map(\.text) == ["CPU --", "45°C"])
        let missing = MenuBarFormatter.segments([.temperature], MenuBarInputs())
        #expect(Format.menuBarSegments(missing, cpuCelsius: nil, unit: .fahrenheit).map(\.text) == ["--°F"])
    }

    @Test func alertThresholdsShowInUnit() {
        let hot = AlertRule(name: "Hot CPU", metric: .cpuTemperatureC, comparator: .above, threshold: 95,
                            duration: 60, severity: .warning, isEnabled: true)
        #expect(RulePhrase.parts(hot).condition == "above 95°C")
        #expect(RulePhrase.parts(hot, unit: .fahrenheit).condition == "above 203°F")
        #expect(Format.alertValue(.cpuPercent, 90, unit: .fahrenheit) == "90%")
    }

    @Test func unitPersists() {
        let name = "MacPulseTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        #expect(AppSettings(metrics: LiveMetrics(), defaults: d).temperatureUnit == .celsius)
        AppSettings(metrics: LiveMetrics(), defaults: d).temperatureUnit = .fahrenheit
        #expect(AppSettings(metrics: LiveMetrics(), defaults: d).temperatureUnit == .fahrenheit)
    }

    // MARK: Sensors

    @Test func thermalDurationOnlyFromWhatWasSeen() {
        let now = Date()
        let launch = now.addingTimeInterval(-3_600)
        // Only the launch reading: the state held at least since launch.
        let onlyLaunch = ThermalSummary.since([(.nominal, launch)], current: .nominal)
        #expect(onlyLaunch == .init(date: launch, atLeast: true))
        #expect(ThermalSummary.headline(.nominal, since: onlyLaunch, now: now)
                == "Running cool — thermal state Nominal for at least 1h 0m")
        // A change seen this session: exactly since then.
        let change = now.addingTimeInterval(-600)
        let changed = ThermalSummary.since([(.nominal, launch), (.serious, change)], current: .serious)
        #expect(changed == .init(date: change, atLeast: false))
        #expect(ThermalSummary.headline(.serious, since: changed, now: now) == "Running hot — thermal state Serious for 10m")
        // Log out of step with the reading, or empty: no duration at all.
        #expect(ThermalSummary.since([(.nominal, launch)], current: .fair) == nil)
        #expect(ThermalSummary.since([], current: .fair) == nil)
        #expect(ThermalSummary.headline(.fair, since: nil) == "Warming up — thermal state Fair")
        // Just launched: "at least" under a minute is left out.
        #expect(ThermalSummary.headline(.nominal, since: .init(date: now.addingTimeInterval(-20), atLeast: true), now: now)
                == "Running cool — thermal state Nominal")
    }

    @Test func cardSparklineCoversFifteenMinutesAndNeedsTwoReadings() {
        let now = Date()
        #expect(TemperatureCard.sparkValues([]) == nil)
        #expect(TemperatureCard.sparkValues([(now, 40)]) == nil)
        let samples: [(time: Date, value: Double)] = [(now.addingTimeInterval(-1_200), 30), (now.addingTimeInterval(-600), 38),
                                                      (now.addingTimeInterval(-5), 40), (now, 41)]
        #expect(TemperatureCard.sparkValues(samples) == [38, 40, 41])
        #expect(TemperatureCard.sparkValues([(now.addingTimeInterval(-5), 40), (now, 41)]) == [40, 41])
    }

    @Test func axisTicksAreRoundInTheDisplayUnit() {
        #expect(TemperatureUnit.celsius.axisTicks(celsius: 0...100) == [0, 25, 50, 75, 100])
        let f = TemperatureUnit.fahrenheit
        let ticks = f.axisTicks(celsius: 0...100)
        #expect(ticks.map { f.fromCelsius($0).rounded() } == [40, 80, 120, 160, 200])
        #expect(ticks.allSatisfy { (0...100).contains($0) })
        #expect(ticks.map { Format.temperature($0, f) } == ["40°F", "80°F", "120°F", "160°F", "200°F"])
    }

    @Test func cardSparklineHasAMinimumSpan() {
        #expect(TemperatureCard.sparkDomain([52, 52, 52]) == 49...55)
        #expect(TemperatureCard.sparkDomain([40, 50]) == 40...50)
        #expect(TemperatureCard.sparkDomain([]) == 0...6)
    }

    /// °F entries store to the nearest half °C, and every whole °F reads back as typed.
    @Test func fahrenheitEntryRoundsToHalfDegreeCelsius() {
        let f = TemperatureUnit.fahrenheit
        #expect(f.storedCelsius(entered: 200) == 93.5)
        #expect(f.storedCelsius(entered: 201) == 94)
        for typed in stride(from: 100.0, through: 250, by: 1) {
            let stored = f.storedCelsius(entered: typed)
            #expect((stored * 2).rounded() == stored * 2)
            #expect(f.threshold(fromCelsius: stored) == typed)
        }
        #expect(TemperatureUnit.celsius.storedCelsius(entered: 93) == 93)
        #expect(TemperatureUnit.celsius.threshold(fromCelsius: 93.5) == 93.5)
        #expect(Format.temperatureThreshold(93.5, .celsius) == "93.5°C")
        #expect(Format.temperatureThreshold(95, .celsius) == "95°C")
        #expect(Format.temperatureThreshold(93.5, .fahrenheit) == "200°F")
        let rule = AlertRule(name: "Hot CPU", metric: .cpuTemperatureC, comparator: .above, threshold: 93.5,
                             duration: 60, severity: .warning, isEnabled: true)
        #expect(RulePhrase.parts(rule).condition == "above 93.5°C")
        #expect(RulePhrase.parts(rule, unit: .fahrenheit).condition == "above 200°F")
    }

    @Test func fanPhrase() {
        #expect(ThermalSummary.fans(rpm: 0, maxRPM: 6_000) == "fans stopped")
        #expect(ThermalSummary.fans(rpm: 2_340, maxRPM: 7_800) == "fans at 30% of max")
        #expect(ThermalSummary.fans(rpm: 2_340, maxRPM: nil).hasPrefix("fans at 2"))
    }

    @Test func thermalDetailHidesWhatIsMissing() {
        let none = SensorsReading(cpuCelsius: nil, ssdCelsius: nil, batteryCelsius: nil, sensors: [], fans: [])
        #expect(ThermalSummary.detail(none, unit: .celsius) == nil)
        #expect(ThermalSummary.detail(nil, unit: .celsius) == nil)
        let some = SensorsReading(cpuCelsius: 45, ssdCelsius: nil, batteryCelsius: nil,
                                  sensors: [.init(name: "PMU tcal", celsius: 52), .init(name: "NAND", celsius: 39)], fans: [])
        #expect(ThermalSummary.detail(some, unit: .celsius) == "Hottest sensor is PMU tcal at 52°C")
        #expect(ThermalSummary.detail(some, unit: .fahrenheit) == "Hottest sensor is PMU tcal at 126°F")
    }

    @Test func sensorRangeScaleIsSharedAndNeverZeroWidth() {
        #expect(SensorRange.scale([]) == nil)
        #expect(SensorRange.scale([30...40, 35...60]) == 30...60)
        #expect(SensorRange.scale([40...41]) == 38.5...42.5)
    }

    // MARK: Battery

    private func battery(charging: Bool, ac: Bool, minutes: Int?) -> BatteryReading {
        BatteryReading(percent: 80, isCharging: charging, onACPower: ac, minutesRemaining: minutes,
                       cycleCount: 67, maximumCapacityPercent: 100)
    }

    @Test func batteryStateLine() {
        let at = Calendar.current.date(bySettingHour: 21, minute: 16, second: 0, of: Date())!
        #expect(BatteryPhrase.state(battery(charging: true, ac: true, minutes: 30), unpluggedAt: nil) == "Charging")
        #expect(BatteryPhrase.state(battery(charging: false, ac: true, minutes: nil), unpluggedAt: nil) == "On AC")
        #expect(BatteryPhrase.state(battery(charging: false, ac: false, minutes: 90), unpluggedAt: nil) == "On battery")
        #expect(BatteryPhrase.state(battery(charging: false, ac: false, minutes: 90), unpluggedAt: at)
                == "On battery · unplugged \(at.formatted(date: .omitted, time: .shortened))")
    }

    @Test func emptyOrFullByNeedsAnEstimate() {
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let clock = { (m: Int) in now.addingTimeInterval(TimeInterval(m) * 60).formatted(date: .omitted, time: .shortened) }
        #expect(BatteryPhrase.clockTime(minutesRemaining: 90, onACPower: false, isCharging: false, now: now) == clock(90))
        #expect(BatteryPhrase.clockTime(minutesRemaining: 20 * 60, onACPower: false, isCharging: false, now: now)
                == "\(clock(20 * 60)) tomorrow")
        #expect(BatteryPhrase.clockTime(minutesRemaining: 45, onACPower: true, isCharging: true, now: now) == clock(45))
        #expect(BatteryPhrase.clockTime(minutesRemaining: nil, onACPower: false, isCharging: false, now: now) == nil)
        #expect(BatteryPhrase.clockTime(minutesRemaining: 30, onACPower: true, isCharging: false, now: now) == nil)
    }

    // MARK: Storage

    @Test func volumeLocationOnlyWhenKnown() {
        let unknown = DiskReading(volumeName: "X", totalBytes: 1, availableBytes: 0)
        #expect(StorageText.isExternal(unknown) == nil)
        #expect(StorageText.isExternal(DiskReading(volumeName: "X", totalBytes: 1, availableBytes: 0, isInternal: true)) == false)
        #expect(StorageText.isExternal(DiskReading(volumeName: "X", totalBytes: 1, availableBytes: 0, isRemovable: true)) == true)
        #expect(StorageText.isExternal(DiskReading(volumeName: "X", totalBytes: 1, availableBytes: 0, isInternal: false)) == true)
        let internalDisk = DiskReading(volumeName: "Macintosh HD", totalBytes: 995_000_000_000, availableBytes: 404_000_000_000,
                                       isInternal: true)
        #expect(StorageText.descriptor(internalDisk) == "995 GB · internal")
        #expect(StorageText.descriptor(DiskReading(volumeName: "X", totalBytes: 995_000_000_000, availableBytes: 0)) == "995 GB")
    }

    @Test func freeSpaceTrend() {
        #expect(StorageText.trendDelta([4e11, 3.9e11, 3.8e11]) == nil)
        #expect(StorageText.trendDelta([4.45e11, 4.3e11, 4.2e11, 4.04e11]) == -41_000_000_000)
        #expect(StorageText.signedBytes(-41_000_000_000) == "\u{2212}41 GB")
        #expect(StorageText.signedBytes(3_200_000_000) == "+3.2 GB")
        let now = Date()
        #expect(StorageText.trendTitle(since: now.addingTimeInterval(-2 * 86_400), now: now) == "2-day trend")
        #expect(StorageText.trendTitle(since: now.addingTimeInterval(-3_600), now: now) == "1-day trend")
        #expect(StorageText.trendTitle(since: now.addingTimeInterval(-40 * 86_400), now: now) == "30-day trend")
    }
}
