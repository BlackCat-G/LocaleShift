import Foundation
import CSQLite
import CryptoKit
import Darwin

public final class CrossProcessLock: @unchecked Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public final class Lease: @unchecked Sendable {
        private var descriptor: Int32
        private let mutex = NSLock()
        fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
        public func unlock() { mutex.lock(); defer { mutex.unlock() }; if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); _ = close(descriptor); descriptor = -1 } }
        deinit { unlock() }
    }
    public func acquire() throws -> Lease {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CoreError(.persistence, detail: "无法打开操作锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { _ = close(descriptor); throw CoreError(.busy) }
        return Lease(descriptor)
    }
}

public final class Repository: @unchecked Sendable {
    public let directory: URL
    public let lockURL: URL
    private var db: OpaquePointer?
    private let mutex = NSRecursiveLock()
    private var persistenceDepth = 0
    private let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(directory: URL) throws {
        self.directory = directory; lockURL = directory.appendingPathComponent("operation.lock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("localeshift.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw CoreError(.dataCorrupt, detail: "无法打开设置数据库。") }
        do { try withPersistenceLock {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA fullfsync=ON")
            try execute("PRAGMA checkpoint_fullfsync=ON")
            guard try scalar("PRAGMA journal_mode") == "wal", try scalar("PRAGMA synchronous") == "2", try scalar("PRAGMA fullfsync") == "1" else { throw CoreError(.persistence, detail: "数据库可靠同步设置不可用。") }
            try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value BLOB NOT NULL)")
            let schema = try stringValue("schema_version")
            guard schema == nil || schema == "1" else { throw CoreError(.dataCorrupt, detail: "不支持的数据格式版本。") }
            try putString("1", key: "schema_version")
            try execute("CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY, language TEXT NOT NULL, region TEXT NOT NULL, timezone TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(language,region,timezone))")
            try execute("CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, completed INTEGER NOT NULL, created REAL NOT NULL, payload BLOB NOT NULL)")
        } } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db = db { sqlite3_close(db) } }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { mutex.lock(); defer { mutex.unlock() }; return try body() }
    private static func acquirePersistenceLock(directory: URL) throws -> CrossProcessLock.Lease {
        let lock = CrossProcessLock(url: directory.appendingPathComponent("persistence.lock"))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            do { return try lock.acquire() }
            catch let error as CoreError where error.code == .busy {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw error }
                usleep(1000)
            }
        }
    }
    private func withPersistenceLock<T>(_ body: () throws -> T) throws -> T { try synchronized {
        if persistenceDepth > 0 { return try body() }
        let lease = try Self.acquirePersistenceLock(directory: directory)
        persistenceDepth = 1
        defer { persistenceDepth = 0; lease.unlock() }
        return try body()
    } }
    private func sqlError() -> CoreError {
        let status = sqlite3_errcode(db)
        let code: CoreErrorCode = status == SQLITE_BUSY || status == SQLITE_LOCKED ? .busy : (status == SQLITE_CORRUPT || status == SQLITE_NOTADB ? .dataCorrupt : .persistence)
        return CoreError(code, detail: String(cString: sqlite3_errmsg(db)))
    }
    /// Keep the database generation and independent snapshot stable during integrity verification.
    /// A short RESERVED lock also prevents a concurrent commit from pruning the file being read.
    private func consistentRead<T>(_ body: () throws -> T) throws -> T { try withPersistenceLock {
        if sqlite3_get_autocommit(db) == 0 { return try body() }
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqlError() }
        return statement
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqlError() } }
    private func scalar(_ sql: String) throws -> String? {
        let statement = try statement(sql); defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw sqlError() }
        return String(cString: value)
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T { try withPersistenceLock {
        try execute("BEGIN IMMEDIATE")
        var committed = false
        do {
            try verifyRecoveryIntegrity()
            let result = try body()
            let previous = try recoveryGeneration()
            let snapshot = try captureRecoverySnapshot(generation: UUID(), previous: previous)
            let bytes = try encodeRecord(snapshot)
            let digest = checksum(bytes)
            // Full snapshot is durable before SQLite can acknowledge the corresponding intents.
            try atomicWrite(bytes, to: recoveryStageFileURL(generation: snapshot.generation))
            try putString(snapshot.generation.uuidString, key: "recovery_generation")
            try putString(digest, key: "recovery_digest")
            try execute("COMMIT"); committed = true
            // A crash after COMMIT leaves a stage explicitly referenced by SQLite; finish it under this lock.
            try verifyRecoveryIntegrity()
            pruneRecoverySnapshots(keeping: [snapshot.generation, previous].compactMap { $0 })
            return result
        } catch { if !committed { try? execute("ROLLBACK") }; throw error }
    } }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) { sqlite3_bind_text(statement, index, value, -1, transient) }
    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) { value.withUnsafeBytes { _ = sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) } }
    private func blob(_ statement: OpaquePointer, column: Int32 = 0) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { throw CoreError(.dataCorrupt) }
        return Data(bytes: pointer, count: count)
    }
    private struct RecordEnvelope: Codable { var formatVersion: Int = 1; var payload: Data; var checksum: String }
    private struct RecoveryHead: Codable { var generation: UUID; var checksum: String }
    private func encodeRecord<T: Encodable>(_ value: T) throws -> Data {
        let payload = try encoder.encode(value)
        return try encoder.encode(RecordEnvelope(payload: payload, checksum: checksum(payload)))
    }
    private static func decodeRecord<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let envelope = try JSONDecoder().decode(RecordEnvelope.self, from: data)
            guard envelope.formatVersion == 1, envelope.checksum == digest(envelope.payload) else { throw CoreError(.dataCorrupt) }
            return try JSONDecoder().decode(type, from: envelope.payload)
        } catch { throw CoreError(.dataCorrupt, detail: "恢复记录校验失败。") }
    }
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try Self.decodeRecord(type, from: data) }
    private func value(_ key: String) throws -> Data? {
        let statement = try statement("SELECT value FROM metadata WHERE key=?"); defer { sqlite3_finalize(statement) }; bind(key, at: 1, to: statement)
        let status = sqlite3_step(statement); if status == SQLITE_DONE { return nil }; guard status == SQLITE_ROW else { throw sqlError() }; return try blob(statement)
    }
    private func stringValue(_ key: String) throws -> String? { try value(key).flatMap { String(data: $0, encoding: .utf8) } }
    private func put(_ value: Data?, key: String) throws {
        let statement = try statement(value == nil ? "DELETE FROM metadata WHERE key=?" : "INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"); defer { sqlite3_finalize(statement) }
        bind(key, at: 1, to: statement); if let value { bind(value, at: 2, to: statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError() }
    }
    private func putString(_ value: String, key: String) throws { try put(Data(value.utf8), key: key) }
    public func profiles() throws -> [WorkProfile] { try synchronized {
        let statement = try statement("SELECT payload FROM profiles"); defer { sqlite3_finalize(statement) }; var profiles: [WorkProfile] = []
        while true { let status = sqlite3_step(statement); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw sqlError() }; profiles.append(try decode(WorkProfile.self, from: blob(statement))) }
        return profiles.sorted { ($0.lastAppliedAt ?? .distantPast) > ($1.lastAppliedAt ?? .distantPast) || ($0.lastAppliedAt == $1.lastAppliedAt && $0.createdAt < $1.createdAt) }
    } }
    @discardableResult public func saveProfile(_ profile: WorkProfile) throws -> WorkProfile { try withPersistenceLock {
        var normalized = profile; normalized.language = IdentifierNormalizer.language(profile.language); normalized.region = IdentifierNormalizer.canonicalRegion(profile.region); normalized.timeZone = try IdentifierNormalizer.timeZone(profile.timeZone)
        guard IdentifierNormalizer.isValidLanguage(profile.language), IdentifierNormalizer.isValidRegion(profile.region) else { throw CoreError(.invalidTarget) }
        normalized.updatedAt = Date()
        let statement = try statement("INSERT INTO profiles(id,language,region,timezone,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET language=excluded.language,region=excluded.region,timezone=excluded.timezone,payload=excluded.payload"); defer { sqlite3_finalize(statement) }
        bind(normalized.id.uuidString, at: 1, to: statement); bind(normalized.language, at: 2, to: statement); bind(normalized.region, at: 3, to: statement); bind(normalized.timeZone, at: 4, to: statement); bind(try encodeRecord(normalized), at: 5, to: statement)
        let result = sqlite3_step(statement); if result == SQLITE_CONSTRAINT { throw CoreError(.duplicateProfile) }; guard result == SQLITE_DONE else { throw sqlError() }; return normalized
    } }
    public func deleteProfile(id: UUID) throws { try withPersistenceLock {
        let statement = try statement("DELETE FROM profiles WHERE id=?"); defer { sqlite3_finalize(statement) }; bind(id.uuidString, at: 1, to: statement); guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError() }
    } }
    public func cloneProfile(id: UUID) throws -> WorkProfile {
        guard var profile = try profiles().first(where: { $0.id == id }) else { throw CoreError(.invalidTarget) }
        profile.id = UUID(); profile.createdAt = Date(); profile.updatedAt = profile.createdAt; profile.lastAppliedAt = nil; return profile
    }
    public func baselineFileURL(version: UUID, backup: Bool = false) -> URL { directory.appendingPathComponent("baseline-\(version.uuidString)\(backup ? ".backup" : "").json") }
    private struct BaselineEnvelope: Codable { var formatVersion: Int; var payload: Data; var checksum: String }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func checksum(_ data: Data) -> String { Self.digest(data) }
    private func loadBaseline(version: UUID) throws -> DefaultBaseline { try Self.loadBaseline(directory: directory, version: version) }
    private static func loadBaseline(directory: URL, version: UUID) throws -> DefaultBaseline {
        let decoder = JSONDecoder()
        for backup in [false, true] {
            do {
                let envelope = try decoder.decode(BaselineEnvelope.self, from: Data(contentsOf: directory.appendingPathComponent("baseline-\(version.uuidString)\(backup ? ".backup" : "").json")))
                guard envelope.formatVersion == 1, envelope.checksum == digest(envelope.payload) else { continue }
                let baseline = try decoder.decode(DefaultBaseline.self, from: envelope.payload)
                guard baseline.version == version, baseline.formatVersion == 1 else { continue }
                _ = try baseline.settings.validated(); return baseline
            } catch { continue }
        }
        throw CoreError(.dataCorrupt, detail: "系统默认配置及匹配备份均不可验证。")
    }
    public func baseline() throws -> DefaultBaseline? { try consistentRead {
        try verifyRecoveryIntegrity()
        guard let versionString = try stringValue("baseline_version") else {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if files.contains(where: { $0.hasPrefix("baseline-") }) { throw CoreError(.dataCorrupt, detail: "基准文件与数据库引用不一致。") }
            return nil
        }
        guard let version = UUID(uuidString: versionString) else { throw CoreError(.dataCorrupt) }
        let baseline = try loadBaseline(version: version)
        if let session = try activeSessionRaw(), session.baselineVersion != version { throw CoreError(.dataCorrupt, detail: "活跃会话基准版本不匹配。") }
        for op in try operationsRaw() where op.completedAt == nil { guard op.baselineVersion == version else { throw CoreError(.dataCorrupt) } }
        return baseline
    } }
    @discardableResult public func saveBaseline(settings: SystemSettings, source: String, confirmedAt: Date = Date()) throws -> DefaultBaseline {
        let lease = try CrossProcessLock(url: lockURL).acquire(); defer { lease.unlock() }
        return try withPersistenceLock {
            guard try activeSession() == nil, try operations().allSatisfy({ $0.completedAt != nil }), try restartIntent() == nil else { throw CoreError(.sessionUnresolved) }
            _ = try settings.validated()
            // An existing corrupt baseline requires explicit repair outside normal baseline updates.
            if try stringValue("baseline_version") != nil { _ = try baseline() }
            let baseline = DefaultBaseline(settings: settings, source: source, confirmedAt: confirmedAt)
            let payload = try encoder.encode(baseline)
            let envelope = try encoder.encode(BaselineEnvelope(formatVersion: 1, payload: payload, checksum: checksum(payload)))
            try atomicWrite(envelope, to: baselineFileURL(version: baseline.version))
            try atomicWrite(envelope, to: baselineFileURL(version: baseline.version, backup: true))
            try transaction { try putString(baseline.version.uuidString, key: "baseline_version") }
            return baseline
        }
    }
    private func atomicWrite(_ data: Data, to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CoreError(.persistence) }
        defer { _ = close(fd); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), data.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CoreError(.persistence) }; written += count
            }
        }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0, rename(temporary.path, target.path) == 0 else { throw CoreError(.persistence) }
        let directoryFD = open(parent.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw CoreError(.persistence) }; defer { _ = close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CoreError(.persistence) }
    }
    private func activeSessionRaw() throws -> WorkSession? { try value("active_session").map { try decode(WorkSession.self, from: $0) } }
    public func activeSession() throws -> WorkSession? { try consistentRead { try verifyRecoveryIntegrity(); return try activeSessionRaw() } }
    public func saveSession(_ session: WorkSession?) throws { try synchronized { try transaction { try put(session.map { try encodeRecord($0) }, key: "active_session") } } }
    private func timezonePreparationRaw() throws -> TimezonePreparation { try value("timezone_preparation").map { try decode(TimezonePreparation.self, from: $0) } ?? TimezonePreparation() }
    public func timezonePreparation() throws -> TimezonePreparation { try consistentRead { try verifyRecoveryIntegrity(); return try timezonePreparationRaw() } }
    public func saveTimezonePreparation(_ preparation: TimezonePreparation) throws { try synchronized { try transaction { try put(encodeRecord(preparation), key: "timezone_preparation") } } }
    private func restartIntentRaw() throws -> RestartIntent? { try value("restart_intent").map { try decode(RestartIntent.self, from: $0) } }
    public func restartIntent() throws -> RestartIntent? { try consistentRead { try verifyRecoveryIntegrity(); return try restartIntentRaw() } }
    public func saveRestartIntent(_ intent: RestartIntent?) throws { try synchronized { try transaction { try put(intent.map { try encodeRecord($0) }, key: "restart_intent") } } }
    public func operations() throws -> [OperationRecord] { try consistentRead { try verifyRecoveryIntegrity(); return try operationsRaw() } }
    private func operationsRaw() throws -> [OperationRecord] {
        let statement = try statement("SELECT payload FROM operations ORDER BY created DESC,rowid DESC"); defer { sqlite3_finalize(statement) }; var records: [OperationRecord] = []
        while true { let status = sqlite3_step(statement); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw sqlError() }; records.append(try decode(OperationRecord.self, from: blob(statement))) }; return records
    }
    public func history() throws -> [OperationRecord] { try operations().filter { $0.completedAt != nil } }
    private func persistOperation(_ operation: OperationRecord) throws {
        let statement = try statement("INSERT INTO operations(id,completed,created,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET completed=excluded.completed,payload=excluded.payload"); defer { sqlite3_finalize(statement) }
        bind(operation.id.uuidString, at: 1, to: statement); sqlite3_bind_int(statement, 2, operation.completedAt == nil ? 0 : 1); sqlite3_bind_double(statement, 3, operation.createdAt.timeIntervalSince1970); bind(try encodeRecord(operation), at: 4, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError() }
        try execute("DELETE FROM operations WHERE completed=1 AND id NOT IN (SELECT id FROM operations WHERE completed=1 ORDER BY created DESC,rowid DESC LIMIT 50)")
    }
    public func saveOperation(_ operation: OperationRecord) throws { try synchronized { try transaction { try persistOperation(operation) } } }
    public func commit(operation: OperationRecord, session: WorkSession?) throws { try synchronized { try transaction { try persistOperation(operation); try put(session.map { try encodeRecord($0) }, key: "active_session") } } }
    /// Resolve older interrupted records only after the full fixed baseline was independently verified.
    public func completeRecovery(operation: OperationRecord) throws { try synchronized { try transaction {
        for var old in try operationsRaw() where old.completedAt == nil && old.id != operation.id { old.state = .rolledBack; old.completedAt = Date(); try persistOperation(old) }
        try persistOperation(operation); try put(nil, key: "active_session"); try put(nil, key: "restart_intent")
    } } }
    public func recoverySnapshotFileURL(generation: UUID) -> URL { directory.appendingPathComponent("recovery-\(generation.uuidString).json") }
    private func recoveryGeneration() throws -> UUID? {
        guard let text = try stringValue("recovery_generation") else { return nil }
        guard let generation = UUID(uuidString: text) else { throw CoreError(.dataCorrupt) }; return generation
    }
    private func captureRecoverySnapshot(generation: UUID, previous: UUID?) throws -> RecoverySnapshot {
        let versionText = try stringValue("baseline_version")
        let version = versionText.flatMap(UUID.init(uuidString:))
        guard versionText == nil || version != nil else { throw CoreError(.dataCorrupt) }
        return RecoverySnapshot(generation: generation, previousGeneration: previous, baselineVersion: version, session: try activeSessionRaw(), operations: try operationsRaw(), restartIntent: try restartIntentRaw(), preparation: try timezonePreparationRaw())
    }
    private func recoveryStageFileURL(generation: UUID) -> URL { directory.appendingPathComponent(".recovery-stage-\(generation.uuidString).json") }
    private func syncRecoveryDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw CoreError(.persistence) }; defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw CoreError(.persistence) }
    }
    private func clearUnreferencedStages(cleanInitialBaselines: Bool = false) {
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(".recovery-stage-") {
            if cleanInitialBaselines,
               let bytes = try? Data(contentsOf: file), let candidate = try? decode(RecoverySnapshot.self, from: bytes),
               file.lastPathComponent == ".recovery-stage-\(candidate.generation.uuidString).json",
               candidate.formatVersion == 1, candidate.previousGeneration == nil,
               candidate.session == nil, candidate.operations.isEmpty, candidate.restartIntent == nil,
               let version = candidate.baselineVersion, (try? loadBaseline(version: version)) != nil {
                // Only a verified complete initial stage identifies these files as never committed.
                for backup in [false, true] { try? FileManager.default.removeItem(at: baselineFileURL(version: version, backup: backup)) }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func verifyRecoveryIntegrity() throws {
        guard let generation = try recoveryGeneration() else {
            let recoveryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { name in
                name.hasPrefix("recovery-") && name.hasSuffix(".json")
            }
            guard !recoveryFiles, try activeSessionRaw() == nil, try operationsRaw().isEmpty, try restartIntentRaw() == nil else { throw CoreError(.dataCorrupt, detail: "恢复记录与完整备份的代次不一致。") }
            // A stage without a committed DB reference never authorized a system write.
            clearUnreferencedStages(cleanInitialBaselines: try stringValue("baseline_version") == nil)
            return
        }
        guard let expectedDigest = try stringValue("recovery_digest") else { throw CoreError(.dataCorrupt) }
        let published = recoverySnapshotFileURL(generation: generation)
        let stage = recoveryStageFileURL(generation: generation)
        let isPublished = FileManager.default.fileExists(atPath: published.path)
        guard let bytes = try? Data(contentsOf: isPublished ? published : stage), checksum(bytes) == expectedDigest else { throw CoreError(.dataCorrupt, detail: "当前完整恢复备份不可验证。") }
        let snapshot = try decode(RecoverySnapshot.self, from: bytes)
        guard snapshot.generation == generation, snapshot.formatVersion == 1,
              try captureRecoverySnapshot(generation: generation, previous: snapshot.previousGeneration) == snapshot else { throw CoreError(.dataCorrupt, detail: "主恢复记录与完整备份不一致，需人工核验。") }
        if !isPublished {
            guard rename(stage.path, published.path) == 0 else { throw CoreError(.persistence) }
            try syncRecoveryDirectory()
        }
        let headURL = directory.appendingPathComponent("recovery-head.json")
        let head = (try? Data(contentsOf: headURL)).flatMap { try? decode(RecoveryHead.self, from: $0) }
        if head?.generation != generation || head?.checksum != expectedDigest {
            if let previous = snapshot.previousGeneration, let oldBytes = try? Data(contentsOf: recoverySnapshotFileURL(generation: previous)), let oldSnapshot = try? decode(RecoverySnapshot.self, from: oldBytes), oldSnapshot.generation == previous {
                try atomicWrite(encodeRecord(RecoveryHead(generation: previous, checksum: checksum(oldBytes))), to: directory.appendingPathComponent("recovery-head.backup.json"))
            }
            try atomicWrite(encodeRecord(RecoveryHead(generation: generation, checksum: expectedDigest)), to: headURL)
        }
        clearUnreferencedStages()
    }
    private func pruneRecoverySnapshots(keeping generations: [UUID]) {
        let names = Set(generations.map { "recovery-\($0.uuidString).json" })
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = file.lastPathComponent
            guard name.hasPrefix("recovery-"), name.hasSuffix(".json"), UUID(uuidString: String(name.dropFirst(9).dropLast(5))) != nil, !names.contains(name) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    /// Read evidence without importing it into the live database or authorizing system writes.
    public func verifiedRecoverySnapshot() throws -> RecoverySnapshotEvidence { try consistentRead {
        let preferred = try? recoveryGeneration()
        let expected = try? stringValue("recovery_digest")
        return try Self.readRecoveryEvidence(directory: directory, preferred: preferred, expectedDigest: expected)
    } }
    /// Available even when opening the main SQLite database fails. Always requires manual verification.
    public static func verifiedRecoverySnapshot(directory: URL) throws -> RecoverySnapshotEvidence {
        let lease = try acquirePersistenceLock(directory: directory); defer { lease.unlock() }
        return try readRecoveryEvidence(directory: directory, preferred: nil, expectedDigest: nil)
    }
    private static func readRecoveryEvidence(directory: URL, preferred: UUID?, expectedDigest: String?) throws -> RecoverySnapshotEvidence {
        var heads: [RecoveryHead] = []
        var current = preferred
        if let preferred, let expectedDigest { heads.append(RecoveryHead(generation: preferred, checksum: expectedDigest)) }
        for name in ["recovery-head.json", "recovery-head.backup.json"] {
            if let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)), let head = try? decodeRecord(RecoveryHead.self, from: bytes) {
                if current == nil && name == "recovery-head.json" { current = head.generation }
                if !heads.contains(where: { $0.generation == head.generation }) { heads.append(head) }
            }
        }
        for head in heads {
            do {
                let bytes = try Data(contentsOf: directory.appendingPathComponent("recovery-\(head.generation.uuidString).json"))
                guard digest(bytes) == head.checksum else { continue }
                let snapshot = try decodeRecord(RecoverySnapshot.self, from: bytes)
                guard snapshot.formatVersion == 1, snapshot.generation == head.generation else { continue }
                if let session = snapshot.session { guard session.baselineVersion == snapshot.baselineVersion else { continue }; _ = try session.target.validated(); _ = try session.lastKnownActual.validated() }
                if snapshot.operations.contains(where: { $0.completedAt == nil && $0.baselineVersion != snapshot.baselineVersion }) { continue }
                if let intent = snapshot.restartIntent { guard let session = snapshot.session, intent.baselineVersion == snapshot.baselineVersion, intent.sessionID == session.id, intent.ownerUID == session.ownerUID else { continue } }
                let baseline = try snapshot.baselineVersion.map { try loadBaseline(directory: directory, version: $0) }
                return RecoverySnapshotEvidence(snapshot: snapshot, baseline: baseline, isCurrent: snapshot.generation == current)
            } catch { continue }
        }
        throw CoreError(.dataCorrupt, detail: "当前及上一完整恢复备份均不可验证。")
    }
    /// Uses SQLite's online backup API so committed WAL pages are included.
    /// Baseline envelopes remain independent files; preserve versions referenced by the snapshot.
    public func backupDatabase(to destination: URL) throws {
        let lease = try CrossProcessLock(url: lockURL).acquire(); defer { lease.unlock() }
        try withPersistenceLock {
            try verifyRecoveryIntegrity()
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw CoreError(.persistence, detail: "备份目标已存在。") }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).sqlite")
            var target: OpaquePointer?
            guard sqlite3_open_v2(temporary.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let target else { if let target { sqlite3_close(target) }; throw CoreError(.persistence) }
            defer { sqlite3_close(target); _ = unlink(temporary.path) }
            guard let backup = sqlite3_backup_init(target, "main", db, "main") else { throw CoreError(.persistence) }
            let result = sqlite3_backup_step(backup, -1)
            let finished = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finished == SQLITE_OK else { throw CoreError(.persistence, detail: "无法创建一致的数据库备份。") }
            if let generation = try recoveryGeneration() {
                let bytes = try Data(contentsOf: recoverySnapshotFileURL(generation: generation))
                let snapshot = try decode(RecoverySnapshot.self, from: bytes)
                for item in [generation, snapshot.previousGeneration].compactMap({ $0 }) {
                    let file = recoverySnapshotFileURL(generation: item)
                    try atomicWrite(Data(contentsOf: file), to: destination.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent))
                }
                if let previous = snapshot.previousGeneration {
                    let previousBytes = try Data(contentsOf: recoverySnapshotFileURL(generation: previous))
                    try atomicWrite(encodeRecord(RecoveryHead(generation: previous, checksum: checksum(previousBytes))), to: destination.deletingLastPathComponent().appendingPathComponent("recovery-head.backup.json"))
                }
                try atomicWrite(encodeRecord(RecoveryHead(generation: generation, checksum: checksum(bytes))), to: destination.deletingLastPathComponent().appendingPathComponent("recovery-head.json"))
            }
            let fd = open(temporary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw CoreError(.persistence) }; defer { _ = close(fd) }
            guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0, rename(temporary.path, destination.path) == 0 else { throw CoreError(.persistence) }
            let directoryFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
            guard directoryFD >= 0 else { throw CoreError(.persistence) }; defer { _ = close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw CoreError(.persistence) }
        }
    }

}
