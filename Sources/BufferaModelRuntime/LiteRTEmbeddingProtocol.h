#pragma once
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

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

static void writeFrame(NSDictionary * response) {
    NSData * data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (!data || data.length > 4*1024*1024) throw std::runtime_error("Invalid response");
    uint32_t size = uint32_t(data.length);
    uint8_t header[] = {uint8_t(size >> 24), uint8_t(size >> 16), uint8_t(size >> 8), uint8_t(size)};
    std::cout.write(reinterpret_cast<char *>(header), 4);
    std::cout.write(static_cast<const char *>(data.bytes), size);
    std::cout.flush();
    if (!std::cout) throw std::runtime_error("Client disconnected");
}

template<class Encoder>
static void respond(NSDictionary * request, Encoder & encoder) {
    NSString * kind = request[@"kind"];
    NSString * identifier = request[@"id"];
    NSArray * texts = request[@"texts"];
    if (![identifier isKindOfClass:NSString.class] || identifier.length > 64 ||
        ![kind isKindOfClass:NSString.class] ||
        !([kind isEqual:@"query"] || [kind isEqual:@"document"]) ||
        ![texts isKindOfClass:NSArray.class] || texts.count < 1 || texts.count > 4)
        throw std::invalid_argument("Некорректный текст для поиска.");
    bool query = [kind isEqual:@"query"];
    NSString * prefix = query ? @"task: search result | query: " : @"title: none | text: ";
    NSMutableArray * outputs = [NSMutableArray array];
    for (id text in texts) {
        if (![text isKindOfClass:NSString.class] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128*1024)
            throw std::invalid_argument("Некорректный текст для поиска.");
        NSString * clean = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (clean.length == 0) throw std::invalid_argument("Некорректный текст для поиска.");
        NSData * bytes = [clean dataUsingEncoding:NSUTF8StringEncoding];
        // Conservative byte windows preserve UTF-8 boundaries and stay below the
        // 512-token limit even for byte-fallback text. Keep this in modelKey.
        if (query && bytes.length > 384) throw std::invalid_argument("Текст запроса слишком длинный.");
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
    writeFrame(@{@"id": identifier, @"outputs": outputs});
}

template<class Encoder>
static void runEmbeddingRequests(Encoder & encoder) {
    while (true) {
        @autoreleasepool {
            NSDictionary * request = readRequest();
            if (!request) break;
            NSString * identifier = request[@"id"];
            if (![identifier isKindOfClass:NSString.class] || identifier.length > 64)
                throw std::runtime_error("Invalid request id");
            try { respond(request, encoder); }
            catch (const std::invalid_argument & error) {
                writeFrame(@{@"id": identifier, @"error": [NSString stringWithUTF8String:error.what()]});
            } catch (const std::exception &) {
                writeFrame(@{@"id": identifier, @"error": @"Движок поиска вернул некорректный ответ."});
            }
        }
    }
}
