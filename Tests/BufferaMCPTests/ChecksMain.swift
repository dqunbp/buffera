import Foundation
import Darwin

private var assertionCount = 0
private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func checkFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
    throw CheckFailure(description: "\(file):\(line): \(message)")
}
func checkEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    guard try lhs() == rhs() else { return try checkFail("Values differ. \(message)", file: file, line: line) }
    assertionCount += 1
}
func checkTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "",
               file: StaticString = #filePath, line: UInt = #line) throws {
    guard try value() else { return try checkFail("Expected true. \(message)", file: file, line: line) }
    assertionCount += 1
}
func checkFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "",
                file: StaticString = #filePath, line: UInt = #line) throws {
    try checkTrue(!value(), message, file: file, line: line)
}
func checkNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "",
                 file: StaticString = #filePath, line: UInt = #line) throws {
    try checkTrue(value() == nil, message, file: file, line: line)
}
func checkNotNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) throws {
    try checkTrue(value() != nil, message, file: file, line: line)
}

@main
struct ChecksMain {
    static func main() async {
        setbuf(stdout, nil)
        signal(SIGPIPE, SIG_IGN)
        do {
            try await runHistoryReaderChecks()
            try await runSerializedTransportChecks()
            try await runStdioProcessChecks()
            try await runToolArgumentChecks()
            try await runRawJSONChecks()
            print("PASS: \(assertionCount) MCP assertions")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
