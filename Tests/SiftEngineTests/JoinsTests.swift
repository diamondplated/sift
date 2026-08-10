import Testing
import Foundation
import DuckDBKit
@testable import SiftCore
@testable import SiftEngine

// Joins, key probing and merge. session.py has no engine/tests/test_session.py counterpart to
// port assertion-for-assertion (SessionTests.swift's header explains why), so these are the Task
// 7 brief's own required properties: the semi-join/anti-join SHAPE that makes `join_probe`'s one
// number mean what it says, `join_candidates` keeping the file's column order, and `merge`
// building a VIEW whose key columns appear once and whose other clashes are disambiguated.
//
// Each test gets its own `~/.sift`-equivalent temp directory (`newSession()`), never the real
// one — Swift Testing runs in parallel and two sessions sharing a home would race on DuckDB's
// exclusive file lock.

private func newSession() throws -> Session {
    try Session(
        home: FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-joins-tests-\(UUID().uuidString)").path
    )
}

// MARK: - the join fixture
//
// Deliberately shaped so every property below has something to bite on:
//
//  - `k` is the key. The left side has a DUPLICATE key (2 appears twice) and a NULL key; the
//    right side has a duplicate too (1 appears twice). That makes distinct-key counting and
//    pairing counting produce different numbers, which is the whole reason `join_probe` is a
//    semi join.
//  - The two files share five columns (zz, k, v, big, aaa) in DIFFERENT orders, so a candidate
//    list that came out of an unordered dictionary cannot accidentally look right.
//  - `v` is integers on the left and letters on the right (incompatible kinds); `big` is whole
//    numbers on the left and decimals on the right (different type strings, same kind).

struct JoinCorpus: Sendable {
    let dir: String
    let lhs: String
    let rhs: String
}

private func makeJoinCorpus() throws -> JoinCorpus {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sift-joins-fixtures-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let lhs = (dir as NSString).appendingPathComponent("lhs.csv")
    try """
    zz,k,v,extra,big,aaa
    alpha,1,10,e1,100,A
    beta,2,20,e2,200,B
    beta,2,21,e3,300,C
    gamma,3,30,e4,400,D
    delta,,40,e5,500,E

    """.write(toFile: lhs, atomically: true, encoding: .utf8)

    let rhs = (dir as NSString).appendingPathComponent("rhs.csv")
    try """
    k,v,zz,rextra,aaa,big
    1,x,alpha,r1,P,1.5
    1,x,alpha,r2,Q,2.5
    2,y,beta,r3,R,3.5
    9,z,omega,r4,S,4.5

    """.write(toFile: rhs, atomically: true, encoding: .utf8)

    return JoinCorpus(dir: dir, lhs: lhs, rhs: rhs)
}

private let joinData = try! makeJoinCorpus()

/// Open both sides of the fixture into one session and return it.
private func sessionWithBothSides() async throws -> Session {
    let session = try newSession()
    _ = try await session.openPath(joinData.lhs)
    _ = try await session.openPath(joinData.rhs)
    return session
}

// MARK: - join_probe

@Test func joinProbeCountsDistinctKeysNotRowsAndNotPairings() async throws {
    let session = try await sessionWithBothSides()
    let probe = try await session.joinProbe("lhs", "rhs", on: ["k"])

    // Five physical rows on the left, four distinct key values (1, 2, 3, NULL) — the duplicate
    // 2 collapses. Counting rows here would say 5.
    #expect(probe.leftDistinct == 4)
    // Two of them find a partner (1 and 2). Counting PAIRINGS of the raw key columns instead
    // says 4 — key 1 pairs with two right rows, and key 2's two left rows pair with one right
    // row — which answers "how many pairings exist", not "how many of my keys line up". Keeping
    // that number off the screen is what this test is for.
    //
    // Said honestly, because it is the kind of thing a green test hides: TWO independent things
    // in `joinProbe` each prevent that 4, and MEASURED, removing either one alone leaves this
    // assertion green — the subqueries are DISTINCT (so there is nothing left to multiply) and
    // the join is a SEMI join (so the right side cannot multiply anyway). Only removing BOTH
    // turns this red. The belt-and-braces is deliberate; the mutation log in task-7-report.md
    // records which single mutations survive here and why.
    #expect(probe.matched == 2)
    #expect(probe.unmatched == 2)
    #expect(probe.pct == 0.5)
    #expect(probe.left == "lhs" && probe.right == "rhs" && probe.on == ["k"])
}

@Test func joinProbeCountsANullKeyTowardTheDenominatorAndNeverTowardMatched() async throws {
    let session = try await sessionWithBothSides()
    let probe = try await session.joinProbe("lhs", "rhs", on: ["k"])
    // The left's four distinct keys include NULL, and the right has no NULL key at all — but
    // even if it did, `USING` compares with `=` and NULL = NULL is unknown, so a NULL key can
    // never be reported as matched. Pinned so it cannot later be "fixed" into a lie: a NULL key
    // genuinely does not join, and saying so is the point of the number.
    let unmatched = try await session.unmatchedKeys("lhs", "rhs", on: ["k"])
    #expect(unmatched.rows.count == probe.unmatched)
    #expect(unmatched.rows.contains { $0[0] == .null })
}

@Test func joinProbeHandlesACompositeKey() async throws {
    let session = try await sessionWithBothSides()
    let probe = try await session.joinProbe("lhs", "rhs", on: ["k", "zz"])
    // (1,alpha), (2,beta) [twice, collapsed], (3,gamma), (NULL,delta) — four distinct tuples,
    // two of which the right side also has.
    #expect(probe.leftDistinct == 4)
    #expect(probe.matched == 2)
}

@Test func joinProbeRejectsAKeyMissingFromEitherSide() async throws {
    let session = try await sessionWithBothSides()
    await #expect(throws: SessionError("No column 'extra' in rhs.")) {
        try await session.joinProbe("lhs", "rhs", on: ["extra"])
    }
    await #expect(throws: SessionError("No column 'rextra' in lhs.")) {
        try await session.joinProbe("lhs", "rhs", on: ["rextra"])
    }
    await #expect(throws: SessionError("No open table named 'nope'.")) {
        try await session.joinProbe("nope", "rhs", on: ["k"])
    }
}

/// DIVERGENCE from Python, which interpolates an empty key list into `SELECT DISTINCT  FROM x`
/// and hands the user a parser dump. Only `merge` refuses cleanly there; all three do here.
@Test func joinProbeAndUnmatchedKeysRefuseAnEmptyKeyListInsteadOfEmittingBrokenSQL() async throws {
    let session = try await sessionWithBothSides()
    let expected = SessionError("Pick at least one key column to join on.")
    await #expect(throws: expected) { try await session.joinProbe("lhs", "rhs", on: []) }
    await #expect(throws: expected) { try await session.unmatchedKeys("lhs", "rhs", on: []) }
    await #expect(throws: expected) { try await session.merge("lhs", "rhs", on: []) }
}

// MARK: - unmatched_keys

@Test func unmatchedKeysListsExactlyTheKeysJoinProbeCounted() async throws {
    let session = try await sessionWithBothSides()
    let unmatched = try await session.unmatchedKeys("lhs", "rhs", on: ["k"])

    #expect(unmatched.columns.map(\.name) == ["k"])
    // Anti join, so only the LEFT side's key columns come back — and only distinct ones, so the
    // duplicated key 2 could not appear twice even if it were unmatched.
    #expect(unmatched.rows.count == 2)
    let values = Set(unmatched.rows.map { $0[0].display })
    #expect(values == ["3", ""])   // "" is the NULL key's display
}

@Test func unmatchedKeysHonorsItsLimit() async throws {
    let session = try await sessionWithBothSides()
    let capped = try await session.unmatchedKeys("lhs", "rhs", on: ["k"], limit: 1)
    #expect(capped.rows.count == 1)
}

/// DIVERGENCE from Python, reported: `unmatched_keys` there never resolves the tables and never
/// checks the keys, so this exact call escapes as a raw binder exception instead of the one
/// clean sentence every other session method contracts for.
@Test func unmatchedKeysRejectsATypoInsteadOfLeakingABinderError() async throws {
    let session = try await sessionWithBothSides()
    await #expect(throws: SessionError("No column 'kk' in lhs.")) {
        try await session.unmatchedKeys("lhs", "rhs", on: ["kk"])
    }
    await #expect(throws: SessionError("No open table named 'nope'.")) {
        try await session.unmatchedKeys("lhs", "nope", on: ["k"])
    }
}

// MARK: - join_candidates

@Test func joinCandidatesFollowEachSidesOwnFileColumnOrder() async throws {
    let session = try await sessionWithBothSides()

    // The two files share five columns in DIFFERENT orders. Each direction must report ITS
    // left-hand file's order — which is the property that dies the moment this iterates the
    // `cols` dictionary (Swift dictionaries have no iteration order) instead of `spec.columns`.
    // Two independent five-element orderings make an accidental agreement ~1 in 14,000.
    #expect(try await session.joinCandidates("lhs", "rhs").map(\.col) == ["zz", "k", "v", "big", "aaa"])
    #expect(try await session.joinCandidates("rhs", "lhs").map(\.col) == ["k", "v", "zz", "aaa", "big"])
}

@Test func joinCandidatesOmitColumnsTheOtherSideDoesNotHave() async throws {
    let session = try await sessionWithBothSides()
    let cols = try await session.joinCandidates("lhs", "rhs").map(\.col)
    #expect(!cols.contains("extra"))    // lhs-only
    #expect(!cols.contains("rextra"))   // rhs-only
}

@Test func joinCandidateCompatibilityIsByKindNotByTypeString() async throws {
    let session = try await sessionWithBothSides()
    let byName = Dictionary(
        uniqueKeysWithValues: try await session.joinCandidates("lhs", "rhs").map { ($0.col, $0) }
    )

    // Same kind, DIFFERENT type strings: whole numbers on the left, decimals on the right.
    // Comparing `leftType == rightType` would call this incompatible and hide a perfectly good
    // key, so the guard is that the strings really do differ here.
    let big = try #require(byName["big"])
    #expect(big.leftType != big.rightType)
    #expect(kind(of: big.leftType) == .number && kind(of: big.rightType) == .number)
    #expect(big.compatible)

    // Different kinds: integers on the left, letters on the right.
    let v = try #require(byName["v"])
    #expect(!v.compatible)

    // Identical types.
    #expect(byName["k"]?.compatible == true)
    #expect(byName["zz"]?.compatible == true)
}

// MARK: - merge

@Test func mergeCreatesAViewNotACopy() async throws {
    let session = try await sessionWithBothSides()
    let merged = try await session.merge("lhs", "rhs", on: ["k"])

    #expect(merged.name == "lhs_rhs")
    #expect(merged.spec.fmt == .merge)
    #expect(merged.spec.key.path == "merge://lhs+rhs")
    #expect(merged.staged == false)
    #expect(merged.notes.contains { $0.contains("inner join of lhs + rhs on k") })
    #expect(merged.notes.contains { $0.contains("Export it to save a copy") })

    // The object in the store really is a VIEW. `duckdb_tables()` lists tables only and
    // `duckdb_views()` lists views only, so this tells a view from a materialization no matter
    // what the row counts say — the property the brief says must not be "improved" away.
    // Asked through `runSQL`, which runs on this session's own database.
    let asView = try await session.runSQL(
        "lhs", sql: "SELECT count(*) FROM duckdb_views() WHERE view_name = 'lhs_rhs'",
        offset: 0, limit: 10
    )
    let asTable = try await session.runSQL(
        "lhs", sql: "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'lhs_rhs'",
        offset: 0, limit: 10
    )
    #expect(asView.rows[0][0] == .int(1))
    #expect(asTable.rows[0][0] == .int(0))
}

@Test func mergeKeepsOneCopyOfTheKeyAndSuffixesEveryOtherClash() async throws {
    let session = try await sessionWithBothSides()
    let merged = try await session.merge("lhs", "rhs", on: ["k"])

    // MEASURED against the vendored DuckDB, and pinned rather than asserted loosely: left's
    // columns in file order (the key `k` among them, exactly ONCE), then the right's non-key
    // columns with `_1` appended to each name the left already used.
    //
    // Note what this is NOT: Python's own `merge` docstring claims the disambiguation is
    // DuckDB's "usual `right.col`". No column called `right.v` exists — that docstring describes
    // behavior this engine does not have. If a future DuckDB changes the suffix, this test goes
    // red instead of a surprise column reaching the grid.
    #expect(merged.spec.columns.map(\.name) == [
        "zz", "k", "v", "extra", "big", "aaa", "v_1", "zz_1", "rextra", "aaa_1", "big_1",
    ])
    #expect(merged.spec.columns.filter { $0.name == "k" }.count == 1)

    // And the view really returns that shape, not just the DESCRIBE of it.
    let page = try await session.page(merged.name, offset: 0, limit: 100)
    #expect(page.columns.map(\.name) == merged.spec.columns.map(\.name))
}

@Test func mergeRowCountsFollowTheJoinType() async throws {
    // inner: key 1 pairs 1x2, key 2 pairs 2x1 -> 4.
    // left:  + the two left rows whose key (3, NULL) has no partner -> 6.
    // right: + the one right row whose key (9) has no partner -> 5.
    // full:  both -> 7.
    for (how, expected) in [(JoinType.inner, 4), (.left, 6), (.right, 5), (.full, 7)] {
        let session = try await sessionWithBothSides()
        let merged = try await session.merge("lhs", "rhs", on: ["k"], how: how)
        #expect(merged.rowCount == expected, "\(how.rawValue) join")
        let page = try await session.page(merged.name, offset: 0, limit: 100)
        #expect(page.rows.count == expected, "\(how.rawValue) join, paged")
    }
}

@Test func mergedTableIsProfiledEagerlyAndPageable() async throws {
    let session = try await sessionWithBothSides()
    let merged = try await session.merge("lhs", "rhs", on: ["k"])

    // Python profiles it eagerly, before announcing it, so the sidebar never shows a source with
    // no profile. `merge` returns the catalog's copy, so the profile has to be ON the value it
    // handed back — not just computable afterwards.
    let profile = try #require(merged.profile)
    #expect(profile.map(\.name) == merged.spec.columns.map(\.name))
    #expect(try await session.table(merged.name).profile != nil)
}

@Test func mergeNamesCollideIntoASuffixAndAnExplicitNameIsHonored() async throws {
    let session = try await sessionWithBothSides()
    let first = try await session.merge("lhs", "rhs", on: ["k"])
    let second = try await session.merge("lhs", "rhs", on: ["k"])
    #expect(first.name == "lhs_rhs")
    #expect(second.name == "lhs_rhs_2")

    let named = try await session.merge("lhs", "rhs", on: ["k"], name: "My Merge!")
    #expect(named.name == "my_merge")
}

@Test func mergeGetsItsOwnOpenGenerationSoBackgroundWorkCannotCrossOverIntoIt() async throws {
    let session = try await sessionWithBothSides()
    let lhs = try await session.table("lhs")
    let rhs = try await session.table("rhs")
    let first = try await session.merge("lhs", "rhs", on: ["k"])
    let second = try await session.merge("lhs", "rhs", on: ["k"])

    // `openedAt` is what stops a background result meant for one table from landing on a
    // different table that later took its name, so every table in the catalog needs its own —
    // and specifically NOT the one the most recent open is already using, which is exactly what
    // a merge that reads the counter without incrementing it would take.
    let generations = [lhs.openedAt, rhs.openedAt, first.openedAt, second.openedAt]
    #expect(Set(generations).count == 4)
    #expect(generations.allSatisfy { $0 > 0 })
}

@Test func mergeRejectsAKeyMissingFromEitherSide() async throws {
    let session = try await sessionWithBothSides()
    await #expect(throws: SessionError("No column 'rextra' in lhs.")) {
        try await session.merge("lhs", "rhs", on: ["rextra"])
    }
    await #expect(throws: SessionError("No open table named 'nope'.")) {
        try await session.merge("lhs", "nope", on: ["k"])
    }
}

@Test func closingAMergedTableRemovesItsViewAndFreesTheName() async throws {
    let session = try await sessionWithBothSides()
    let merged = try await session.merge("lhs", "rhs", on: ["k"])
    try await session.closeTable(merged.name)
    await #expect(throws: SessionError("No open table named 'lhs_rhs'.")) {
        try await session.table(merged.name)
    }
    // The name is free again, and re-merging reuses it rather than climbing to _2 — which only
    // works if `closeTable` actually dropped the view underneath.
    #expect(try await session.merge("lhs", "rhs", on: ["k"]).name == "lhs_rhs")
}
