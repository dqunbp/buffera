// Native LiteRT-LM adapter for Buffera's bounded, private chat pipe protocol.
#import <Foundation/Foundation.h>
#include "conversation.h"
#include "LiteRTChatText.h"
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>

static bool probeMode = false;
static bool probeOK = true;
static constexpr uint32_t maximumFrame = 1024 * 1024;

static NSData * readFrame() {
    unsigned char header[4];
    std::cin.read(reinterpret_cast<char *>(header), 4);
    if (std::cin.gcount() == 0 && std::cin.eof()) return nil;
    if (std::cin.gcount() != 4) throw std::runtime_error("Некорректный запрос к помощнику.");
    const uint32_t size = (uint32_t(header[0]) << 24) | (uint32_t(header[1]) << 16) |
                          (uint32_t(header[2]) << 8) | uint32_t(header[3]);
    if (!size || size > maximumFrame) throw std::runtime_error("Некорректный размер запроса.");
    NSMutableData * data = [NSMutableData dataWithLength:size];
    std::cin.read(static_cast<char *>(data.mutableBytes), size);
    if (std::cin.gcount() != size) throw std::runtime_error("Незавершённый запрос к помощнику.");
    return data;
}

static void writeFrame(NSDictionary * value) {
    if (probeMode) {
        if ([value[@"event"] isEqual:@"error"]) probeOK = false;
        return;
    }
    NSData * data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data || data.length > maximumFrame) throw std::runtime_error("Не удалось передать ответ.");
    uint32_t size = uint32_t(data.length);
    unsigned char header[] = {static_cast<unsigned char>(size >> 24), static_cast<unsigned char>(size >> 16),
                              static_cast<unsigned char>(size >> 8), static_cast<unsigned char>(size)};
    std::cout.write(reinterpret_cast<char *>(header), 4);
    std::cout.write(static_cast<const char *>(data.bytes), size);
    std::cout.flush();
    if (!std::cout) throw std::runtime_error("Клиент помощника отключён.");
}

static void check(LiteRtLmStatusCode status) {
    // Never include runtime diagnostics containing user prompts in a wire error.
    if (status != kLiteRtLmStatusOk) throw std::runtime_error("LiteRT-LM inference failed");
}
template<class T, void (*Destroy)(T*)>
using Owned = std::unique_ptr<T, decltype(Destroy)>;
static std::string json(id value) {
    NSData * data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    if (!data) throw std::runtime_error("Invalid JSON");
    return std::string(static_cast<const char *>(data.bytes), data.length);
}

class Generator {
    Owned<LiteRtLmEngine, litert_lm_engine_delete> engine{nullptr, litert_lm_engine_delete};
    size_t tokens(const char * text) {
        LiteRtLmTokenizeResult * raw = nullptr;
        check(litert_lm_engine_tokenize(engine.get(), text, &raw));
        Owned<LiteRtLmTokenizeResult, litert_lm_tokenize_result_delete> result(raw, litert_lm_tokenize_result_delete);
        size_t count = 0;
        check(litert_lm_tokenize_result_get_num_tokens(result.get(), &count));
        return count;
    }
public:
    Generator(const char * path, const char * cache) {
        LiteRtLmEngineSettings * raw = nullptr;
        check(litert_lm_engine_settings_create(path, "gpu", nullptr, nullptr, &raw));
        Owned<LiteRtLmEngineSettings, litert_lm_engine_settings_delete> settings(raw, litert_lm_engine_settings_delete);
        check(litert_lm_engine_settings_set_max_num_tokens(raw, 8192));
        check(litert_lm_engine_settings_set_cache_dir(raw, cache));
        check(litert_lm_engine_settings_enable_benchmark(raw));
        LiteRtLmEngine * instance = nullptr;
        check(litert_lm_engine_create(raw, &instance));
        engine.reset(instance);
    }
    void generate(NSDictionary * request) {
        NSString * identifier = request[@"id"];
        NSArray * messages = request[@"messages"];
        NSString * format = request[@"responseFormat"];
        NSNumber * maximum = request[@"maximumTokens"];
        if (![identifier isKindOfClass:NSString.class] || identifier.length > 64 ||
            ![messages isKindOfClass:NSArray.class] || messages.count < 1 || messages.count > 13 ||
            ![format isKindOfClass:NSString.class] || ![@[@"json", @"text"] containsObject:format] ||
            ![maximum isKindOfClass:NSNumber.class] || maximum.intValue < 1 || maximum.intValue > 1024 ||
            maximum.doubleValue != maximum.intValue) throw std::runtime_error("Invalid request");
        try {
            LiteRtLmConversationConfig * rawConfig = nullptr;
            check(litert_lm_conversation_config_create(&rawConfig));
            Owned<LiteRtLmConversationConfig, litert_lm_conversation_config_delete> config(rawConfig, litert_lm_conversation_config_delete);
            LiteRtLmSessionConfig * rawSession = nullptr;
            check(litert_lm_session_config_create(&rawSession));
            Owned<LiteRtLmSessionConfig, litert_lm_session_config_delete> session(rawSession, litert_lm_session_config_delete);
            check(litert_lm_session_config_set_max_output_tokens(rawSession, maximum.intValue));
            check(litert_lm_conversation_config_set_session_config(rawConfig, rawSession));
            LiteRtLmThinkingConfig * rawThinking = nullptr;
            check(litert_lm_thinking_config_create(&rawThinking));
            Owned<LiteRtLmThinkingConfig, litert_lm_thinking_config_delete> thinking(rawThinking, litert_lm_thinking_config_delete);
            check(litert_lm_thinking_config_set_enable_thinking(rawThinking, false));
            check(litert_lm_conversation_config_set_thinking_config(rawConfig, rawThinking));
            bool constrained = [format isEqual:@"json"];
            check(litert_lm_conversation_config_set_enable_constrained_decoding(rawConfig, constrained));
            if (constrained) check(litert_lm_conversation_config_set_constraint_provider(rawConfig, kLiteRtLmConstraintProviderTypeLlGuidance));
            NSMutableArray * history = [NSMutableArray array];
            NSMutableArray * safeMessages = [NSMutableArray array];
            NSUInteger inputBytes = 0;
            for (NSUInteger i = 0; i < messages.count; ++i) {
                id message = messages[i];
                if (![message isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid message");
                NSString * role = message[@"role"], * content = message[@"content"];
                if (![role isKindOfClass:NSString.class] || ![@[@"system", @"user", @"assistant"] containsObject:role] ||
                    ![content isKindOfClass:NSString.class] || [content rangeOfString:@"\0"].location != NSNotFound)
                    throw std::runtime_error("Invalid message");
                // LiteRT's string tokenizer recognizes model control delimiters.
                // Keep quoted clipboard text from becoming conversation structure.
                content = escapeLiteRTChatContent(content);
                message = @{@"role": role, @"content": content};
                [safeMessages addObject:message];
                inputBytes += [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                if (inputBytes > 128 * 1024) throw std::runtime_error("Input too large");
                if ([role isEqual:@"system"]) {
                    if (i != 0) throw std::runtime_error("Invalid system message");
                    check(litert_lm_conversation_config_set_system_message(rawConfig, json(content).c_str()));
                } else if (i + 1 < messages.count) [history addObject:message];
                else if (![role isEqual:@"user"]) throw std::runtime_error("Expected user message");
            }
            if (![safeMessages.lastObject[@"role"] isEqual:@"user"]) throw std::runtime_error("Expected user message");
            check(litert_lm_conversation_config_set_messages(rawConfig, json(history).c_str()));
            LiteRtLmConversation * rawConversation = nullptr;
            check(litert_lm_conversation_create(engine.get(), rawConfig, &rawConversation));
            Owned<LiteRtLmConversation, litert_lm_conversation_delete> conversation(rawConversation, litert_lm_conversation_delete);
            const char * rendered = nullptr;
            std::string prompt;
            if (history.count > 0 || [messages[0][@"role"] isEqual:@"system"]) {
                check(litert_lm_conversation_render_preface_to_string(rawConversation, &rendered));
                prompt = rendered;
            }
            std::string message = json(safeMessages.lastObject);
            check(litert_lm_conversation_render_message_to_string(rawConversation, message.c_str(), &rendered));
            prompt += rendered;
            size_t input = tokens(prompt.c_str());
            if (input == 0 || input > 7168) {
                writeFrame(@{@"id": identifier, @"event": @"error", @"code": @"context_too_long", @"error": @"Context too long"});
                return;
            }
            LiteRtLmConversationOptionalArgs * rawArgs = nullptr;
            check(litert_lm_conversation_optional_args_create(&rawArgs));
            Owned<LiteRtLmConversationOptionalArgs, litert_lm_conversation_optional_args_delete> args(rawArgs, litert_lm_conversation_optional_args_delete);
            if (constrained) check(litert_lm_conversation_optional_args_set_constraint(rawArgs, kLiteRtLmConstraintTypeJsonSchema, "{\"type\":\"object\"}"));
            struct Stream {
                NSString * identifier;
                bool failed = false;
                size_t bytes = 0;
            } stream{identifier};
            check(litert_lm_conversation_send_message_stream(rawConversation, message.c_str(), nullptr, rawArgs,
                [](void * context, const LiteRtLmStreamChunk * chunk) {
                    @autoreleasepool {
                        auto & state = *static_cast<Stream *>(context);
                        try {
                            const char * error = nullptr, * value = nullptr;
                            check(litert_lm_stream_chunk_get_error(chunk, &error));
                            if (error) throw std::runtime_error("Stream failed");
                            check(litert_lm_stream_chunk_get_text(chunk, &value));
                            if (!value || state.failed) return;
                            NSData * data = [[NSString stringWithUTF8String:value] dataUsingEncoding:NSUTF8StringEncoding];
                            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if (![parsed isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid response");
                            if (!parsed[@"content"] && (parsed[@"channels"] || parsed[@"reasoning_content"])) return;
                            if (![parsed[@"content"] isKindOfClass:NSArray.class]) throw std::runtime_error("Invalid response");
                            for (id part in parsed[@"content"]) {
                                if ([part isKindOfClass:NSDictionary.class] && [part[@"type"] isEqual:@"text"] &&
                                    [part[@"text"] isKindOfClass:NSString.class] && [part[@"text"] length] > 0) {
                                    state.bytes += [part[@"text"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                                    if (state.bytes > 128 * 1024) throw std::runtime_error("Output too large");
                                    writeFrame(@{@"id": state.identifier, @"event": @"delta", @"text": part[@"text"]});
                                }
                            }
                        } catch (...) { state.failed = true; }
                    }
                }, &stream));
            check(litert_lm_conversation_wait_until_done(rawConversation));
            if (stream.failed) throw std::runtime_error("Stream failed");
            LiteRtLmBenchmarkInfo * rawInfo = nullptr;
            check(litert_lm_conversation_get_benchmark_info(rawConversation, &rawInfo));
            Owned<LiteRtLmBenchmarkInfo, litert_lm_benchmark_info_delete> info(rawInfo, litert_lm_benchmark_info_delete);
            size_t output = 0;
            check(litert_lm_benchmark_info_get_decode_token_count_at(rawInfo, 0, &output));
            if (output > static_cast<size_t>(maximum.intValue)) throw std::runtime_error("Output too large");
            writeFrame(@{@"id": identifier, @"event": @"done", @"stopReason": output >= maximum.intValue ? @"length" : @"completed",
                         @"inputTokens": @(input), @"outputTokens": @(output)});
        } catch (const std::exception &) {
            writeFrame(@{@"id": identifier, @"event": @"error", @"code": @"generation", @"error": @"Движок помощника вернул некорректный ответ."});
        }
    }
};

int main(int argc, char ** argv) {
    @autoreleasepool {
        try {
            if (argc != 3 && argc != 4) return 2;
            probeMode = argc == 4 && std::string(argv[1]) == "--probe";
            pid_t parent = getppid();
            if (parent <= 1) return 1;
            std::thread([parent] {
                while (true) {
                    std::this_thread::sleep_for(std::chrono::seconds(1));
                    if (getppid() != parent) _exit(0);
                }
            }).detach();
            Generator generator(argv[probeMode ? 2 : 1], argv[probeMode ? 3 : 2]);
            if (probeMode) {
                for (NSString * text in @[@"Ответь одним словом: готово", @"Reply with READY", @"What is 2 + 2?"]) {
                    generator.generate(@{@"id": @"probe", @"messages": @[@{@"role": @"user", @"content": text}],
                                         @"maximumTokens": @32, @"responseFormat": @"text"});
                }
                std::cout << (probeOK ? "{\"success\":true,\"summary\":\"LiteRT-LM: OK\"}" : "{\"success\":false,\"summary\":\"LiteRT-LM failed\"}") << std::endl;
                return probeOK ? 0 : 1;
            }
            while (true) {
                @autoreleasepool {
                    NSData * frame = readFrame();
                    if (!frame) return 0;
                    id request = [NSJSONSerialization JSONObjectWithData:frame options:0 error:nil];
                    if (![request isKindOfClass:NSDictionary.class]) return 2;
                    generator.generate(request);
                }
            }
        } catch (const std::exception &) { return 1; }
    }
}
