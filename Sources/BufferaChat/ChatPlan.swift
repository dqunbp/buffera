import Foundation
import CoreFoundation
import BufferaCore

enum ChatPlanError: Error { case invalid }

enum ChatPlan {
    case search(SearchFilter, limit: Int, offset: Int)
    case read(Int64, offset: Int, limit: Int)
    case neighbors(Int64, before: Int, after: Int)
    case finish

    static func parse(_ text: String) throws -> ChatPlan {
        guard text.utf8.count <= 8192,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys).isSubset(of: ["tool", "arguments"]),
              let tool = object["tool"] as? String,
              let arguments = object["arguments"] as? [String: Any] else { throw ChatPlanError.invalid }
        func keys(_ allowed: Set<String>) throws {
            guard Set(arguments.keys).isSubset(of: allowed) else { throw ChatPlanError.invalid }
        }
        func string(_ key: String, maximum: Int, fallback: String? = nil) throws -> String? {
            guard let raw = arguments[key] else { return fallback }
            guard let value = raw as? String, value.count <= maximum, !value.contains("\0") else {
                throw ChatPlanError.invalid
            }
            return value
        }
        func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = arguments[key] else { return fallback }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(range.lowerBound),
                  number.doubleValue <= Double(range.upperBound) else { throw ChatPlanError.invalid }
            return number.intValue
        }
        func boolean(_ key: String) throws -> Bool {
            guard let raw = arguments[key] else { return false }
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ChatPlanError.invalid
            }
            return number.boolValue
        }
        func id() throws -> Int64 {
            guard let text = try string("id", maximum: 19), text.allSatisfy(\.isNumber),
                  let id = Int64(text), id > 0 else { throw ChatPlanError.invalid }
            return id
        }
        func date(_ key: String) throws -> Date? {
            guard let text = try string(key, maximum: 64) else { return nil }
            let formatter = ISO8601DateFormatter()
            if let result = formatter.date(from: text) { return result }
            formatter.formatOptions.insert(.withFractionalSeconds)
            guard let result = formatter.date(from: text) else { throw ChatPlanError.invalid }
            return result
        }
        switch tool {
        case "search_history":
            try keys(["query", "kind", "source", "favorites_only", "remote_only", "from", "until", "limit", "offset"])
            var filter = SearchFilter()
            filter.query = try string("query", maximum: 1000, fallback: "")!
            if let raw = try string("kind", maximum: 16) {
                guard let kind = ClipKind(rawValue: raw) else { throw ChatPlanError.invalid }
                filter.kind = kind
            }
            filter.source = try string("source", maximum: 128)
            filter.favoritesOnly = try boolean("favorites_only")
            filter.remoteOnly = try boolean("remote_only")
            filter.from = try date("from")
            filter.until = try date("until")
            if let from = filter.from, let until = filter.until, from >= until { throw ChatPlanError.invalid }
            filter.excludesConcealed = true
            return .search(filter, limit: try integer("limit", fallback: 6, range: 1...8),
                           offset: try integer("offset", fallback: 0, range: 0...100_000))
        case "read_clip":
            try keys(["id", "offset", "limit"])
            return .read(try id(), offset: try integer("offset", fallback: 0, range: 0...1_000_000),
                         limit: try integer("limit", fallback: 4000, range: 1...8000))
        case "get_neighbors":
            try keys(["id", "before", "after"])
            return .neighbors(try id(), before: try integer("before", fallback: 2, range: 0...3),
                              after: try integer("after", fallback: 2, range: 0...3))
        case "finish":
            try keys([])
            return .finish
        default: throw ChatPlanError.invalid
        }
    }
}
