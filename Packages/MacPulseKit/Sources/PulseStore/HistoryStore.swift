import Foundation
import GRDB
import PulseCore

/// How much history to keep (PRD §13 presets). Caps every tier.
public enum RetentionPreset: Int, CaseIterable, Sendable, Codable {
    case oneHour = 3_600
    case sixHours = 21_600
    case oneDay = 86_400
    case sevenDays = 604_800
    case thirtyDays = 2_592_000

    public var seconds: Int64 { Int64(rawValue) }
}

public struct HistoryPoint: Sendable, Equatable {
    public var time: Date
    public var min: Double
    public var avg: Double
    public var max: Double
}

public struct ProcessSample: Sendable, Equatable {
    public var time: Date
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public init(time: Date, pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.time = time
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// Tiered time-series history (PRD §13): raw 1 s samples for 1 h, then min/avg/max aggregates at
/// 10 s (24 h), 1 min (7 d) and 5 min (30 d). Aggregates are built incrementally on every write for
/// completed buckets only, tracked by a per-tier watermark, so each tier covers its full window.
public final class HistoryStore: Sendable {
    struct Tier: Sendable {
        let table: String
        let bucketSeconds: Int64
        let keepSeconds: Int64
        /// Nil for the raw tier.
        let source: String?
    }

    static let raw = Tier(table: "samples_1s", bucketSeconds: 1, keepSeconds: 3_600, source: nil)
    static let aggregates = [
        Tier(table: "agg_10s", bucketSeconds: 10, keepSeconds: 86_400, source: "samples_1s"),
        Tier(table: "agg_1m", bucketSeconds: 60, keepSeconds: 604_800, source: "agg_10s"),
        Tier(table: "agg_5m", bucketSeconds: 300, keepSeconds: 2_592_000, source: "agg_1m"),
    ]
    static let processKeepSeconds: Int64 = 86_400

    private let db: any DatabaseWriter

    /// - Parameter url: SQLite file (WAL mode). Nil opens an in-memory database, for tests.
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try DatabasePool(path: url.path)
        } else {
            db = try DatabaseQueue()
        }
        try Self.migrator.migrate(db)
    }

    public static func defaultURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "MacPulse/history.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE samples_1s (metric TEXT NOT NULL, ts INTEGER NOT NULL, value REAL NOT NULL,
                                         PRIMARY KEY (metric, ts)) WITHOUT ROWID;
                CREATE TABLE process_samples (ts INTEGER NOT NULL, pid INTEGER NOT NULL, name TEXT NOT NULL,
                                              cpu REAL NOT NULL, mem INTEGER NOT NULL);
                CREATE INDEX process_samples_ts ON process_samples (ts);
                CREATE TABLE rollup_state (tier TEXT PRIMARY KEY NOT NULL, done_until INTEGER NOT NULL) WITHOUT ROWID;
                """)
            for tier in aggregates {
                try db.execute(sql: """
                    CREATE TABLE \(tier.table) (metric TEXT NOT NULL, bucket INTEGER NOT NULL,
                                                min REAL NOT NULL, avg REAL NOT NULL, max REAL NOT NULL,
                                                count INTEGER NOT NULL, PRIMARY KEY (metric, bucket)) WITHOUT ROWID
                    """)
            }
        }
        m.registerMigration("v2-timeline") { db in
            try db.execute(sql: """
                CREATE TABLE timeline_events (id TEXT PRIMARY KEY NOT NULL, ts REAL NOT NULL, category TEXT NOT NULL,
                                              severity INTEGER NOT NULL, title TEXT NOT NULL, detail TEXT);
                CREATE INDEX timeline_events_ts ON timeline_events (ts);
                """)
        }
        return m
    }

    // MARK: Writing

    /// Inserts a batch, rolls up completed buckets and prunes — all in one transaction.
    public func write(samples: [MetricSample], processes: [ProcessSample], events: [TimelineEvent] = [],
                      now: Date, retention: RetentionPreset) throws {
        let nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
        try db.write { db in
            let insertSample = try db.makeStatement(sql: "INSERT OR REPLACE INTO samples_1s (metric, ts, value) VALUES (?, ?, ?)")
            for s in samples where s.value.isFinite {
                try insertSample.execute(arguments: [s.kind.rawValue, Self.seconds(s.timestamp), s.value])
            }
            let insertProcess = try db.makeStatement(sql: "INSERT INTO process_samples (ts, pid, name, cpu, mem) VALUES (?, ?, ?, ?, ?)")
            for p in processes {
                try insertProcess.execute(arguments: [Self.seconds(p.time), Int64(p.pid), p.name, p.cpuPercent, Int64(clamping: p.memoryBytes)])
            }
            for e in events {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO timeline_events (id, ts, category, severity, title, detail) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [e.id.uuidString, e.time.timeIntervalSince1970, e.category.rawValue,
                                     e.severity.rawValue, e.title, e.detail])
            }
            for tier in Self.aggregates {
                try Self.rollUp(tier, until: nowSeconds, db)
            }
            try Self.prune(now: nowSeconds, retention: retention, db)
        }
    }

    public func clear() throws {
        try db.write { db in
            for table in ["samples_1s", "process_samples", "rollup_state", "timeline_events"] + Self.aggregates.map(\.table) {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    private static func rollUp(_ tier: Tier, until now: Int64, _ db: Database) throws {
        guard let source = tier.source else { return }
        let b = tier.bucketSeconds
        let to = now / b * b                       // only buckets that have fully elapsed
        let timeColumn = source == raw.table ? "ts" : "bucket"
        let from: Int64
        if let done = try Int64.fetchOne(db, sql: "SELECT done_until FROM rollup_state WHERE tier = ?", arguments: [tier.table]) {
            from = done
        } else if let first = try Int64.fetchOne(db, sql: "SELECT MIN(\(timeColumn)) FROM \(source)") {
            from = first / b * b
        } else {
            return
        }
        guard to > from else { return }

        let select = source == raw.table
            ? "SELECT metric, ts / \(b) * \(b), MIN(value), AVG(value), MAX(value), COUNT(*) FROM samples_1s"
            : "SELECT metric, bucket / \(b) * \(b), MIN(min), SUM(avg * count) / SUM(count), MAX(max), SUM(count) FROM \(source)"
        try db.execute(sql: """
            INSERT OR REPLACE INTO \(tier.table) (metric, bucket, min, avg, max, count)
            \(select) WHERE \(timeColumn) >= ? AND \(timeColumn) < ? GROUP BY 1, 2
            """, arguments: [from, to])
        try db.execute(sql: "INSERT OR REPLACE INTO rollup_state (tier, done_until) VALUES (?, ?)", arguments: [tier.table, to])
    }

    private static func prune(now: Int64, retention: RetentionPreset, _ db: Database) throws {
        let cap = retention.seconds
        try db.execute(sql: "DELETE FROM samples_1s WHERE ts < ?", arguments: [now - min(raw.keepSeconds, cap)])
        try db.execute(sql: "DELETE FROM process_samples WHERE ts < ?", arguments: [now - min(processKeepSeconds, cap)])
        try db.execute(sql: "DELETE FROM timeline_events WHERE ts < ?", arguments: [Double(now - cap)])
        for tier in aggregates {
            try db.execute(sql: "DELETE FROM \(tier.table) WHERE bucket < ?", arguments: [now - min(tier.keepSeconds, cap)])
        }
    }

    // MARK: Reading

    /// Points for one metric, from the finest tier whose window still covers `from`.
    public func series(_ kind: MetricKind, from: Date, to: Date, now: Date = Date()) throws -> [HistoryPoint] {
        let tier = Self.tier(covering: from, now: now)
        let lower = Self.seconds(from), upper = Self.seconds(to)
        return try db.read { db in
            if tier.source == nil {
                return try Row.fetchAll(db, sql: "SELECT ts, value FROM samples_1s WHERE metric = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                                        arguments: [kind.rawValue, lower, upper]).map {
                    let v: Double = $0["value"]
                    return HistoryPoint(time: Date(timeIntervalSince1970: TimeInterval($0["ts"] as Int64)), min: v, avg: v, max: v)
                }
            }
            return try Row.fetchAll(db, sql: "SELECT bucket, min, avg, max FROM \(tier.table) WHERE metric = ? AND bucket >= ? AND bucket <= ? ORDER BY bucket",
                                    arguments: [kind.rawValue, lower / tier.bucketSeconds * tier.bucketSeconds, upper]).map {
                HistoryPoint(time: Date(timeIntervalSince1970: TimeInterval($0["bucket"] as Int64)),
                             min: $0["min"], avg: $0["avg"], max: $0["max"])
            }
        }
    }

    /// Chart-ready series: at most ~`maxPoints` points, re-bucketed in SQL from the finest tier that
    /// covers `from`. Each point keeps the min/max of what it merges, so spikes stay visible.
    public func chartSeries(_ kind: MetricKind, from: Date, to: Date, now: Date = Date(), maxPoints: Int = 600) throws -> HistorySeries {
        let tier = Self.tier(covering: from, now: now)
        let lower = Self.seconds(from), upper = Self.seconds(to)
        let step = Self.step(span: upper - lower, tierBucket: tier.bucketSeconds, maxPoints: maxPoints)
        let sql = tier.source == nil
            ? """
              SELECT ts / \(step) * \(step) AS b, MIN(value) AS min, AVG(value) AS avg, MAX(value) AS max
              FROM samples_1s WHERE metric = ? AND ts >= ? AND ts <= ? GROUP BY b ORDER BY b
              """
            : """
              SELECT bucket / \(step) * \(step) AS b, MIN(min) AS min, SUM(avg * count) / SUM(count) AS avg, MAX(max) AS max
              FROM \(tier.table) WHERE metric = ? AND bucket >= ? AND bucket <= ? GROUP BY b ORDER BY b
              """
        let points = try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [kind.rawValue, lower / step * step, upper]).map {
                HistoryPoint(time: Date(timeIntervalSince1970: TimeInterval($0["b"] as Int64)),
                             min: $0["min"], avg: $0["avg"], max: $0["max"])
            }
        }
        return HistorySeries(points: points, stepSeconds: step)
    }

    /// Bucket width: a multiple of the tier's own bucket, wide enough for `maxPoints`.
    static func step(span: Int64, tierBucket: Int64, maxPoints: Int) -> Int64 {
        let needed = max(1, (span + Int64(maxPoints) - 1) / Int64(max(maxPoints, 1)))
        return max(tierBucket, (needed + tierBucket - 1) / tierBucket * tierBucket)
    }

    /// Stored top-process samples in a time range, oldest first.
    public func processSamples(from: Date, to: Date) throws -> [ProcessSample] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT ts, pid, name, cpu, mem FROM process_samples WHERE ts >= ? AND ts <= ? ORDER BY ts",
                             arguments: [Self.seconds(from), Self.seconds(to)]).map {
                ProcessSample(time: Date(timeIntervalSince1970: TimeInterval($0["ts"] as Int64)),
                              pid: Int32(truncatingIfNeeded: $0["pid"] as Int64), name: $0["name"],
                              cpuPercent: $0["cpu"], memoryBytes: UInt64(max(0, $0["mem"] as Int64)))
            }
        }
    }

    /// Timeline events in a range, newest first.
    public func events(from: Date, to: Date, categories: Set<TimelineCategory>? = nil, limit: Int = 500) throws -> [TimelineEvent] {
        let filter = categories.map { set in
            " AND category IN (" + set.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",") + ")"
        } ?? ""
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, ts, category, severity, title, detail FROM timeline_events
                WHERE ts >= ? AND ts <= ?\(filter) ORDER BY ts DESC LIMIT ?
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970, limit]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let category = TimelineCategory(rawValue: row["category"]),
                      let severity = HealthLevel(rawValue: row["severity"]) else { return nil }
                return TimelineEvent(id: id, time: Date(timeIntervalSince1970: row["ts"]), category: category,
                                     severity: severity, title: row["title"], detail: row["detail"])
            }
        }
    }

    static func tier(covering from: Date, now: Date) -> Tier {
        let age = Int64(now.timeIntervalSince(from).rounded(.up))
        if age <= raw.keepSeconds { return raw }
        return aggregates.first { age <= $0.keepSeconds } ?? aggregates[aggregates.count - 1]
    }

    private static func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
}

public struct HistorySeries: Sendable, Equatable {
    public var points: [HistoryPoint]
    /// Seconds each point spans.
    public var stepSeconds: Int64

    public init(points: [HistoryPoint], stepSeconds: Int64) {
        self.points = points
        self.stepSeconds = stepSeconds
    }

    /// Splits where consecutive points are further apart than expected — the app was not running
    /// or the Mac slept — so charts show a gap instead of a line across it.
    public var segments: [[HistoryPoint]] {
        let maxGap = max(3 * TimeInterval(stepSeconds), 16)
        var result: [[HistoryPoint]] = []
        for point in points {
            if let last = result.last?.last, point.time.timeIntervalSince(last.time) <= maxGap {
                result[result.count - 1].append(point)
            } else {
                result.append([point])
            }
        }
        return result
    }
}
