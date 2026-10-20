import BufferaModels
import Foundation

/// All corpus text is synthetic. A temporary receipt enables an isolated copy of the
/// already-downloaded model; this never reads history or changes the user's settings.
func runLiveEmbeddingChecks(arguments: [String]) async throws -> Int32 {
    guard arguments.count == 4 else {
        print("Usage: BufferaEmbeddingRuntimeChecks --live /absolute/Buffera.app /absolute/model.gguf")
        return 2
    }
    let descriptor = LocalModelCatalog.models.first { $0.role == .embedding }!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("buffera-embedding-live-\(UUID())")
    let directory = root.appendingPathComponent("embedding").appendingPathComponent(descriptor.revision)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[3]),
                                    to: directory.appendingPathComponent(descriptor.filename))
    let receipt: [String: Any] = ["embedding": [
        "revision": descriptor.revision, "sha256": descriptor.sha256,
        "state": "downloaded", "enabled": true
    ]]
    try JSONSerialization.data(withJSONObject: receipt)
        .write(to: root.appendingPathComponent("state.json"), options: .atomic)
    let worker = EmbeddingRuntime(modelRootURL: root, bundleURL: URL(fileURLWithPath: arguments[2]))
    defer { worker.shutdown() }
    let documents = [
        #"raise ConnectionError("connection refused to PostgreSQL database")"#,
        "Не удалось подключиться к базе данных PostgreSQL: сервер отказал в соединении.",
        "Как приготовить пасту: вскипятите воду, посолите и варите макароны восемь минут.",
        "Cook pasta in boiling salted water for eight minutes, then add tomato sauce.",
        "Встреча с командой в четверг в 15:00. Обсудим бюджет проекта.",
        "Team meeting on Thursday at 3 PM to review the project budget.",
        "if response.status == 401: token = refresh_access_token(refresh_token)",
        "When the access token expires, use the refresh token to obtain a new access token.",
        "Чтобы включить тёмную тему, откройте настройки приложения и выберите оформление.",
        "Open app preferences and select dark appearance to enable the night theme.",
        "const document = JSON.parse(responseText);",
        "let document = try JSONDecoder().decode(Document.self, from: jsonData)",
        "The weather is sunny and a dog is playing in the park.",
        "Wi-Fi network name: OfficeGuest. Open VPN settings to import the profile.",
        "git rebase --continue: resolve merge conflicts before continuing the rebase"
    ]
    let queries: [(String, Set<Int>)] = [
        ("ошибка подключения к базе", [0, 1]),
        ("как сварить пасту", [2, 3]),
        ("встреча в четверг по бюджету", [4, 5]),
        ("refresh expired access token", [6, 7]),
        ("тёмная тема в настройках", [8, 9]),
        ("Swift decode JSON", [10, 11])
    ]
    var vectors: [[Float]] = []
    for start in stride(from: 0, to: documents.count, by: 4) {
        let results = try await worker.embed(Array(documents[start..<min(start + 4, documents.count)]),
                                             kind: .document)
        vectors.append(contentsOf: results.map { $0.vectors[0] })
    }
    var failed = 0
    var minimumPositive = Double.infinity
    var maximumNegative = -Double.infinity
    var falsePositivesAt65 = 0
    var falsePositivesAt70 = 0
    func cosine(_ left: [Float], _ right: [Float]) -> Double {
        zip(left, right).reduce(0) { $0 + Double($1.0) * Double($1.1) }
    }
    for (index, query) in queries.enumerated() {
        let result = try await worker.embed([query.0], kind: .query)[0].vectors[0]
        let scores = vectors.map { cosine(result, $0) }
        let ranked = scores.indices.sorted { scores[$0] > scores[$1] }
        if !query.1.contains(ranked[0]) { failed += 1 }
        let positives = scores.indices.filter { query.1.contains($0) }.map { scores[$0] }
        let negatives = scores.indices.filter { !query.1.contains($0) }.map { scores[$0] }
        minimumPositive = min(minimumPositive, positives.min()!)
        maximumNegative = max(maximumNegative, negatives.max()!)
        falsePositivesAt65 += negatives.filter { $0 >= 0.65 }.count
        falsePositivesAt70 += negatives.filter { $0 >= 0.70 }.count
        print(String(format: "QUERY %d: top=%d positive=%.4f...%.4f max_negative=%.4f",
                     index, ranked[0], positives.min()!, positives.max()!, negatives.max()!))
    }
    let repeated = try await worker.embed([queries[0].0, queries[0].0], kind: .query)
    if repeated[0].vectors != repeated[1].vectors { failed += 1 }
    let long = try await worker.embed([String(repeating: "banana apples oranges ", count: 5500)], kind: .document)[0]
    if long.vectors.count != 32 || !long.truncated { failed += 1 }
    let chunked = try await worker.embed([String(repeating: "ordinary filler ", count: 500) +
        " Could not connect to the PostgreSQL database: connection refused."], kind: .document)[0]
    if chunked.vectors.count < 2 || chunked.truncated { failed += 1 }
    let query = repeated[0].vectors[0]
    let chunkScores = chunked.vectors.map { cosine(query, $0) }
    if chunkScores.last! <= chunkScores.first! { failed += 1 }
    do {
        _ = try await worker.embed([String(repeating: "banana ", count: 1000)], kind: .query)
        failed += 1
    } catch {}
    worker.unload()
    if worker.isRunning { failed += 1 }
    print(String(format: "CALIBRATION positive_min=%.4f negative_max=%.4f false_positive_at_065=%d at_070=%d",
                 minimumPositive, maximumNegative, falsePositivesAt65, falsePositivesAt70))
    print("PASS checks: real model, RU/EN/code top results, repeatability, late chunks, truncation, long query, unload")
    print("\(failed) live failures")
    return failed == 0 ? 0 : 1
}
