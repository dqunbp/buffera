// Standalone checks for the internal verification boundary; no test-only production API.
// swiftc -module-cache-path .build/ModuleCache Sources/BufferaModels/LocalModel.swift Sources/BufferaModels/ModelStorage.swift Tests/ModelStorageChecks/main.swift -o .build/model-storage-checks
// .build/model-storage-checks
import CryptoKit
import Darwin
import Foundation

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    do {
        if try condition() { passed += 1; print("PASS \(name)") }
        else { failed += 1; print("FAIL \(name)") }
    } catch { failed += 1; print("FAIL \(name): \(error)") }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-verification-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("fixture.gguf")
let payload = Data(repeating: 0x3a, count: 3 * 1024 * 1024)
let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
let descriptor = LocalModelDescriptor(role: .embedding, title: "Fixture", summary: "Fixture", repository: "fixture",
    revision: String(repeating: "a", count: 40), filename: "fixture.gguf", byteCount: Int64(payload.count),
    sha256: hash, sourceURL: URL(string: "http://127.0.0.1/fixture")!, licenseURL: URL(string: "https://example.com")!)
try payload.write(to: file)
check(try ModelStorage.verify(file, descriptor: descriptor, token: ModelVerification()) == .hashed,
      "first verification hashes the complete file")
check(try ModelStorage.verify(file, descriptor: descriptor, token: ModelVerification()) == .reused,
      "unchanged file reuses successful in-process verification")

let cancelled = ModelVerification()
cancelled.cancel()
do {
    try ModelStorage.verify(file, descriptor: descriptor, token: cancelled)
    check(false, "cancelled cache hit must fail")
} catch is CancellationError { check(true, "cancelled cache hit is rejected before reuse") }

let wrongDescriptor = LocalModelDescriptor(role: .embedding, title: "Fixture", summary: "Fixture", repository: "fixture",
    revision: descriptor.revision, filename: descriptor.filename, byteCount: descriptor.byteCount,
    sha256: String(repeating: "0", count: 64), sourceURL: descriptor.sourceURL, licenseURL: descriptor.licenseURL)
do {
    try ModelStorage.verify(file, descriptor: wrongDescriptor, token: ModelVerification())
    check(false, "different checksum cannot reuse cached success")
} catch ModelStorageError.checksum { check(true, "cache remains bound to expected descriptor checksum") }

// Preserve inode, size and mtime; ctime must still invalidate the previous successful hash.
var original = stat()
check(Darwin.lstat(file.path, &original) == 0, "capture original file timestamps")
let writer = try FileHandle(forWritingTo: file)
try writer.seek(toOffset: UInt64(payload.count / 2))
try writer.write(contentsOf: Data([0x3b]))
try writer.close()
var times = [original.st_atimespec, original.st_mtimespec]
check(times.withUnsafeBufferPointer { Darwin.utimensat(AT_FDCWD, file.path, $0.baseAddress, 0) } == 0,
      "restore mtime after same-size in-place mutation")
do {
    try ModelStorage.verify(file, descriptor: descriptor, token: ModelVerification())
    check(false, "in-place mutation cannot reuse cached success")
} catch ModelStorageError.checksum { check(true, "ctime detects mutation even when mtime is restored") }

try payload.write(to: file, options: .atomic)
check(try ModelStorage.verify(file, descriptor: descriptor, token: ModelVerification()) == .hashed,
      "atomic replacement with valid bytes requires a fresh hash")
check(try ModelStorage.verify(file, descriptor: descriptor, token: ModelVerification()) == .reused,
      "verified replacement can be reused")
var invalid = payload
invalid[0] ^= 0xff
try invalid.write(to: file, options: .atomic)
do {
    try ModelStorage.verify(file, descriptor: descriptor, token: ModelVerification())
    check(false, "corrupt replacement cannot reuse cached success")
} catch ModelStorageError.checksum { check(true, "atomic replacement with corrupt bytes is rejected") }

let source = directory.appendingPathComponent("source.gguf")
try payload.write(to: source)
try FileManager.default.removeItem(at: file)
try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
do {
    try ModelStorage.verify(file, descriptor: descriptor, token: ModelVerification())
    check(false, "symlink must not be accepted as model file")
} catch { check(true, "symlink replacement is rejected before verification") }

print("Model storage checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
