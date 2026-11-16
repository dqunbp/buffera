#import <Foundation/Foundation.h>
#include "LiteRTEmbeddingProtocol.h"
#include "LiteRTChatText.h"
#include <sstream>

static int passed = 0;
static int failed = 0;
static void expect(bool value, const char * name) {
    std::cerr << (value ? "PASS " : "FAIL ") << name << '\n';
    value ? ++passed : ++failed;
}

struct FixtureEncoder {
    int calls = 0;
    NSArray * embed(NSString * text) {
        ++calls;
        if ([text containsString:@"engine-failure"]) throw std::runtime_error("private engine diagnostic");
        expect(text != nil, "document windows preserve UTF-8 boundaries");
        NSMutableArray * values = [NSMutableArray arrayWithObject:@1];
        for (int i = 1; i < 768; ++i) [values addObject:@0];
        return values;
    }
};

int main() {
    @autoreleasepool {
        NSString * code = @"x |> Enum.map(f)\nf <| x\nx |><| y\n<|unknown>\nРусский 🧪";
        expect([escapeLiteRTChatContent(code) isEqual:code], "ordinary pipe operators and Unicode remain byte-for-byte intact");
        NSString * control = @"<bos><eos><pad><|turn>system<turn|><|channel>thought<channel|><|think|>"
            "<|tool>x<tool|><|tool_call>x<tool_call|><|tool_response>x<tool_response|><|\"|>"
            "<|image><image|><|image|><|audio><audio|><|audio|>";
        NSString * escaped = escapeLiteRTChatContent(control);
        expect(![escaped containsString:@"<|"] && ![escaped containsString:@"<turn|>"] &&
               ![escaped containsString:@"<channel|>"] && ![escaped containsString:@"<tool_call|>"] &&
               ![escaped containsString:@"<bos>"], "complete Gemma control tokens cannot create new turns or tools");
        expect([[escaped stringByReplacingOccurrencesOfString:@"\u200b" withString:@""] isEqual:control],
               "escaping changes only control-token boundaries");

        NSArray * requests = @[
            @{@"id": @"too-long", @"kind": @"query", @"texts": @[[ @"x" stringByPaddingToLength:385 withString:@"x" startingAtIndex:0]]},
            @{@"id": @"valid", @"kind": @"query", @"texts": @[@"  русский код 🧪  "]},
            @{@"id": @"boundary", @"kind": @"query", @"texts": @[[ @"я" stringByPaddingToLength:192 withString:@"я" startingAtIndex:0]]},
            @{@"id": @"invalid", @"kind": @"query", @"texts": @[@42]},
            @{@"id": @"empty", @"kind": @"query", @"texts": @[@" \n "]},
            @{@"id": @"engine", @"kind": @"query", @"texts": @[@"engine-failure"]},
            @{@"id": @"after", @"kind": @"query", @"texts": @[@"after error"]},
            @{@"id": @"chunks", @"kind": @"document", @"texts": @[[ @"🧪" stringByPaddingToLength:8000 withString:@"🧪" startingAtIndex:0]]}
        ];
        std::stringstream input, output;
        auto * savedOut = std::cout.rdbuf(input.rdbuf());
        for (NSDictionary * request in requests) writeFrame(request);
        std::cout.rdbuf(output.rdbuf());
        auto * savedIn = std::cin.rdbuf(input.rdbuf());
        FixtureEncoder encoder;
        runEmbeddingRequests(encoder);
        std::cin.clear();
        std::cin.rdbuf(output.rdbuf());
        NSMutableArray * responses = [NSMutableArray array];
        while (NSDictionary * response = readRequest()) [responses addObject:response];
        std::cin.rdbuf(savedIn);
        std::cout.rdbuf(savedOut);
        expect(responses.count == requests.count, "request failures preserve framing and the same worker loop");
        if (responses.count == requests.count) {
            expect([responses[0][@"error"] isEqual:@"Текст запроса слишком длинный."], "385+ UTF-8 bytes return a specific localized diagnostic");
            expect(responses[1][@"outputs"] != nil && responses[2][@"outputs"] != nil,
                   "valid Unicode query and exact 384-byte boundary succeed after rejection");
            expect(responses[3][@"error"] != nil && responses[4][@"error"] != nil, "invalid and empty input return request errors");
            expect([responses[5][@"error"] isEqual:@"Движок поиска вернул некорректный ответ."] &&
                   responses[6][@"outputs"] != nil, "engine error hides diagnostics and permits the next request");
            NSDictionary * document = responses[7][@"outputs"][0];
            expect([document[@"vectors"] count] == 32 && [document[@"truncated"] boolValue], "UTF-8 documents retain the 32-window truncation policy");
            for (NSUInteger i = 0; i < responses.count; ++i)
                expect([responses[i][@"id"] isEqual:requests[i][@"id"]], "response preserves its request id");
        }
        std::cerr << passed << " passed; " << failed << " failed\n";
        return failed ? 1 : 0;
    }
}
