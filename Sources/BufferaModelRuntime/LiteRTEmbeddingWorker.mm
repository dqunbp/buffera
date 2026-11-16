#import <Foundation/Foundation.h>
#include "embedding_engine.h"
#include <cmath>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <chrono>
#include <unistd.h>

static void check(LiteRtLmStatusCode status) {
    if (status != kLiteRtLmStatusOk) {
        const char * message = litert_lm_get_last_error_message();
        throw std::runtime_error(message ? message : "LiteRT API failure");
    }
}

template<class T, void (*Destroy)(T*)>
using Owned = std::unique_ptr<T, decltype(Destroy)>;

class Encoder {
    Owned<LiteRtLmEmbeddingEngine, litert_lm_embedding_engine_delete> engine{nullptr, litert_lm_embedding_engine_delete};
    Owned<LiteRtLmEmbeddingOptions, litert_lm_embedding_options_delete> options{nullptr, litert_lm_embedding_options_delete};
public:
    Encoder(const char * model, const char * backend, const char * cache) {
        LiteRtLmEmbeddingEngineSettings * rawSettings = nullptr;
        check(litert_lm_embedding_engine_settings_create(model, backend, nullptr, nullptr, &rawSettings));
        Owned<LiteRtLmEmbeddingEngineSettings, litert_lm_embedding_engine_settings_delete>
            settings(rawSettings, litert_lm_embedding_engine_settings_delete);
        check(litert_lm_embedding_engine_settings_set_cache_dir(settings.get(), cache));
        check(litert_lm_embedding_engine_settings_set_max_input_length(settings.get(), 512));
        if (std::string(backend) == "cpu")
            check(litert_lm_embedding_engine_settings_set_num_threads(settings.get(), 8));
        LiteRtLmEmbeddingEngine * rawEngine = nullptr;
        check(litert_lm_embedding_engine_create(settings.get(), &rawEngine));
        engine.reset(rawEngine);
        LiteRtLmEmbeddingOptions * rawOptions = nullptr;
        check(litert_lm_embedding_options_create(&rawOptions));
        options.reset(rawOptions);
        check(litert_lm_embedding_options_set_normalize(options.get(), true));
        check(litert_lm_embedding_options_set_output_size(options.get(), 768));
        check(litert_lm_embedding_options_set_input_overflow_strategy(options.get(), kLiteRtLmInputOverflowStrategyError));
    }

    NSArray * embed(NSString * text) {
        NSData * bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
        LiteRtLmInputData * rawInput = nullptr;
        check(litert_lm_input_data_create(kLiteRtLmInputDataTypeText, bytes.bytes, bytes.length, &rawInput));
        Owned<LiteRtLmInputData, litert_lm_input_data_delete> input(rawInput, litert_lm_input_data_delete);
        const LiteRtLmInputData * inputs[] = {input.get()};
        LiteRtLmEmbeddingResponse * rawResponse = nullptr;
        check(litert_lm_embedding_engine_compute_embedding(engine.get(), inputs, 1, options.get(), &rawResponse));
        Owned<LiteRtLmEmbeddingResponse, litert_lm_embedding_response_delete>
            response(rawResponse, litert_lm_embedding_response_delete);
        size_t size = 0;
        const float * values = nullptr;
        check(litert_lm_embedding_response_get_size(response.get(), &size));
        check(litert_lm_embedding_response_get_values(response.get(), &values));
        if (size != 768 || !values) throw std::runtime_error("Invalid vector size");
        NSMutableArray * vector = [NSMutableArray arrayWithCapacity:size];
        double norm = 0;
        for (size_t i = 0; i < size; ++i) {
            if (!std::isfinite(values[i])) throw std::runtime_error("Nonfinite vector");
            norm += double(values[i]) * values[i];
            [vector addObject:@(values[i])];
        }
        if (std::abs(norm - 1) > .01) throw std::runtime_error("Vector is not normalized");
        return vector;
    }
};

static NSDictionary * readRequest() {
    uint8_t header[4];
    std::cin.read(reinterpret_cast<char *>(header), 4);
    if (std::cin.gcount() == 0 && std::cin.eof()) return nil;
    if (std::cin.gcount() != 4) throw std::runtime_error("Incomplete frame");
    uint32_t size = uint32_t(header[0]) << 24 | uint32_t(header[1]) << 16 |
                    uint32_t(header[2]) << 8 | header[3];
    if (!size || size > 4 * 1024 * 1024) throw std::runtime_error("Invalid frame size");
    NSMutableData * bytes = [NSMutableData dataWithLength:size];
    std::cin.read(static_cast<char *>(bytes.mutableBytes), size);
    if (std::cin.gcount() != size) throw std::runtime_error("Incomplete payload");
    id request = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid request");
    return request;
}

static void respond(NSDictionary * request, Encoder & encoder) {
    NSString * kind = request[@"kind"];
    NSString * identifier = request[@"id"];
    NSArray * texts = request[@"texts"];
    if (![identifier isKindOfClass:NSString.class] || identifier.length > 64 ||
        ![kind isKindOfClass:NSString.class] ||
        !([kind isEqual:@"query"] || [kind isEqual:@"document"]) ||
        ![texts isKindOfClass:NSArray.class] || texts.count < 1 || texts.count > 4)
        throw std::runtime_error("Invalid request fields");
    bool query = [kind isEqual:@"query"];
    NSString * prefix = query ? @"task: search result | query: " : @"title: none | text: ";
    NSMutableArray * outputs = [NSMutableArray array];
    for (id text in texts) {
        if (![text isKindOfClass:NSString.class] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128*1024)
            throw std::runtime_error("Invalid input text");
        NSString * clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length == 0) throw std::runtime_error("Empty input");
        NSData * bytes = [clean dataUsingEncoding:NSUTF8StringEncoding];
        // Conservative byte windows preserve UTF-8 boundaries and stay below the
        // 512-token limit even for byte-fallback text. Keep this in modelKey.
        if (query && bytes.length > 384) throw std::runtime_error("Query too long");
        std::string value(static_cast<const char *>(bytes.bytes), bytes.length);
        NSMutableArray * vectors = [NSMutableArray array];
        size_t offset = 0;
        bool truncated = false;
        while (offset < value.size()) {
            size_t end = std::min(offset + 384, value.size());
            while (end < value.size() && (static_cast<unsigned char>(value[end]) & 0xc0) == 0x80) --end;
            NSString * chunk = [[NSString alloc] initWithBytes:value.data() + offset length:end - offset encoding:NSUTF8StringEncoding];
            [vectors addObject:encoder.embed([prefix stringByAppendingString:chunk])];
            if (end == value.size()) break;
            if (vectors.count == 32) { truncated = true; break; }
            offset = end - 64;
            while ((static_cast<unsigned char>(value[offset]) & 0xc0) == 0x80) ++offset;
        }
        [outputs addObject:@{@"vectors": vectors, @"truncated": @(truncated)}];
    }
    NSData * data = [NSJSONSerialization dataWithJSONObject:@{@"id": identifier, @"outputs": outputs} options:0 error:nil];
    if (!data || data.length > 4*1024*1024) throw std::runtime_error("Invalid response");
    uint32_t size = uint32_t(data.length);
    uint8_t header[] = {uint8_t(size >> 24), uint8_t(size >> 16), uint8_t(size >> 8), uint8_t(size)};
    std::cout.write(reinterpret_cast<char *>(header), 4);
    std::cout.write(static_cast<const char *>(data.bytes), size);
    std::cout.flush();
    if (!std::cout) throw std::runtime_error("Client disconnected");
}

int main(int argc, char ** argv) {
    @autoreleasepool {
        try {
            if (argc != 3 && argc != 4) return 2;
            bool probe = argc == 4 && std::string(argv[1]) == "--probe";
            const pid_t parent = getppid();
            if (parent <= 1) return 1;
            std::thread([parent] {
                while (true) {
                    std::this_thread::sleep_for(std::chrono::seconds(1));
                    if (getppid() != parent) _exit(0);
                }
            }).detach();
            Encoder encoder(argv[probe ? 2 : 1], "gpu", argv[probe ? 3 : 2]);
            if (probe) {
                for (NSString * text in @[@"Проверка поиска", @"Search check", @"let value = 42"]) encoder.embed(text);
                std::cout << "{\"success\":true,\"summary\":\"LiteRT-LM: OK\"}" << std::endl;
                return 0;
            }
            while (true) {
                @autoreleasepool {
                    NSDictionary * request = readRequest();
                    if (!request) break;
                    respond(request, encoder);
                }
            }
        } catch (const std::exception & error) {
            std::cerr << error.what() << std::endl;
            return 1;
        }
    }
    return 0;
}
