import Foundation

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "TemporaryImageExportsChecks", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: message]) }
}

let manager = FileManager.default
let sandbox = manager.temporaryDirectory.appendingPathComponent("BuferaExportChecks-\(UUID().uuidString)", isDirectory: true)
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
let linked = directory.appendingPathComponent("Bufera-3.png")
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
print("PASS: temporary image export reuse, expiry, capacity, permissions and path isolation")
