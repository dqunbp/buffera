#pragma once
#import <Foundation/Foundation.h>

// Gemma 4 tokenizer control tokens, not ordinary <| / |> operators.
// https://ai.google.dev/gemma/docs/core/prompt-formatting-gemma4
static NSString * escapeLiteRTChatContent(NSString * content) {
    for (NSString * token in @[@"<bos>", @"<eos>", @"<pad>", @"<|turn>", @"<turn|>",
                              @"<|channel>", @"<channel|>", @"<|think|>",
                              @"<|tool>", @"<tool|>", @"<|tool_call>", @"<tool_call|>",
                              @"<|tool_response>", @"<tool_response|>", @"<|\"|>",
                              @"<|image>", @"<image|>", @"<|image|>",
                              @"<|audio>", @"<audio|>", @"<|audio|>"]) {
        content = [content stringByReplacingOccurrencesOfString:token
            withString:[@"<\u200b" stringByAppendingString:[token substringFromIndex:1]]];
    }
    return content;
}
