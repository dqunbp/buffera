import BufferaModels
import Foundation

func runLiveDownload(arguments: [String]) throws -> Int32 {
    guard arguments.count == 4, let role = ModelRole(rawValue: arguments[2]),
          arguments[3].hasPrefix("/") else {
        print("Usage: BufferaModelChecks --download-live embedding|assistant /absolute/isolated/directory")
        return 2
    }
    let root = URL(fileURLWithPath: arguments[3], isDirectory: true)
    var manager = try LocalModelManager(rootURL: root)
    defer { manager.shutdown() }
    manager.download(role)
    var restarted = false
    var lastPrint = Date.distantPast
    let deadline = Date().addingTimeInterval(45 * 60)
    while Date() < deadline {
        guard let snapshot = manager.snapshots.first(where: { $0.descriptor.role == role }) else { return 2 }
        if Date().timeIntervalSince(lastPrint) >= 3 {
            print("\(role.rawValue): \(snapshot.state.rawValue) \(snapshot.receivedBytes)/\(snapshot.totalBytes)")
            fflush(stdout)
            lastPrint = Date()
        }
        if snapshot.state == .failed {
            print("FAIL: \(snapshot.errorMessage ?? "unknown")")
            return 1
        }
        if snapshot.state == .downloaded {
            print("PASS: pinned model downloaded and SHA256 verified")
            print("MODEL_PATH=\(manager.modelURL(for: role)!.path)")
            return 0
        }
        if !restarted && snapshot.state == .downloading && snapshot.receivedBytes >= 1024 * 1024 {
            manager.pause(role)
            manager.shutdown()
            let bytes = manager.snapshots.first(where: { $0.descriptor.role == role })!.receivedBytes
            manager = try LocalModelManager(rootURL: root)
            guard manager.snapshots.first(where: { $0.descriptor.role == role })?.receivedBytes == bytes else {
                print("FAIL: saved partial size changed across manager restart")
                return 1
            }
            print("RESTART: resuming retained \(bytes) bytes")
            fflush(stdout)
            manager.download(role)
            restarted = true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    print("FAIL: live download deadline exceeded")
    return 1
}
