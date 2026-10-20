import Foundation
import MCP
import BufferaCore

func runToolArgumentChecks() async throws {
    let fixture = try ProcessFixture()
    defer { fixture.cleanup() }
    try fixture.access.setEnabled(true)
    try await fixture.withConnection { connection in
        let invalid: [(String, [String: Value])] = [
            ("search_history", ["include_hidden": true]),
            ("read_clip", ["id": 12]),
            ("read_clip", ["id": "9223372036854775808"]),
            ("read_clip", ["id": "01"]),
            ("read_clip", ["id": "-1"]),
            ("search_history", ["limit": true]),
            ("search_history", ["limit": 51]),
            ("search_history", ["favorites_only": "true"]),
            ("search_history", ["query": "a\0b"]),
            ("search_history", ["from": "yesterday"]),
            ("search_history", ["from": "2026-10-19"]),
            ("search_history", ["from": "2026-10-20T00:00:00Zgarbage"]),
            ("search_history", ["from": "2026-10-20T00:00:00Z\n"]),
            ("search_history", ["from": "2026-02-29T00:00:00Z"]),
            ("search_history", ["from": "2026-04-31T00:00:00Z"]),
            ("search_history", ["from": "2026-10-20T24:00:00Z"]),
            ("search_history", ["from": "2026-10-20T00:60:00Z"]),
            ("search_history", ["from": "2026-10-20T00:00:60Z"]),
            ("search_history", ["from": "2026-10-20T00:00:00+24:00"]),
            ("search_history", ["from": "2026-10-20T00:00:00+04:60"]),
            ("search_history", ["kind": "password"]),
            ("search_history", ["from": "2026-10-20T00:00:00Z", "until": "2026-10-19T00:00:00Z"]),
            ("delete_clip", ["id": "1"])
        ]
        for (name, arguments) in invalid {
            do {
                _ = try await connection.call(name, arguments)
                try checkFail("Invalid arguments were accepted: \(name)")
            } catch let error as MCPError {
                guard case .invalidParams = error else { return try checkFail("Unexpected error: \(error)") }
            }
        }
        let filtered = try await connection.call("search_history", [
            "query": "Ошибка connection", "kind": "image", "favorites_only": true,
            "from": "2026-10-19T00:00:00+04:00", "until": "2026-10-20T00:00:00.000+04:00"
        ])
        try checkEqual(filtered.isError, false)
        for date in ["2024-02-29T12:34:56Z", "2026-10-20T12:34:56.123456789+04:00",
                     "2026-10-20T12:34:56-03:30", "2026-10-20t12:34:56z",
                     "2026-10-20T12:34:56+0400"] {
            let result = try await connection.call("search_history", ["from": .string(date)])
            try checkEqual(result.isError, false)
        }
        let maximumID = try await connection.call("read_clip", ["id": "9223372036854775807"])
        try checkEqual(maximumID.isError, true, "Valid Int64 ID reaches the missing-record path")
        let (tools, _) = try await connection.client.listTools()
        for tool in tools {
            try checkEqual(tool.annotations.readOnlyHint, true)
            try checkEqual(tool.annotations.openWorldHint, false)
            try checkEqual(tool.inputSchema.objectValue?["additionalProperties"], false)
        }
        let text = "data:text/plain;charset=utf-8;base64,SGVsbG8="
        let id = try fixture.store.insert(
            payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]]),
            kind: .text, title: "data URL", text: text, source: "MCP Test")
        let result = try await connection.call("read_clip", ["id": .string(String(id))])
        guard case .text(let json, _, _) = result.content.first else { return try checkFail("Missing JSON text") }
        let content = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        try checkEqual(content?["text"] as? String, text)
        print("PASS MCP argument validation and exact clipboard strings")
    }
}
