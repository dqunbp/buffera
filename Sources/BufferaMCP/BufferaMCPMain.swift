import Foundation
import BufferaMCPKit
import Darwin

@main
struct BufferaMCPMain {
    static func main() async {
        // A client disappearing during a response must not leave a subprocess behind.
        signal(SIGPIPE, SIG_IGN)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                diagnostic("""
                BufferaMCP — локальный MCP через stdio.
                Использование: BufferaMCP [--data-directory /absolute/path]
                По умолчанию: ~/Library/Application Support/Buffera.
                Доступ включается в Buffera → Настройки → Агенты.
                """)
                return
            }
            if arguments.isEmpty {
                try await BufferaMCPServer.run()
            } else if arguments.count == 2, arguments[0] == "--data-directory",
                      arguments[1].hasPrefix("/") {
                try await BufferaMCPServer.run(directory: URL(fileURLWithPath: arguments[1], isDirectory: true))
            } else {
                diagnostic("Неверные параметры. Используйте --help.")
                exit(2)
            }
        } catch {
            diagnostic("Buffera MCP: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func diagnostic(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
