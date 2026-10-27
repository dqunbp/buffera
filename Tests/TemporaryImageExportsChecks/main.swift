import Foundation

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "TemporaryImageExportsChecks", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: message]) }
}

let manager = FileManager.default
let sandbox = manager.temporaryDirectory.appendingPathComponent("BufferaExportChecks-\(UUID().uuidString)", isDirectory: true)
try manager.createDirectory(at: sandbox, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: sandbox) }
let directory = sandbox.appendingPathComponent("Images", isDirectory: true)
let cache = TemporaryImageExports(directory: directory, maximumBytes: 8)
let oldDate = Date().addingTimeInterval(-25 * 60 * 60)

let original = try cache.file(data: Data([1, 2, 3, 4]), id: 1, fileExtension: "png")
try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: original.path)
let repeated = try cache.file(data: Data([5, 6, 7, 8]), id: 1, fileExtension: "png")
try check(repeated == original, "Repeated exports should reuse one path")
try check(try Data(contentsOf: repeated) == Data([5, 6, 7, 8]), "Repeated export should atomically replace its contents")
try cache.cleanup()
try check(manager.fileExists(atPath: repeated.path), "Opening again must refresh the lifetime")
try check((try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700,
          "The cache directory must be private")
try check((try manager.attributesOfItem(atPath: repeated.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
          "Export files must be private")

try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: original.path)
let second = try cache.file(data: Data([1, 2, 3, 4, 5]), id: 2, fileExtension: "png")
try check(!manager.fileExists(atPath: original.path), "The oldest export must be evicted when the cache exceeds its limit")
try check(manager.fileExists(atPath: second.path), "The file requested for Finder must survive eviction")

let foreign = directory.appendingPathComponent("keep.txt")
try Data([9]).write(to: foreign)
try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: foreign.path)
let outside = sandbox.appendingPathComponent("outside.png")
try Data([10]).write(to: outside)
let linked = directory.appendingPathComponent("Buffera-3.png")
try manager.createSymbolicLink(at: linked, withDestinationURL: outside)
try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: second.path)
try cache.cleanup()
try check(!manager.fileExists(atPath: second.path), "Unused exports must expire after 24 hours")
try check(try Data(contentsOf: foreign) == Data([9]), "Unrelated files must not be removed")
try check(try Data(contentsOf: outside) == Data([10]), "Symlink targets must not be touched")
try check(try manager.attributesOfItem(atPath: linked.path)[.type] as? FileAttributeType == .typeSymbolicLink,
          "Cleanup must not touch links")
do {
    _ = try cache.file(data: Data([11]), id: 3, fileExtension: "png")
    throw NSError(domain: "TemporaryImageExportsChecks", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "An export must not overwrite a symlink"])
} catch let error as CocoaError {
    try check(error.code == .fileWriteNoPermission, "A symlink destination must fail safely")
}
do {
    _ = try cache.file(data: Data([11]), id: 4, fileExtension: "../outside")
    throw NSError(domain: "TemporaryImageExportsChecks", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "An extension must not escape the cache directory"])
} catch let error as CocoaError {
    try check(error.code == .fileWriteInvalidFileName, "An invalid extension must fail safely")
}

let redirect = sandbox.appendingPathComponent("Redirect", isDirectory: true)
try manager.createSymbolicLink(at: redirect, withDestinationURL: directory)
do {
    try TemporaryImageExports(directory: redirect).cleanup()
    throw NSError(domain: "TemporaryImageExportsChecks", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "The cache directory must not be a symlink"])
} catch let error as CocoaError {
    try check(error.code == .fileWriteNoPermission, "A redirected cache directory must fail safely")
}

let legacyContainer = sandbox.appendingPathComponent("OldContainer", isDirectory: true)
let legacyDirectory = legacyContainer.appendingPathComponent("ImageExports", isDirectory: true)
let renamedDirectory = sandbox.appendingPathComponent("RenamedImages", isDirectory: true)
let renamedCache = TemporaryImageExports(directory: renamedDirectory, legacyDirectory: legacyDirectory,
                                         maximumBytes: 8)
try renamedCache.cleanup()
try check(!manager.fileExists(atPath: legacyContainer.path), "Cleanup must not create an absent legacy container")
try manager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

let expiredLegacy = legacyDirectory.appendingPathComponent("Bufera-10.png")
let freshLegacy = legacyDirectory.appendingPathComponent("Bufera-11.png")
let foreignLegacy = legacyDirectory.appendingPathComponent("keep.txt")
let unrecognizedLegacy = legacyDirectory.appendingPathComponent("Bufera-not-an-id.png")
let linkedLegacy = legacyDirectory.appendingPathComponent("Bufera-12.png")
let hardLinkedLegacy = legacyDirectory.appendingPathComponent("Bufera-13.png")
for url in [expiredLegacy, foreignLegacy, unrecognizedLegacy] {
    try Data([8]).write(to: url)
    try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
}
try Data([1, 2, 3, 4]).write(to: freshLegacy)
try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: freshLegacy.path)
try manager.createSymbolicLink(at: linkedLegacy, withDestinationURL: outside)
try manager.linkItem(at: outside, to: hardLinkedLegacy)
try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: outside.path)
try renamedCache.cleanup()
try check(!manager.fileExists(atPath: expiredLegacy.path), "Exports from before the rename must expire")
try check(manager.fileExists(atPath: freshLegacy.path), "A fresh legacy export should keep its normal lifetime")
try check(manager.fileExists(atPath: legacyDirectory.path), "Cleanup must not remove the legacy directory")
try check(try Data(contentsOf: foreignLegacy) == Data([8]), "Unrelated legacy files must survive cleanup")
try check(try Data(contentsOf: unrecognizedLegacy) == Data([8]), "Only exact legacy export filenames may be removed")
try check(try manager.attributesOfItem(atPath: linkedLegacy.path)[.type] as? FileAttributeType == .typeSymbolicLink,
          "Legacy symlinks must not be removed")
try check(try Data(contentsOf: hardLinkedLegacy) == Data([10]), "Legacy hard links must not be removed")
try check(try Data(contentsOf: outside) == Data([10]), "Legacy link targets must not be changed")

let renamedFile = try renamedCache.file(data: Data([1, 2, 3, 4, 5]), id: 14, fileExtension: "png")
try check(renamedFile.lastPathComponent == "Buffera-14.png", "New exports must use the new app name")
try check(!manager.fileExists(atPath: freshLegacy.path), "The combined cache size limit must include old exports")
try check(manager.fileExists(atPath: renamedFile.path), "Newly requested exports must survive combined eviction")

let redirectedLegacyFile = legacyDirectory.appendingPathComponent("Bufera-15.png")
try Data([15]).write(to: redirectedLegacyFile)
try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: redirectedLegacyFile.path)
let redirectedLegacyContainer = sandbox.appendingPathComponent("RedirectLegacyContainer", isDirectory: true)
try manager.createSymbolicLink(at: redirectedLegacyContainer, withDestinationURL: legacyContainer)
try TemporaryImageExports(directory: renamedDirectory,
                          legacyDirectory: redirectedLegacyContainer.appendingPathComponent("ImageExports")).cleanup()
try check(manager.fileExists(atPath: redirectedLegacyFile.path), "A linked legacy parent must not be traversed")
let redirectedLegacyDirectory = sandbox.appendingPathComponent("RedirectLegacyImages", isDirectory: true)
try manager.createSymbolicLink(at: redirectedLegacyDirectory, withDestinationURL: legacyDirectory)
try TemporaryImageExports(directory: renamedDirectory, legacyDirectory: redirectedLegacyDirectory).cleanup()
try check(manager.fileExists(atPath: redirectedLegacyFile.path), "A linked legacy cache must not be traversed")
print("PASS: temporary image export reuse, expiry, shared legacy capacity, permissions and path isolation")

let namedDirectory = sandbox.appendingPathComponent("Named")
let namedCache = TemporaryImageExports(directory: namedDirectory, maximumBytes: 8)
let a = try namedCache.file(data: Data([1, 2, 3]), id: 1, fileExtension: "txt", basename: "План")
let b = try namedCache.file(data: Data([4, 5, 6]), id: 2, fileExtension: "txt", basename: "План")
try check(a.lastPathComponent == "План.txt" && b.lastPathComponent == "План.txt" && a != b,
          "Identical names from different records must keep independent paths")
try check(try Data(contentsOf: a) == Data([1, 2, 3]), "A second record must not overwrite the first")
try check((try manager.attributesOfItem(atPath: a.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700,
          "Named export folders must be private")
try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: a.path)
try namedCache.cleanup()
try check(!manager.fileExists(atPath: a.deletingLastPathComponent().path), "Expired named exports and empty folders must be removed")
try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: b.path)
let c = try namedCache.file(data: Data([1, 2, 3, 4, 5, 6]), id: 3, fileExtension: "md", basename: "New")
try check(!manager.fileExists(atPath: b.path) && manager.fileExists(atPath: c.path), "Named exports must participate in cache size eviction")
let changed = try namedCache.file(data: Data([1]), id: 3, fileExtension: "md", basename: "Changed")
try check(manager.fileExists(atPath: c.path) && changed != c, "Changing naming mode must not rename an existing clipboard file")
for invalid in ["../escape", ".", "..", "bad/name", "bad:name", "", String(repeating: "x", count: 181)] {
    do {
        _ = try namedCache.file(data: Data([1]), id: 4, fileExtension: "txt", basename: invalid)
        fatalError("Invalid basename was accepted")
    } catch let error as CocoaError {
        try check(error.code == .fileWriteInvalidFileName, "Invalid basename must fail before writing")
    }
}
let namedLink = namedDirectory.appendingPathComponent("Text-5")
try manager.createSymbolicLink(at: namedLink, withDestinationURL: sandbox)
do {
    _ = try namedCache.file(data: Data([1]), id: 5, fileExtension: "txt", basename: "outside")
    fatalError("Linked named export folder was accepted")
} catch let error as CocoaError {
    try check(error.code == .fileWriteNoPermission, "Named export must reject a linked folder")
}
try namedCache.cleanup()
try check(try Data(contentsOf: outside) == Data([10]), "Named cleanup must never traverse a linked folder")
print("PASS: named export collision isolation, expiry, size eviction, permissions and path validation")
