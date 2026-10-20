// Private local worker. Plaintext travels only over anonymous pipes, never argv or logs.
#import <Foundation/Foundation.h>
#include "EmbeddingEncoder.hpp"
#include "ggml-backend.h"
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <memory>
#include <unistd.h>

static constexpr uint32_t maximumFrame = 4 * 1024 * 1024;
static void quietLog(ggml_log_level, const char *, void *) {}

static NSData * readFrame() {
    unsigned char header[4];
    std::cin.read(reinterpret_cast<char *>(header), 4);
    if (std::cin.gcount() == 0 && std::cin.eof()) return nil;
    if (std::cin.gcount() != 4) throw std::runtime_error("Некорректный запрос к движку.");
    const uint32_t size = (uint32_t(header[0]) << 24) | (uint32_t(header[1]) << 16) |
                          (uint32_t(header[2]) << 8) | uint32_t(header[3]);
    if (!size || size > maximumFrame) throw std::runtime_error("Некорректный размер запроса.");
    NSMutableData * data = [NSMutableData dataWithLength:size];
    std::cin.read(static_cast<char *>(data.mutableBytes), size);
    if (std::cin.gcount() != size) throw std::runtime_error("Незавершённый запрос к движку.");
    return data;
}

static void writeFrame(NSDictionary * value) {
    NSError * error = nil;
    NSData * data = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (!data || data.length > maximumFrame) throw std::runtime_error("Не удалось передать эмбеддинг.");
    uint32_t size = uint32_t(data.length);
    unsigned char header[] = {static_cast<unsigned char>(size >> 24), static_cast<unsigned char>(size >> 16),
                              static_cast<unsigned char>(size >> 8), static_cast<unsigned char>(size)};
    std::cout.write(reinterpret_cast<char *>(header), 4);
    std::cout.write(static_cast<const char *>(data.bytes), size);
    std::cout.flush();
    if (!std::cout) throw std::runtime_error("Клиент поиска отключён.");
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
                if (std::string(architecture) != "gemma-embedding2" || llama_model_n_embd_out(model.get()) != 768) {
                    return 3;
                }
                buffera::EmbeddingEncoder encoder(model.get());
                while (true) {
                    @autoreleasepool {
                        NSData * bytes = readFrame();
                        if (!bytes) break;
                        id parsed = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
                        if (![parsed isKindOfClass:[NSDictionary class]]) return 2;
                        NSDictionary * request = parsed;
                        NSString * identifier = request[@"id"];
                        NSString * kind = request[@"kind"];
                        NSArray * texts = request[@"texts"];
                        if (![identifier isKindOfClass:[NSString class]] || identifier.length > 64 ||
                            ![kind isKindOfClass:[NSString class]] ||
                            !([kind isEqualToString:@"document"] || [kind isEqualToString:@"query"]) ||
                            ![texts isKindOfClass:[NSArray class]] || texts.count < 1 || texts.count > 4) return 2;
                        try {
                            NSMutableArray * results = [NSMutableArray arrayWithCapacity:texts.count];
                            for (id text in texts) {
                                if (![text isKindOfClass:[NSString class]]) {
                                    throw std::runtime_error("Некорректный текст для поиска.");
                                }
                                NSData * utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
                                if (!utf8 || utf8.length > 128 * 1024) {
                                    throw std::runtime_error("Текст запроса слишком длинный.");
                                }
                                const auto result = encoder.embed(
                                    std::string(static_cast<const char *>(utf8.bytes), utf8.length),
                                    [kind isEqualToString:@"query"]);
                                NSMutableArray * vectors = [NSMutableArray arrayWithCapacity:result.vectors.size()];
                                for (const auto & vector : result.vectors) {
                                    NSMutableArray * values = [NSMutableArray arrayWithCapacity:vector.size()];
                                    for (float value : vector) [values addObject:@(value)];
                                    [vectors addObject:values];
                                }
                                [results addObject:@{@"vectors": vectors, @"truncated": @(result.truncated)}];
                            }
                            writeFrame(@{@"id": identifier, @"outputs": results});
                        } catch (const std::exception & error) {
                            writeFrame(@{@"id": identifier,
                                         @"error": [NSString stringWithUTF8String:error.what()]});
                        }
                    }
                }
            }
            llama_backend_free();
            return 0;
        } catch (const std::exception &) {
            // No caller-provided text is reported by failures or runtime logging.
            return 1;
        }
    }
}
