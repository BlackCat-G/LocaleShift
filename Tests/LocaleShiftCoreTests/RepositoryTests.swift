import Foundation
import CSQLite
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import LocaleShiftCore

final class RepositoryTests: CoreTestBase {
    func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    let defaults = SystemSettings(languages: ["zh-CN", "en-US", "ja"], region: "zh_CN@calendar=gregorian", timeZone: "Asia/Shanghai")
    #if !canImport(XCTest)
    @Test
    #endif
    func testProfileUniquenessCanonicalizationCloneAndDelete() throws {
        let repo = try Repository(directory: temporary())
        let saved = try repo.saveProfile(WorkProfile(language: "en_US", region: "en_US", timeZone: "US/Eastern"))
        XCTAssertEqual(saved.language, "en-US")
        XCTAssertThrowsError(try repo.saveProfile(WorkProfile(language: "en-US", region: "en-US", timeZone: "America/New_York"))) { XCTAssertEqual(($0 as? CoreError)?.code, .duplicateProfile) }
        let clone = try repo.cloneProfile(id: saved.id)
        XCTAssertNotEqual(saved.id, clone.id)
        XCTAssertEqual(try repo.profiles().count, 1)
        XCTAssertThrowsError(try repo.saveProfile(clone))
        let baseline = try repo.saveBaseline(settings: defaults, source: "test")
        let session = WorkSession(baselineVersion: baseline.version, process: ProcessIdentity(pid: 1, startSeconds: 1, startMicroseconds: 1, bootID: "boot"), target: try saved.applying(to: defaults), targetTitle: saved.title, lastKnownActual: defaults)
        try repo.saveSession(session)
        try repo.deleteProfile(id: saved.id)
        XCTAssertEqual(try repo.activeSession()?.target, session.target)
        XCTAssertThrowsError(try repo.saveBaseline(settings: defaults, source: "forbidden"))
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testBaselineSurvivesReopenAndUsesOnlyMatchingChecksumBackup() throws {
        let directory = try temporary()
        let repo = try Repository(directory: directory)
        let baseline = try repo.saveBaseline(settings: defaults, source: "explicit")
        XCTAssertEqual(try Repository(directory: directory).baseline(), baseline)
        let primary = repo.baselineFileURL(version: baseline.version)
        try Data("broken".utf8).write(to: primary)
        XCTAssertEqual(try repo.baseline(), baseline)
        try Data("broken".utf8).write(to: repo.baselineFileURL(version: baseline.version, backup: true))
        XCTAssertThrowsError(try repo.baseline()) { XCTAssertEqual(($0 as? CoreError)?.code, .dataCorrupt) }
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testHistoryRetentionDoesNotEvictUnresolvedRecordsAndOldBaselineDoesNotBlockNewVersion() throws {
        let repo = try Repository(directory: temporary())
        let baseline = try repo.saveBaseline(settings: defaults, source: "test")
        let sessionID = UUID()
        let unresolved = OperationRecord(sessionID: sessionID, baselineVersion: baseline.version, kind: .restore, title: "unresolved", before: defaults, target: defaults)
        try repo.saveOperation(unresolved)
        for index in 0..<55 {
            var op = OperationRecord(sessionID: sessionID, baselineVersion: baseline.version, kind: .apply, title: String(index), before: defaults, target: defaults, createdAt: Date(timeIntervalSince1970: Double(index)))
            op.state = .completed; op.completedAt = op.createdAt
            try repo.saveOperation(op)
        }
        XCTAssertEqual(try repo.history().count, 50)
        XCTAssertEqual(try repo.operations().count, 51)
        XCTAssertThrowsError(try repo.saveBaseline(settings: defaults, source: "blocked"))
        var resolved = unresolved; resolved.state = .completed; resolved.completedAt = Date()
        try repo.saveOperation(resolved)
        let updated = try repo.saveBaseline(settings: defaults, source: "new")
        XCTAssertNotEqual(updated.version, baseline.version)
        XCTAssertEqual(try repo.baseline(), updated)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testLockIsExclusiveAcrossIndependentRepositoryInstances() throws {
        let directory = try temporary()
        let one = try Repository(directory: directory), two = try Repository(directory: directory)
        let lease = try CrossProcessLock(url: one.lockURL).acquire()
        XCTAssertThrowsError(try CrossProcessLock(url: two.lockURL).acquire()) { XCTAssertEqual(($0 as? CoreError)?.code, .busy) }
        lease.unlock()
        let next = try CrossProcessLock(url: two.lockURL).acquire(); next.unlock()
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testSQLiteBackupCapturesCommittedWALAndBaselineReferences() throws {
        let source = try Repository(directory: temporary())
        let baseline = try source.saveBaseline(settings: defaults, source: "test")
        let profile = try source.saveProfile(WorkProfile(language: "ja", region: "ja_JP", timeZone: "Asia/Tokyo"))
        try source.saveTimezonePreparation(TimezonePreparation(userConfirmed: true))
        let destination = try temporary()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try source.backupDatabase(to: destination.appendingPathComponent("localeshift.sqlite"))
        for backup in [false, true] {
            let file = source.baselineFileURL(version: baseline.version, backup: backup)
            try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
        }
        let snapshot = try Repository(directory: destination)
        XCTAssertEqual(try snapshot.profiles(), [profile])
        XCTAssertEqual(try snapshot.baseline(), baseline)
        let current = try snapshot.verifiedRecoverySnapshot()
        try Data("broken".utf8).write(to: snapshot.recoverySnapshotFileURL(generation: current.snapshot.generation))
        let previous = try Repository.verifiedRecoverySnapshot(directory: destination)
        XCTAssertFalse(previous.isCurrent)
        XCTAssertTrue(previous.requiresManualVerification)
    }

    private func corruptSQL(_ repository: Repository, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(repository.directory.appendingPathComponent("localeshift.sqlite").path, &db) == SQLITE_OK else { throw CoreError(.persistence) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CoreError(.persistence) }
    }
    private func recoveryFixture() throws -> (Repository, WorkSession, OperationRecord) {
        let repository = try Repository(directory: temporary())
        let baseline = try repository.saveBaseline(settings: defaults, source: "test")
        let session = WorkSession(baselineVersion: baseline.version, process: ProcessIdentity(pid: 123, startSeconds: 1, startMicroseconds: 2, bootID: "boot"), target: defaults, targetTitle: "test", lastKnownActual: defaults)
        let operation = OperationRecord(sessionID: session.id, baselineVersion: baseline.version, kind: .apply, title: "test", before: defaults, target: defaults)
        try repository.commit(operation: operation, session: session)
        return (repository, session, operation)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testChecksumDamageStopsPrimaryWritesButPreservesCompleteVerifiedSnapshot() throws {
        let (repository, session, operation) = try recoveryFixture()
        try corruptSQL(repository, "UPDATE operations SET payload=CAST(replace(CAST(payload AS TEXT),'checksum','damagedChecksum') AS BLOB)")
        XCTAssertThrowsError(try repository.operations()) { XCTAssertEqual(($0 as? CoreError)?.code, .dataCorrupt) }
        XCTAssertThrowsError(try repository.saveSession(nil)) { XCTAssertEqual(($0 as? CoreError)?.code, .dataCorrupt) }
        let evidence = try repository.verifiedRecoverySnapshot()
        XCTAssertEqual(evidence.snapshot.session, session)
        XCTAssertEqual(evidence.snapshot.operations, [operation])
        XCTAssertTrue(evidence.isCurrent)
        XCTAssertTrue(evidence.requiresManualVerification)
        XCTAssertEqual(evidence.baseline?.version, session.baselineVersion)
        let reopened = try Repository(directory: repository.directory)
        XCTAssertThrowsError(try reopened.activeSession())
        XCTAssertEqual(try reopened.verifiedRecoverySnapshot().snapshot, evidence.snapshot)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testDeletedSessionRowCannotSilentlyDiscardRecoveryDuty() throws {
        let (repository, session, _) = try recoveryFixture()
        try corruptSQL(repository, "DELETE FROM metadata WHERE key='active_session'")
        XCTAssertThrowsError(try repository.activeSession()) { XCTAssertEqual(($0 as? CoreError)?.code, .dataCorrupt) }
        XCTAssertEqual(try repository.verifiedRecoverySnapshot().snapshot.session, session)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testCompletedRecoverySnapshotNeverRevivesOlderSessionAndStaleBackupIsManualOnly() throws {
        let (repository, session, pending) = try recoveryFixture()
        var completed = pending; completed.kind = .restore; completed.state = .completed; completed.completedAt = Date()
        try repository.completeRecovery(operation: completed)
        let completedEvidence = try repository.verifiedRecoverySnapshot()
        XCTAssertNil(completedEvidence.snapshot.session)
        try corruptSQL(repository, "INSERT INTO metadata(key,value) VALUES('active_session',CAST('broken' AS BLOB))")
        XCTAssertThrowsError(try repository.activeSession())
        XCTAssertNil(try repository.verifiedRecoverySnapshot().snapshot.session)
        try Data("broken".utf8).write(to: repository.recoverySnapshotFileURL(generation: completedEvidence.snapshot.generation))
        let older = try repository.verifiedRecoverySnapshot()
        XCTAssertEqual(older.snapshot.session, session)
        XCTAssertFalse(older.isCurrent)
        XCTAssertTrue(older.requiresManualVerification)
        XCTAssertThrowsError(try repository.saveSession(older.snapshot.session))
        try Data("broken".utf8).write(to: repository.recoverySnapshotFileURL(generation: older.snapshot.generation))
        XCTAssertThrowsError(try repository.verifiedRecoverySnapshot()) { XCTAssertEqual(($0 as? CoreError)?.code, .dataCorrupt) }
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testIndependentSnapshotCanBeReadWhenDatabaseIsUnavailable() throws {
        let (repository, session, _) = try recoveryFixture()
        let evidence = try Repository.verifiedRecoverySnapshot(directory: repository.directory)
        XCTAssertEqual(evidence.snapshot.session, session)
        XCTAssertTrue(evidence.requiresManualVerification)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testIndependentEvidenceSurvivesAnUnreadableSQLiteDatabase() throws {
        func closedFixture() throws -> (URL, WorkSession) {
            let (repository, session, _) = try recoveryFixture()
            return (repository.directory, session)
        }
        let (directory, session) = try closedFixture()
        try Data("unreadable database".utf8).write(to: directory.appendingPathComponent("localeshift.sqlite"))
        XCTAssertThrowsError(try Repository(directory: directory))
        let evidence = try Repository.verifiedRecoverySnapshot(directory: directory)
        XCTAssertEqual(evidence.snapshot.session, session)
        XCTAssertEqual(evidence.baseline?.version, session.baselineVersion)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testMissingGenerationAndCurrentHeadCannotHideIndependentRecoveryRecords() throws {
        let (repository, _, _) = try recoveryFixture()
        try corruptSQL(repository, "DELETE FROM metadata WHERE key IN ('active_session','recovery_generation','recovery_digest'); DELETE FROM operations")
        try FileManager.default.removeItem(at: repository.directory.appendingPathComponent("recovery-head.json"))
        XCTAssertThrowsError(try repository.activeSession()) { XCTAssertEqual(($0 as? CoreError)?.code, .dataCorrupt) }
        XCTAssertThrowsError(try repository.saveSession(nil))
        let evidence = try repository.verifiedRecoverySnapshot()
        XCTAssertFalse(evidence.isCurrent)
        XCTAssertTrue(evidence.requiresManualVerification)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testIndependentRepositoryReadersNeverObserveMixedSnapshotGenerations() throws {
        let (writer, initial, _) = try recoveryFixture()
        let reader = try Repository(directory: writer.directory)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                for index in 0..<40 {
                    var next = initial
                    next.targetTitle = String(repeating: "snapshot", count: 2000) + String(index)
                    try writer.saveSession(next)
                }
            } catch { XCTFail("Concurrent writer failed: \(error)") }
        }
        for _ in 0..<100 {
            do { let session = try reader.activeSession(); XCTAssertNotNil(session) }
            catch { XCTFail("A consistent committed read must not be classified as corruption: \(error)") }
        }
        group.wait()
        XCTAssertNotNil(try reader.activeSession())
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testUnreferencedInitialStageDoesNotPretendToBeCommittedRecoveryData() throws {
        let repository = try Repository(directory: temporary())
        let stage = repository.directory.appendingPathComponent(".recovery-stage-\(UUID().uuidString).json")
        try Data("interrupted uncommitted stage".utf8).write(to: stage)
        XCTAssertNil(try repository.activeSession())
        XCTAssertFalse(try repository.timezonePreparation().userConfirmed)
        XCTAssertNotNil(try repository.saveBaseline(settings: defaults, source: "confirmed after interruption"))
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testCommittedStageIsPublishedFromMatchingDatabaseGeneration() throws {
        let (repository, session, _) = try recoveryFixture()
        let evidence = try repository.verifiedRecoverySnapshot()
        let published = repository.recoverySnapshotFileURL(generation: evidence.snapshot.generation)
        let stage = repository.directory.appendingPathComponent(".recovery-stage-\(evidence.snapshot.generation.uuidString).json")
        try FileManager.default.moveItem(at: published, to: stage)
        try FileManager.default.removeItem(at: repository.directory.appendingPathComponent("recovery-head.json"))
        XCTAssertEqual(try repository.activeSession(), session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path))
        XCTAssertEqual(try repository.verifiedRecoverySnapshot().snapshot.session, session)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testIndependentWritersSerializePublicationAndPruningAfterCommit() throws {
        let (one, initial, _) = try recoveryFixture()
        let two = try Repository(directory: one.directory)
        let group = DispatchGroup()
        for writer in [one, two] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    for index in 0..<35 {
                        var session = initial; session.targetTitle = String(repeating: "record", count: 1000) + String(index)
                        try writer.saveSession(session)
                        try writer.saveTimezonePreparation(TimezonePreparation(userConfirmed: index % 2 == 0))
                    }
                } catch { XCTFail("Independent writer must retain a valid live snapshot: \(error)") }
            }
        }
        group.wait()
        XCTAssertNotNil(try one.activeSession())
        XCTAssertTrue(try one.verifiedRecoverySnapshot().isCurrent)
        XCTAssertNotNil(try Repository(directory: one.directory).baseline())
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testInvalidBaselineAndProfileAreRejectedBeforeSaving() throws {
        let repository = try Repository(directory: temporary())
        var invalid = defaults; invalid.region = "garbage"
        XCTAssertThrowsError(try repository.saveBaseline(settings: invalid, source: "invalid"))
        invalid = defaults; invalid.languages = ["nonsense!"]
        XCTAssertThrowsError(try repository.saveBaseline(settings: invalid, source: "invalid"))
        XCTAssertNil(try repository.baseline())
        XCTAssertThrowsError(try repository.saveProfile(WorkProfile(language: "nonsense!", region: "en_US", timeZone: "America/New_York")))
        XCTAssertThrowsError(try repository.saveProfile(WorkProfile(language: "en-US", region: "garbage_US", timeZone: "America/New_York")))
        XCTAssertEqual(try repository.profiles().count, 0)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testInterruptedFirstBaselineStageDoesNotStrandUncommittedBaselineFiles() throws {
        let source = try Repository(directory: temporary())
        let baseline = try source.saveBaseline(settings: defaults, source: "candidate")
        let evidence = try source.verifiedRecoverySnapshot()
        let destination = try Repository(directory: temporary())
        for backup in [false, true] {
            let candidate = source.baselineFileURL(version: baseline.version, backup: backup)
            try FileManager.default.copyItem(at: candidate, to: destination.baselineFileURL(version: baseline.version, backup: backup))
        }
        let staged = destination.directory.appendingPathComponent(".recovery-stage-\(evidence.snapshot.generation.uuidString).json")
        try FileManager.default.copyItem(at: source.recoverySnapshotFileURL(generation: evidence.snapshot.generation), to: staged)
        XCTAssertNil(try destination.baseline())
        XCTAssertNotNil(try destination.saveBaseline(settings: defaults, source: "explicitly reconfirmed"))
    }

}
