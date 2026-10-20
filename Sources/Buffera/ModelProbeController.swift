import Foundation
import BufferaModels
import Darwin

/// A short-lived native process owns model/GPU memory. It never receives clipboard data.
final class ModelProbeController {
    var onChange: ((ModelRole, String, Bool) -> Void)?

    private final class Run {
        let id = UUID()
        let process = Process()
        let output = Pipe()
        let diagnostics: URL
        var timeout: DispatchWorkItem?

        init() {
            diagnostics = FileManager.default.temporaryDirectory
                .appendingPathComponent("buffera-model-check-\(id.uuidString).log")
        }
    }

    private struct Result: Decodable {
        let success: Bool
        let summary: String
    }

    private let queue = DispatchQueue(label: "app.buffera.model-check")
    private var runs: [ModelRole: Run] = [:]
    private let executable: URL

    init(bundleURL: URL = Bundle.main.bundleURL) {
        executable = bundleURL.appendingPathComponent("Contents/MacOS/BufferaModelProbe")
    }

    func check(_ role: ModelRole, modelURL: URL) {
        queue.async { [self] in
            cancelOnQueue(role, message: nil)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                publish(role, "Движок недоступен. Пересоберите или обновите Buffera.", running: false)
                return
            }
            let run = Run()
            run.process.executableURL = executable
            run.process.arguments = [role == .embedding ? "embedding" : "chat", modelURL.path]
            run.process.standardInput = FileHandle.nullDevice
            run.process.standardOutput = run.output
            do {
                guard FileManager.default.createFile(atPath: run.diagnostics.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let log = try FileHandle(forWritingTo: run.diagnostics)
                run.process.standardError = log
                try run.process.run()
                try? log.close()
            } catch {
                try? FileManager.default.removeItem(at: run.diagnostics)
                publish(role, "Не удалось запустить проверку: \(error.localizedDescription)", running: false)
                return
            }
            runs[role] = run
            publish(role, "Проверяем русский, английский и код…", running: true)
            let timeout = DispatchWorkItem { [weak self, weak run] in
                guard let self, let run, self.runs[role]?.id == run.id else { return }
                self.cancelOnQueue(role, message: "Проверка заняла больше трёх минут. Модель выгружена.")
            }
            run.timeout = timeout
            queue.asyncAfter(deadline: .now() + 180, execute: timeout)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // The helper emits a bounded JSON object. Drain concurrently with its execution.
                let output = run.output.fileHandleForReading.readDataToEndOfFile()
                run.process.waitUntilExit()
                let diagnostic = Self.failureDetail(at: run.diagnostics)
                try? FileManager.default.removeItem(at: run.diagnostics)
                self?.queue.async { [weak self] in
                    guard let self, self.runs[role]?.id == run.id else { return }
                    self.runs[role] = nil
                    run.timeout?.cancel()
                    if run.process.terminationStatus == 0, output.count <= 128_000,
                       let result = try? JSONDecoder().decode(Result.self, from: output), result.success {
                        self.publish(role, "\(result.summary) Память освобождена.", running: false)
                    } else {
                        let result = output.count <= 128_000
                            ? try? JSONDecoder().decode(Result.self, from: output) : nil
                        let detail = result?.summary ?? diagnostic ?? "Движок завершился с ошибкой."
                        self.publish(role, "Проверка не пройдена: \(detail)", running: false)
                    }
                }
            }
        }
    }

    func cancel(_ role: ModelRole) {
        queue.async { [self] in
            cancelOnQueue(role, message: "Проверка остановлена. Модель выгружена.")
        }
    }

    func shutdown() {
        queue.sync {
            for run in runs.values {
                run.timeout?.cancel()
                if run.process.isRunning { Darwin.kill(run.process.processIdentifier, SIGKILL) }
            }
            runs.removeAll()
        }
    }

    private func cancelOnQueue(_ role: ModelRole, message: String?) {
        guard let run = runs.removeValue(forKey: role) else { return }
        run.timeout?.cancel()
        // A probe has no persistent writes to finish; kill gives cancellation a firm memory boundary.
        if run.process.isRunning { Darwin.kill(run.process.processIdentifier, SIGKILL) }
        if let message { publish(role, message, running: false) }
    }

    private func publish(_ role: ModelRole, _ status: String, running: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(role, status, running) }
    }

    private static func failureDetail(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2048 ? size - 2048 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map { String($0.prefix(240)) }
    }
}
