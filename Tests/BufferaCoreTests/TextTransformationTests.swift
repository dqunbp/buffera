import Foundation
import BufferaCore

extension HistoryStoreTests {
    func testPlainTextPreservesCompleteContentAndTransformByteLimit() throws {
        let full = String(repeating: "исходный текст\n", count: 30_000) + "last character"
        try check(full.count > 200_000)
        try checkEqual(try TextTransformation.plainText.apply(to: full), full)
        let oversized = String(repeating: "я", count: 1_048_577)
        try checkEqual(try TextTransformation.plainText.apply(to: oversized), oversized)
        for operation in TextTransformation.allCases where operation != .plainText {
            do {
                _ = try operation.apply(to: oversized)
                throw CheckFailure(description: "Expected a UTF-8 size limit for \(operation)")
            } catch TextTransformationError.tooLarge { }
        }
        try checkThrows(try TextTransformation.plainText.apply(to: ""))
    }

    func testJSONFormattingPreservesNumbersKeysAndStringLexemes() throws {
        let input = #"{"n":9007199254740993,"n":1e400,"precision":0.123456789012345678901234567890,"minus":-0,"escaped":"quote: \" slash: \/ literal: \u0041","v":[true,false,null,{},[]]}"#
        let expected = #"""
        {
          "n": 9007199254740993,
          "n": 1e400,
          "precision": 0.123456789012345678901234567890,
          "minus": -0,
          "escaped": "quote: \" slash: \/ literal: \u0041",
          "v": [
            true,
            false,
            null,
            {},
            []
          ]
        }
        """#
        let result = try TextTransformation.formatJSON.apply(to: input)
        try checkEqual(result, expected)
        try checkEqual(try TextTransformation.formatJSON.apply(to: result), result)
        for scalar in ["1E+400", "-0.00e-9999", #""строка 😀""#, "true", "null"] {
            try checkEqual(try TextTransformation.formatJSON.apply(to: " \r\n\t" + scalar + " \n"), scalar)
        }
    }

    func testJSONRejectsInvalidSyntaxAndBoundsDepthAndOutput() throws {
        let malformed = [" ", "00", "-01", "1.", "1e", "1e+", "+1", ".1", "truefalse", "[1,]",
                         "{\"a\":1,}", "{a:1}", "[}", "[] {}", "\"raw\nline\"", #""\x20""#, #""\u123""#, #""unfinished\"#]
        for input in malformed {
            do {
                _ = try TextTransformation.formatJSON.apply(to: input)
                throw CheckFailure(description: "Invalid JSON accepted: \(input)")
            } catch TextTransformationError.invalidJSON { }
        }
        let deepest = String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)
        try check(!TextTransformation.formatJSON.apply(to: deepest).isEmpty)
        do {
            _ = try TextTransformation.formatJSON.apply(to: "[" + deepest + "]")
            throw CheckFailure(description: "Expected JSON depth limit")
        } catch TextTransformationError.jsonTooDeep { }
        let expanded = "[" + String(repeating: "[0],", count: 160_000) + "0]"
        do {
            _ = try TextTransformation.formatJSON.apply(to: expanded)
            throw CheckFailure(description: "Expected formatted output limit")
        } catch TextTransformationError.tooLarge { }
    }

    func testUnwrapPreservesParagraphsAndNormalizesLineEndings() throws {
        let input = "\r\n  первая строка \r\n вторая строка\r\n\r\n\r\nтретий\rабзац\n \nпоследний\n"
        try checkEqual(try TextTransformation.unwrapLines.apply(to: input),
                       "\nпервая строка вторая строка\n\n\nтретий абзац\n \nпоследний\n")
        try checkEqual(try TextTransformation.unwrapLines.apply(to: "already one line"), "already one line")
        try checkEqual(try TextTransformation.unwrapLines.apply(to: "\n\n"), "\n\n")
    }

    func testDuplicateLinesUseExactContentAndPreserveBlankLines() throws {
        let input = "a\r\na\r\n\r\nA\na \na\n \n \n\né\ne\u{301}\né\n"
        try checkEqual(try TextTransformation.removeDuplicateLines.apply(to: input),
                       "a\n\nA\na \n \n \n\né\ne\u{301}\n")
        try checkEqual(try TextTransformation.removeDuplicateLines.apply(to: "\n\n"), "\n\n")
    }

    func testURLCleaningPreservesRawValuesOrderFragmentAndUntouchedNames() throws {
        let input = "HTTPS://Example.com:443/a%2fb?x=a+b&%75tm_source=test&x=%2F&fbclid=ad&&ref=source&token=abc%2b123#part?utm_campaign=kept"
        let expected = "HTTPS://Example.com:443/a%2fb?x=a+b&x=%2F&&ref=source&token=abc%2b123#part?utm_campaign=kept"
        try checkEqual(try TextTransformation.removeTrackingParameters.apply(to: input), expected)
        try checkEqual(try TextTransformation.removeTrackingParameters.apply(to: "https://e.test/?UTM_Campaign=one&gclid=two#h"), "https://e.test/#h")
        try checkEqual(try TextTransformation.removeTrackingParameters.apply(to: "https://e.test?utm_content=first&utm_content=second&a=1"), "https://e.test?a=1")
        let unmodified = "https://e.test/path?ref=project&source=docs&id=12&q=a+b&token=a%2fb#frag"
        try checkEqual(try TextTransformation.removeTrackingParameters.apply(to: unmodified), unmodified)
        try checkEqual(try TextTransformation.removeTrackingParameters.apply(to: "https://e.test/path?"), "https://e.test/path?")
    }

    func testURLCleaningRejectsInvalidOrModifiedSignedLinks() throws {
        for value in ["relative/path?utm_source=a", "ftp://e.test?utm_source=a", "https://", "https://e.test/a b",
                      "https://e.test/?q=%broken", "https://e.test/?q=%", "https://e.test\nhttps://other.test"] {
            do {
                _ = try TextTransformation.removeTrackingParameters.apply(to: value)
                throw CheckFailure(description: "Invalid URL accepted: \(value)")
            } catch TextTransformationError.invalidURL { }
        }
        for signature in ["X-Amz-Signature", "X-Goog-Signature", "sig", "%73ignature", "oauth_signature", "hmac"] {
            do {
                _ = try TextTransformation.removeTrackingParameters.apply(to: "https://e.test/?utm_source=ad&\(signature)=signed")
                throw CheckFailure(description: "Expected signed URL rejection")
            } catch TextTransformationError.signedURL { }
        }
        let unchanged = "https://e.test/?X-Amz-Signature=abc&ref=project"
        try checkEqual(try TextTransformation.removeTrackingParameters.apply(to: unchanged), unchanged)
    }
}
