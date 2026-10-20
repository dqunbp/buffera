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
    ("Read-only open never creates or migrates history", HistoryStoreTests.testReadOnlyDoesNotCreateOrMigrateHistory),
    ("Read-only connection rejects writes and sees writer commits", HistoryStoreTests.testReadOnlyRejectsWritesAndSeesNewWriterCommits),
    ("Read snapshots stay coherent across commits and recover after errors", HistoryStoreTests.testReadSnapshotIsCoherentAcrossConcurrentCommitsAndEndsAfterFailure),
    ("Visible search excludes concealed rows before pagination", HistoryStoreTests.testVisibleSearchFiltersConcealedRowsBeforePagination),
    ("Visible nearby skips hidden neighbors and rejects hidden anchors", HistoryStoreTests.testVisibleNearbySkipsHiddenNeighborsAndRejectsHiddenAnchor),
    ("Visible content limits payload access and returns only completed OCR", HistoryStoreTests.testVisibleContentReturnsOnlyEligiblePayloadAndCompletedOCR),
    ("Shared text decoder preserves complete plaintext and representation priority", HistoryStoreTests.testSharedTextDecoderPreservesFullPlainTextAndPrefersItOverRTF),
    ("Shared text decoder falls back to RTF and keeps items separate", HistoryStoreTests.testSharedTextDecoderFallsBackToRTFAndPreservesItemBoundaries),
    ("Plain text retains complete content and transforms bound UTF-8 bytes", HistoryStoreTests.testPlainTextPreservesCompleteContentAndTransformByteLimit),
    ("JSON formatting preserves number precision, duplicate keys and string lexemes", HistoryStoreTests.testJSONFormattingPreservesNumbersKeysAndStringLexemes),
    ("JSON rejects invalid syntax and bounds nesting and expanded output", HistoryStoreTests.testJSONRejectsInvalidSyntaxAndBoundsDepthAndOutput),
    ("Line unwrapping preserves paragraphs and normalizes newlines", HistoryStoreTests.testUnwrapPreservesParagraphsAndNormalizesLineEndings),
    ("Duplicate lines compare exact content and preserve blank lines", HistoryStoreTests.testDuplicateLinesUseExactContentAndPreserveBlankLines),
    ("Link cleanup preserves untouched raw values, order and fragments", HistoryStoreTests.testURLCleaningPreservesRawValuesOrderFragmentAndUntouchedNames),
    ("Link cleanup rejects invalid and modified signed links", HistoryStoreTests.testURLCleaningRejectsInvalidOrModifiedSignedLinks),
    ("Summary getter reads current metadata without loading payload", HistoryStoreTests.testSummaryGetterReflectsCurrentMetadataAndDoesNotLoadPayload),
    ("OCR getter distinguishes complete empty, pending, failed and hidden records", HistoryStoreTests.testImageTextGetterDistinguishesCompletedEmptyPendingFailedAndHidden),
    ("All formats and items survive reopen", HistoryStoreTests.testAllFormatsAndItemsSurviveReopen),
    ("Duplicate moves to top", HistoryStoreTests.testDuplicateMovesToTopWithoutNewRecord),
    ("Using a clip promotes it without changing captured metadata", HistoryStoreTests.testMarkUsedPromotesWithoutChangingCapturedMetadata),
    ("Usage preserves date filters and persists after reopen", HistoryStoreTests.testMarkUsedPreservesDateFiltersAndPersistsAfterReopen),
    ("Use recency pagination keeps stable tie ordering", HistoryStoreTests.testUseRecencyPaginationHasStableTies),
    ("Count pruning retains used clips and cascades unused payloads", HistoryStoreTests.testPruningKeepsRecentlyUsedRecordsAndCascadesUnusedPayloads),
    ("Byte pruning retains used clips", HistoryStoreTests.testBytePruningKeepsRecentlyUsedRecords),
    ("Repeat capture after use updates recency and source", HistoryStoreTests.testRepeatCaptureAfterUseUpdatesRecencyAndSource),
    ("Missing usage update throws and leaves history usable", HistoryStoreTests.testMissingMarkUsedThrowsMissingAndLeavesStoreUsable),
    ("Nearby uses capture order across search filters", HistoryStoreTests.testNearbyUsesCaptureOrderAcrossSearchFilters),
    ("Nearby equal dates have stable sides without duplicates", HistoryStoreTests.testNearbyEqualDatesHaveStableSidesWithoutDuplicates),
    ("Nearby bounds the default window and requested counts", HistoryStoreTests.testNearbyBoundsDefaultWindowAndCounts),
    ("Nearby refreshes repeated capture dates and sources", HistoryStoreTests.testNearbyRefreshesRepeatedCaptureDateAndSource),
    ("Nearby preserves concealment without loading payloads", HistoryStoreTests.testNearbyPreservesConcealmentWithoutLoadingPayloads),
    ("Missing or deleted nearby anchors leave history usable", HistoryStoreTests.testNearbyMissingOrDeletedAnchorThrowsAndLeavesStoreUsable),
    ("Date, type and search filters combine", HistoryStoreTests.testDateTypeAndCaseInsensitiveWordsCombine),
    ("SQL wildcards remain literal", HistoryStoreTests.testSearchTreatsSQLWildcardsLiterally),
    ("Source, query, type and date filters combine", HistoryStoreTests.testSourceCombinesWithQueryTypeAndDate),
    ("Source names match exactly and quotes remain literal", HistoryStoreTests.testSourceMatchesExactNamesAndBindsQuotesLiterally),
    ("Sources are distinct, nonempty and case-insensitively sorted", HistoryStoreTests.testSourcesAreDistinctNonemptyAndSortedIgnoringCase),
    ("Sources track deduplication and deletion", HistoryStoreTests.testSourceListTracksLastCopyAndDeletedRecords),
    ("Version one migration preserves history and payloads", HistoryStoreTests.testVersionOneMigrationPreservesRecordsAndPayloads),
    ("Version two migration preserves concealed history and payloads", HistoryStoreTests.testVersionTwoMigrationPreservesConcealmentAndPayloads),
    ("Version three migration backfills only visible images", HistoryStoreTests.testVersionThreeMigrationBackfillsOnlyVisibleImagesWithoutChangingHistory),
    ("Version four migration preserves unknown origins, payloads and OCR", HistoryStoreTests.testVersionFourMigrationPreservesUnknownOriginsPayloadsAndOCR),
    ("Version five migration preserves ordering, metadata, payloads and OCR", HistoryStoreTests.testVersionFiveMigrationPreservesOrderingMetadataPayloadsAndOCR),
    ("Remote and concealed filters combine with pagination and existing filters", HistoryStoreTests.testRemoteAndConcealedFiltersCombineWithPaginationAndExistingFilters),
    ("Latest capture controls origin while concealment, favorite and OCR persist", HistoryStoreTests.testOriginFollowsLatestCaptureWhileConcealmentFavoriteAndOCRPersist),
    ("Sources exclude remote rows but keep shared local apps", HistoryStoreTests.testSourcesExcludeRemoteRowsWithoutHidingSharedLocalApps),
    ("Image-text jobs are eligible and ordered newest first", HistoryStoreTests.testImageTextQueueEligibilityAndNewestOrdering),
    ("Image-text search combines base text, filters and literal wildcards", HistoryStoreTests.testImageTextSearchCombinesBaseWordsFiltersAndLiteralWildcards),
    ("Deduplication preserves image text; concealment removes it", HistoryStoreTests.testImageTextDeduplicationPreservesResultButConcealmentRemovesIt),
    ("Hidden and deleted images reject late recognition results", HistoryStoreTests.testConcealedAndDeletedImagesRejectLateTextResults),
    ("Pruning cascades image text while preserving favorites", HistoryStoreTests.testPruningCascadesImageTextButKeepsFavorites),
    ("Empty text, failure, retry and pending jobs survive reopen", HistoryStoreTests.testEmptyImageTextFailureRetryAndPendingJobsSurviveReopen),
    ("Image text bounds raw and normalized values without changing payload", HistoryStoreTests.testImageTextBoundsRawAndNormalizedIndexWithoutChangingPayload),
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
