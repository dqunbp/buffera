import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func check(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if try !value() { throw CheckFailure(description: "\(file):\(line): condition failed") }
}
func checkEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                              file: StaticString = #filePath, line: UInt = #line) throws {
    let first = try a(); let second = try b()
    if first != second { throw CheckFailure(description: "\(file):\(line): \(first) != \(second)") }
}
func checkNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
    try check(a() != b(), file: file, line: line)
}
func checkThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) throws {
    do { _ = try expression() } catch { return }
    throw CheckFailure(description: "\(file):\(line): expected an error")
}

let checks: [(String, (HistoryStoreTests) -> () throws -> Void)] = [
    ("All formats and items survive reopen", HistoryStoreTests.testAllFormatsAndItemsSurviveReopen),
    ("Duplicate moves to top", HistoryStoreTests.testDuplicateMovesToTopWithoutNewRecord),
    ("Date, type and search filters combine", HistoryStoreTests.testDateTypeAndCaseInsensitiveWordsCombine),
    ("SQL wildcards remain literal", HistoryStoreTests.testSearchTreatsSQLWildcardsLiterally),
    ("Source, query, type and date filters combine", HistoryStoreTests.testSourceCombinesWithQueryTypeAndDate),
    ("Source names match exactly and quotes remain literal", HistoryStoreTests.testSourceMatchesExactNamesAndBindsQuotesLiterally),
    ("Sources are distinct, nonempty and case-insensitively sorted", HistoryStoreTests.testSourcesAreDistinctNonemptyAndSortedIgnoringCase),
    ("Sources track deduplication and deletion", HistoryStoreTests.testSourceListTracksLastCopyAndDeletedRecords),
    ("Version one migration preserves history and payloads", HistoryStoreTests.testVersionOneMigrationPreservesRecordsAndPayloads),
    ("Version two migration preserves concealed history and payloads", HistoryStoreTests.testVersionTwoMigrationPreservesConcealmentAndPayloads),
    ("Favorites survive repeat writes, reopen, deduplication and concealment", HistoryStoreTests.testFavoriteSurvivesRepeatSetReopenDeduplicationAndConcealment),
    ("Favorite filtering combines with all filters and pagination", HistoryStoreTests.testFavoriteFilterCombinesWithOtherFiltersAndPagination),
    ("Favorites bypass count limits; unstar waits for next capture", HistoryStoreTests.testFavoriteExcludedFromCountLimitUntilNextCaptureAfterUnstar),
    ("Favorites bypass byte limits and explicit deletion still cascades", HistoryStoreTests.testFavoriteExcludedFromByteLimitAndExplicitDeletionStillCascades),
    ("Missing favorite update throws and leaves history usable", HistoryStoreTests.testSettingMissingFavoriteThrowsMissingAndLeavesStoreUsable),
    ("Concealed metadata excludes original text", HistoryStoreTests.testConcealedMetadataNeverContainsPayloadText),
    ("Deduplication never removes concealment", HistoryStoreTests.testDeduplicationCannotRemoveConcealment),
    ("Newer schemas are not downgraded", HistoryStoreTests.testNewerSchemaIsNotDowngraded),
    ("Manual concealment preserves payload and survives reopen", HistoryStoreTests.testManualConcealmentPreservesPayloadAndSurvivesReopen),
    ("Missing concealment rolls back and leaves store usable", HistoryStoreTests.testConcealingMissingRecordLeavesStoreUsable),
    ("Count limit removes oldest payload", HistoryStoreTests.testPruningRemovesOldestPayloadAndRetainsNewest),
    ("Byte limit and cascading deletion", HistoryStoreTests.testByteLimitPrunesAndDeleteCascades),
    ("Stable pagination", HistoryStoreTests.testPaginationHasStableTieOrdering),
    ("Fingerprint item boundaries", HistoryStoreTests.testFingerprintPreservesGroupingButIgnoresTypeOrdering),
    ("Invalid payload leaves history intact", HistoryStoreTests.testInvalidPayloadDoesNotAlterHistory)
]
var failures = 0
for (name, run) in checks {
    let suite = HistoryStoreTests()
    do {
        try suite.setUpWithError()
        defer { try? suite.tearDownWithError() }
        try run(suite)()
        print("PASS: \(name)")
    } catch { failures += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
}
print("\(checks.count - failures)/\(checks.count) checks passed")
exit(failures == 0 ? 0 : 1)
