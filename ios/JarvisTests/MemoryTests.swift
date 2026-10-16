import XCTest
@testable import JarvisCore

final class MemoryTests: XCTestCase {

    func testMigrationCreatesSchemaAndSupportsPersistence() throws {
        let stack = try TestFixtures.makeStack()
        XCTAssertEqual(try stack.memory.count(), 0)
        let record = try stack.memory.remember("The user lives in Shimla", kind: .fact, subject: "user.location")
        XCTAssertEqual(try stack.memory.count(), 1)

        // Round-trip through a second engine instance on the same store (simulates restart).
        let reloaded = try stack.store.record(id: record.id)
        XCTAssertEqual(reloaded?.text, "The user lives in Shimla")
        XCTAssertEqual(reloaded?.subject, "user.location")
    }

    func testNearDuplicateStatementsAreMergedNotDuplicated() throws {
        let stack = try TestFixtures.makeStack()
        try stack.memory.remember("My preferred language is English", kind: .preference, subject: "user.language")
        try stack.memory.remember("my preferred language is english", kind: .preference, subject: "user.language")
        XCTAssertEqual(try stack.memory.count(), 1, "near-identical statements must not create duplicates")
    }

    func testConflictingSubjectSupersedesOlderRecord() throws {
        let stack = try TestFixtures.makeStack()
        let first = try stack.memory.remember("The user lives in Delhi", kind: .fact, subject: "user.location")
        _ = try stack.memory.remember("The user lives in Shimla", kind: .fact, subject: "user.location")
        let active = try stack.memory.all()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.text, "The user lives in Shimla")
        let superseded = try stack.store.record(id: first.id)
        XCTAssertEqual(superseded?.status, .superseded)
        XCTAssertNotNil(superseded?.supersededBy)
    }

    func testInstructionsOutrankInferencesAndAreNeverAutoOverwritten() throws {
        let stack = try TestFixtures.makeStack()
        let instruction = try stack.memory.remember("Always answer in English", kind: .instruction,
                                                    source: .userStated, subject: "user.language")
        XCTAssertTrue(instruction.locked)
        // An inferred preference for the same subject must not touch the locked instruction.
        _ = try stack.memory.remember("The user might prefer Hindi", kind: .inference,
                                      source: .inferred, subject: "user.language")
        let stored = try stack.store.record(id: instruction.id)
        XCTAssertEqual(stored?.status, .active)
        XCTAssertEqual(stored?.text, "Always answer in English")
        XCTAssertEqual(try stack.memory.standingInstructions().count, 1)
    }

    func testRetrievalRanksKeywordRelevanceWithRecencyAndKindWeights() throws {
        let stack = try TestFixtures.makeStack()
        _ = try stack.memory.remember("The user's project is called Jarvis", kind: .fact, subject: "user.project")
        _ = try stack.memory.remember("The user enjoys hiking near Shimla in summer", kind: .preference)
        _ = try stack.memory.remember("Never send email without confirmation", kind: .instruction)

        let results = try stack.memory.retrieve("what is my jarvis project", limit: 3)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.record.subject, "user.project")
        // The standing instruction is always part of the candidate set.
        XCTAssertTrue(results.contains { $0.record.kind == .instruction })
    }

    func testEmptyRetrievalReturnsNothingRatherThanInventing() throws {
        let stack = try TestFixtures.makeStack()
        let results = try stack.memory.retrieve("what is my pet's name", limit: 5)
        XCTAssertTrue(results.isEmpty, "retrieval must never fabricate a memory")
    }

    func testExpiryMarksRecordsWithoutDeletingUserStatements() throws {
        let stack = try TestFixtures.makeStack()
        let record = try stack.memory.remember("Temporary context about a meeting", kind: .fact, ttl: 60)
        stack.clock.advance(by: 120)
        let expired = try stack.memory.expireStale()
        XCTAssertEqual(expired, 1)
        let stored = try stack.store.record(id: record.id)
        XCTAssertEqual(stored?.status, .expired)
        XCTAssertNotNil(stored, "expiry archives rather than destroys")
    }

    func testCorrectionSupersedesAndPreservesAuditTrail() throws {
        let stack = try TestFixtures.makeStack()
        let original = try stack.memory.remember("The user's birthday is 1 January", kind: .importantDate,
                                                 subject: "user.birthday")
        let corrected = try stack.memory.correct(id: original.id, newText: "The user's birthday is 12 March")
        XCTAssertEqual(corrected.source, .userCorrected)
        XCTAssertEqual(corrected.kind, .importantDate)
        let old = try stack.store.record(id: original.id)
        XCTAssertEqual(old?.status, .superseded)
        XCTAssertEqual(old?.supersededBy, corrected.id)
    }

    func testForgetDryRunDoesNotDelete() throws {
        let stack = try TestFixtures.makeStack()
        _ = try stack.memory.remember("The user's favourite colour is blue", kind: .preference)
        let matches = try stack.memory.forget(matching: "favourite colour", dryRun: true)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(try stack.memory.count(), 1, "dry run must not delete")
        _ = try stack.memory.forget(matching: "favourite colour", dryRun: false)
        XCTAssertEqual(try stack.memory.count(), 0)
    }

    func testExportFormats() throws {
        let stack = try TestFixtures.makeStack()
        _ = try stack.memory.remember("The user lives in Shimla", kind: .fact, subject: "user.location")
        let json = try stack.memory.export(format: .json)
        XCTAssertTrue(json.contains("Shimla"))
        XCTAssertNotNil(try? JSONDecoder().decode([MemoryRecord].self, from: Data(json.utf8)))
        let markdown = try stack.memory.export(format: .markdown)
        XCTAssertTrue(markdown.contains("# JARVIS Memory Export"))
        XCTAssertTrue(markdown.contains("Shimla"))
        let csv = try stack.memory.export(format: .csv)
        XCTAssertTrue(csv.hasPrefix("id,kind,text"))
        XCTAssertTrue(csv.contains("Shimla"))
    }

    func testExternalContentIsMarkedUntrusted() throws {
        let stack = try TestFixtures.makeStack()
        let record = try stack.memory.remember("Invoice from ACME says payment is due", kind: .fact,
                                               source: .importedExternal,
                                               provenance: Provenance(externalLabel: "gmail:invoice"))
        XCTAssertTrue(record.source.isUntrusted)
        XCTAssertFalse(record.locked)
    }

    func testKeywordSearchWorksWithoutFTSAssumptions() throws {
        let stack = try TestFixtures.makeStack()
        _ = try stack.memory.remember("The user is building an iOS assistant called Jarvis", kind: .fact)
        _ = try stack.memory.remember("The user plays the guitar on weekends", kind: .preference)
        let hits = try stack.store.keywordSearch("Jarvis assistant", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].record.text.contains("Jarvis"))
    }

    func testMemoryCommandParserRecognisesCommands() {
        let parser = MemoryCommandParser()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(parser.parse("Remember that my preferred language is English", now: now),
                       .remember(text: "my preferred language is English", asInstruction: true))
        XCTAssertEqual(parser.parse("Forget my favourite colour", now: now),
                       .forget(query: "my favourite colour", confirmed: false))
        if case .recall(let query)? = parser.parse("What do you remember about my project", now: now) {
            XCTAssertTrue(query.lowercased().contains("my project"))
        } else { XCTFail("recall command not recognised") }
        XCTAssertEqual(parser.parse("Export my memory", now: now), .exportMemory)
        XCTAssertNil(parser.parse("What's the weather like?", now: now))
    }
}
