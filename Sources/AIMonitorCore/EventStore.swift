import Foundation

/// Persistent analytics store. SQLite, local-only, WAL mode.
///
/// Dedup rules are enforced by the schema, not by callers remembering:
///   * Claude Code events upsert by requestId and keep the **largest**
///     snapshot (progressive streaming duplicates never double-count, and the
///     fold stays order-independent).
///   * Codex delta events carry positional ids and INSERT OR IGNORE — replaying
///     a log is a no-op.
public final class EventStore: @unchecked Sendable {
    // SQLite runs in serialized mode; the connection is safe to share.
    // Callers still serialize their own writes by design (single sync engine).
    let db: Database

    /// Applied migrations, in order. Never edit an applied entry; append.
    private static let migrations: [(String, String)] = [
        ("001_core", """
            CREATE TABLE events(
              id TEXT PRIMARY KEY,
              ts REAL,
              source TEXT NOT NULL,
              provider TEXT NOT NULL,
              application TEXT,
              model TEXT,
              session_id TEXT,
              project TEXT,
              event_type TEXT NOT NULL DEFAULT 'usage',
              uncached_input INTEGER NOT NULL DEFAULT 0,
              cached_input INTEGER NOT NULL DEFAULT 0,
              cache_write_5m INTEGER NOT NULL DEFAULT 0,
              cache_write_1h INTEGER NOT NULL DEFAULT 0,
              cache_write_unspecified INTEGER NOT NULL DEFAULT 0,
              output INTEGER NOT NULL DEFAULT 0,
              reasoning INTEGER NOT NULL DEFAULT 0,
              billable INTEGER NOT NULL DEFAULT 0,
              cost_usd REAL,
              confidence TEXT NOT NULL
            );
            CREATE TABLE quota_snapshots(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              observed_at REAL NOT NULL,
              provider TEXT NOT NULL,
              window_id TEXT NOT NULL,
              label TEXT NOT NULL,
              used_percent REAL NOT NULL,
              window_minutes INTEGER NOT NULL,
              resets_at REAL,
              plan_type TEXT
            );
            CREATE TABLE checkpoints(
              path TEXT PRIMARY KEY,
              size INTEGER NOT NULL,
              offset INTEGER NOT NULL,
              state TEXT
            );
            CREATE TABLE settings(
              key TEXT PRIMARY KEY,
              value TEXT
            );
            """),
        ("002_indexes", """
            CREATE INDEX idx_events_ts ON events(ts);
            CREATE INDEX idx_events_provider_ts ON events(provider, ts);
            CREATE INDEX idx_events_model ON events(model);
            CREATE INDEX idx_events_project ON events(project);
            CREATE INDEX idx_events_session ON events(session_id);
            CREATE INDEX idx_quota_window_obs ON quota_snapshots(window_id, observed_at);
            """),
        // `speed` was applied to the price at sync time and then thrown away,
        // which made the stored cost unreproducible: nothing left on the row
        // said whether it had been billed at the fast-mode premium. Recosting
        // against an edited rate table needs that fact back, and a recost that
        // silently dropped every fast-mode event to the standard rate would be
        // precisely the kind of quietly-wrong number this project refuses.
        // Rows written before this column exist keep NULL, which reads as
        // "standard" — true for every provider except Claude fast mode, and
        // `recost` reports how many rows it could not vouch for.
        ("003_speed", """
            ALTER TABLE events ADD COLUMN speed TEXT;
            """),
    ]

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
        Self.restrictPermissions(path: path)
    }

    /// Make the store readable only by its owner.
    ///
    /// SQLite creates the database — and its `-wal` and `-shm` companions —
    /// with the process umask, which on macOS means **0644: every other local
    /// account can read it**. What it holds is not innocuous. The store is a
    /// complete record of when this person works, for how long, on which
    /// projects by directory name, at what cost. "Local" and "private" are not
    /// the same claim, and PRIVACY.md makes the second one.
    ///
    /// The credential files this tool *reads* are 0600. The file it *writes*
    /// should not be looser than its own sources.
    ///
    /// Best-effort: a store on a filesystem without POSIX modes (a network
    /// share, an exFAT volume) cannot be restricted, and failing to open is a
    /// worse outcome than failing to tighten. Nothing here can widen a mode.
    static func restrictPermissions(path: String) {
        guard !path.hasPrefix("file:") else { return }   // in-memory test stores
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
        }
    }

    /// In-memory store, for tests.
    public static func inMemory() throws -> EventStore { try EventStore(path: "file:aimonitor-test-\(UUID().uuidString)?mode=memory&cache=shared") }

    /// Default on-disk location: ~/Library/Application Support/AIMonitor/aimonitor.db
    public static func defaultPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AIMonitor/aimonitor.db").path
    }

    private func migrate() throws {
        var applied = db.schemaVersion
        while applied < Self.migrations.count {
            let (_, sql) = Self.migrations[applied]
            try db.transaction { try db.exec(sql) }
            applied += 1
            db.schemaVersion = applied
        }
    }

    // MARK: - Transactions

    /// Atomic multi-write. Used by the sync engine so a file's events and its
    /// checkpoint commit together or not at all.
    public func transaction(_ body: (EventStore) throws -> Void) throws {
        try db.transaction { try body(self) }
    }

    // MARK: - Events

    /// Inserts a usage event. Claude-style ids (requestId) keep the largest
    /// snapshot on conflict; Codex-style positional ids ignore duplicates.
    public func insert(usage event: AIEvent, keepLargest: Bool) throws {
        let sql: String
        if keepLargest {
            sql = """
                INSERT INTO events(id,ts,source,provider,application,model,session_id,project,
                  uncached_input,cached_input,cache_write_5m,cache_write_1h,cache_write_unspecified,
                  output,reasoning,billable,cost_usd,confidence,speed)
                VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)
                ON CONFLICT(id) DO UPDATE SET
                  ts=excluded.ts, model=excluded.model,
                  uncached_input=excluded.uncached_input, cached_input=excluded.cached_input,
                  cache_write_5m=excluded.cache_write_5m, cache_write_1h=excluded.cache_write_1h,
                  cache_write_unspecified=excluded.cache_write_unspecified,
                  output=excluded.output, reasoning=excluded.reasoning,
                  billable=excluded.billable, cost_usd=excluded.cost_usd, speed=excluded.speed
                WHERE excluded.billable > events.billable
                """
        } else {
            sql = """
                INSERT OR IGNORE INTO events(id,ts,source,provider,application,model,session_id,project,
                  uncached_input,cached_input,cache_write_5m,cache_write_1h,cache_write_unspecified,
                  output,reasoning,billable,cost_usd,confidence,speed)
                VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)
                """
        }
        let stmt = try db.prepare(sql)
        let t = event.tokens
        stmt.bind(event.id, 1)
        stmt.bind(event.timestamp?.timeIntervalSince1970, 2)
        stmt.bind(event.source, 3)
        stmt.bind(event.provider, 4)
        stmt.bind(event.application, 5)
        stmt.bind(event.model, 6)
        stmt.bind(event.sessionId, 7)
        stmt.bind(event.project, 8)
        stmt.bind(t.uncachedInput, 9)
        stmt.bind(t.cachedInput, 10)
        stmt.bind(t.cacheWrite5m, 11)
        stmt.bind(t.cacheWrite1h, 12)
        stmt.bind(t.cacheWriteUnspecified, 13)
        stmt.bind(t.output, 14)
        stmt.bind(t.reasoning, 15)
        stmt.bind(t.billableEquivalent, 16)
        stmt.bind(event.costUSD.map { ($0 as NSDecimalNumber).doubleValue }, 17)
        stmt.bind(event.confidence.rawValue, 18)
        stmt.bind(event.speed, 19)
        _ = try stmt.step()
    }

}
