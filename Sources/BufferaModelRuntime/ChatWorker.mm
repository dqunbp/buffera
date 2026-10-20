// Private local worker. Conversation text travels over anonymous pipes, never argv or logs.
#import <Foundation/Foundation.h>
#include "ChatGenerator.hpp"
#include "ggml-backend.h"
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <unistd.h>

static constexpr uint32_t maximumFrame = 1024 * 1024;
static void quietLog(ggml_log_level, const char *, void *) {}

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

static std::string utf8(NSString * value) {
    NSData * bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes) throw std::runtime_error("Некорректный текст сообщения.");
    return std::string(static_cast<const char *>(bytes.bytes), bytes.length);
}

int main(int argc, char ** argv) {
    @autoreleasepool {
        try {
            if (argc != 2) return 2;
            const pid_t parent = getppid();
            if (parent <= 1) return 1;
            std::thread([parent] {
                while (true) {
                    std::this_thread::sleep_for(std::chrono::seconds(1));
                    if (getppid() != parent) _exit(0);
                }
            }).detach();
            const std::filesystem::path path(argv[1]);
            if (!path.is_absolute() || !std::filesystem::is_regular_file(path)) return 2;
            const auto binary = std::filesystem::canonical(argv[0]);
            const auto backends = binary.parent_path().parent_path() / "Frameworks" / "BufferaModels";
            llama_log_set(quietLog, nullptr);
            ggml_log_set(quietLog, nullptr);
            ggml_backend_load_all_from_path(backends.c_str());
            llama_backend_init();
            {
                auto parameters = llama_model_default_params();
                parameters.n_gpu_layers = -1;
                parameters.check_tensors = true;
                std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
                    llama_model_load_from_file(path.c_str(), parameters), llama_model_free);
                if (!model) return 3;
                char architecture[128] = {};
                llama_model_meta_val_str(model.get(), "general.architecture", architecture, sizeof(architecture));
                if (std::string(architecture) != "gemma4" || !llama_model_has_decoder(model.get())) return 3;
                buffera::ChatGenerator generator(model.get());
                while (true) {
                    @autoreleasepool {
                        NSData * bytes = readFrame();
                        if (!bytes) break;
                        id parsed = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
                        if (![parsed isKindOfClass:[NSDictionary class]]) return 2;
                        NSDictionary * request = parsed;
                        NSString * identifier = request[@"id"];
                        NSString * format = request[@"responseFormat"];
                        NSNumber * maximum = request[@"maximumTokens"];
                        NSArray * messages = request[@"messages"];
                        if (![identifier isKindOfClass:[NSString class]] || identifier.length > 64 ||
                            ![format isKindOfClass:[NSString class]] ||
                            !([format isEqualToString:@"text"] || [format isEqualToString:@"json"]) ||
                            ![maximum isKindOfClass:[NSNumber class]] ||
                            maximum.doubleValue != maximum.intValue || maximum.intValue < 1 || maximum.intValue > 1024 ||
                            ![messages isKindOfClass:[NSArray class]] || messages.count < 1 || messages.count > 13) return 2;
                        try {
                            std::vector<buffera::ChatMessage> input;
                            for (id value in messages) {
                                if (![value isKindOfClass:[NSDictionary class]]) {
                                    throw std::runtime_error("Некорректное сообщение для помощника.");
                                }
                                NSString * role = value[@"role"];
                                NSString * content = value[@"content"];
                                if (![role isKindOfClass:[NSString class]] || ![content isKindOfClass:[NSString class]]) {
                                    throw std::runtime_error("Некорректное сообщение для помощника.");
                                }
                                input.push_back({utf8(role), utf8([content stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]])});
                            }
                            const auto result = generator.generate(input, maximum.intValue, [format isEqualToString:@"json"],
                                [identifier](const std::string & text) {
                                    @autoreleasepool {
                                        NSString * value = [[NSString alloc] initWithBytes:text.data() length:text.size()
                                                                                encoding:NSUTF8StringEncoding];
                                        if (!value) throw std::runtime_error("Некорректный фрагмент ответа.");
                                        writeFrame(@{@"id": identifier, @"event": @"delta", @"text": value});
                                    }
                                });
                            writeFrame(@{@"id": identifier, @"event": @"done",
                                         @"stopReason": result.limited ? @"length" : @"completed",
                                         @"inputTokens": @(result.inputTokens), @"outputTokens": @(result.outputTokens)});
                        } catch (const buffera::ChatContextTooLong & error) {
                            writeFrame(@{@"id": identifier, @"event": @"error", @"code": @"context_too_long",
                                         @"error": [NSString stringWithUTF8String:error.what()]});
                        } catch (const std::exception & error) {
                            writeFrame(@{@"id": identifier, @"event": @"error", @"code": @"generation",
                                         @"error": [NSString stringWithUTF8String:error.what()]});
                        }
                    }
                }
            }
            llama_backend_free();
            return 0;
        } catch (const std::exception &) {
            return 1;
        }
    }
}
