#pragma once

#include "llama.h"
#include <algorithm>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace buffera {

struct ChatMessage {
    std::string role;
    std::string content;
};

struct ChatResult {
    int inputTokens;
    int outputTokens;
    bool limited;
};

class ChatContextTooLong : public std::runtime_error {
public:
    ChatContextTooLong() : std::runtime_error("В запросе слишком много текста для локального помощника.") {}
};

// Text-only, no-thinking subset of Google's canonical Gemma 4 template:
// https://huggingface.co/google/gemma-4-E2B-it/blob/main/chat_template.jinja
// The same subset is present in the template shipped with our pinned GGUF revision.
class ChatGenerator {
    llama_model * model;
    const llama_vocab * vocab;

    void append(std::vector<llama_token> & target, const std::string & text, bool special) const {
        std::vector<llama_token> tokens(text.size() + 32);
        int count = llama_tokenize(vocab, text.data(), int(text.size()), tokens.data(),
                                   int(tokens.size()), false, special);
        if (count < 0) throw std::runtime_error("Не удалось подготовить сообщения для помощника.");
        target.insert(target.end(), tokens.begin(), tokens.begin() + count);
        if (target.size() > 7168) throw ChatContextTooLong();
    }

    std::vector<llama_token> prepare(const std::vector<ChatMessage> & messages) const {
        if (messages.empty() || messages.size() > 13 || messages.back().role != "user") {
            throw std::runtime_error("Неподходящий порядок сообщений.");
        }
        size_t bytes = 0;
        std::vector<llama_token> tokens;
        const auto bos = llama_vocab_bos(vocab);
        if (bos != LLAMA_TOKEN_NULL) tokens.push_back(bos);
        std::string expected = "user";
        for (size_t index = 0; index < messages.size(); ++index) {
            const auto & message = messages[index];
            bytes += message.content.size();
            if (bytes > 128 * 1024) throw ChatContextTooLong();
            if (message.content.empty() ||
                (!(index == 0 && message.role == "system") && message.role != expected)) {
                throw std::runtime_error("Неподходящий порядок сообщений.");
            }
            if (message.role != "system") expected = expected == "user" ? "assistant" : "user";
            append(tokens, "<|turn>" + (message.role == "assistant" ? "model" : message.role) + "\n", true);
            // Never let clipboard text, prior model output or a user message create a control token.
            append(tokens, message.content, false);
            append(tokens, "<turn|>\n", true);
        }
        append(tokens, "<|turn>model\n", true);
        return tokens;
    }

    static size_t completeUTF8Prefix(const std::string & text) {
        size_t offset = 0;
        while (offset < text.size()) {
            const auto first = static_cast<unsigned char>(text[offset]);
            const size_t size = first <= 0x7f ? 1 : first >= 0xc2 && first <= 0xdf ? 2 :
                                first >= 0xe0 && first <= 0xef ? 3 :
                                first >= 0xf0 && first <= 0xf4 ? 4 : 0;
            if (!size) throw std::runtime_error("Помощник вернул некорректный текст.");
            if (offset + size > text.size()) return offset;
            for (size_t i = 1; i < size; ++i) {
                const auto next = static_cast<unsigned char>(text[offset + i]);
                if ((next & 0xc0) != 0x80) throw std::runtime_error("Помощник вернул некорректный текст.");
            }
            if (size >= 3) {
                const auto second = static_cast<unsigned char>(text[offset + 1]);
                if ((first == 0xe0 && second < 0xa0) || (first == 0xed && second >= 0xa0) ||
                    (first == 0xf0 && second < 0x90) || (first == 0xf4 && second >= 0x90)) {
                    throw std::runtime_error("Помощник вернул некорректный текст.");
                }
            }
            offset += size;
        }
        return offset;
    }

    // Upstream MIT-licensed grammars/json.gbnf at pinned llama.cpp revision d806193.
    static constexpr const char * jsonGrammar = R"GBNF(
root ::= object
value ::= object | array | string | number | ("true" | "false" | "null") ws
object ::= "{" ws (string ":" ws value ("," ws string ":" ws value)*)? "}" ws
array ::= "[" ws (value ("," ws value)*)? "]" ws
string ::= "\"" ([^"\\\x7F\x00-\x1F] | "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4}))* "\"" ws
number ::= ("-"? ([0-9] | [1-9] [0-9]{0,15})) ("." [0-9]+)? ([eE] [-+]? [0-9] [1-9]{0,15})? ws
ws ::= | " " | "\n" [ \t]{0,20}
)GBNF";

public:
    explicit ChatGenerator(llama_model * value) : model(value), vocab(llama_model_get_vocab(value)) {}

    ChatResult generate(const std::vector<ChatMessage> & messages, int maximumTokens, bool json,
                        const std::function<void(const std::string &)> & emit) const {
        if (maximumTokens < 1 || maximumTokens > 1024) {
            throw std::runtime_error("Некорректный предел длины ответа.");
        }
        const auto tokens = prepare(messages);
        auto parameters = llama_context_default_params();
        parameters.n_ctx = 8192;
        parameters.n_batch = 512;
        parameters.n_ubatch = 512;
        parameters.n_seq_max = 1;
        parameters.n_threads = int(std::max(1u, std::min(8u, std::thread::hardware_concurrency())));
        parameters.n_threads_batch = parameters.n_threads;
        parameters.no_perf = true;
        std::unique_ptr<llama_context, decltype(&llama_free)> context(
            llama_init_from_model(model, parameters), llama_free);
        if (!context) throw std::runtime_error("Не удалось запустить локального помощника. Проверьте доступную память.");

        // Only this request owns KV state. A later request starts with a fresh context.
        auto batch = llama_batch_init(512, 0, 1);
        for (size_t start = 0; start < tokens.size(); start += 512) {
            const auto count = std::min(size_t(512), tokens.size() - start);
            for (size_t i = 0; i < count; ++i) {
                batch.token[i] = tokens[start + i];
                batch.pos[i] = int(start + i);
                batch.n_seq_id[i] = 1;
                batch.seq_id[i][0] = 0;
                batch.logits[i] = start + i + 1 == tokens.size();
            }
            batch.n_tokens = int(count);
            const int status = llama_decode(context.get(), batch);
            if (status != 0) {
                llama_batch_free(batch);
                throw std::runtime_error("Не удалось обработать сообщения для помощника.");
            }
        }
        llama_batch_free(batch);

        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
            llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
        if (!sampler) throw std::runtime_error("Не удалось подготовить генерацию.");
        if (json) {
            auto grammar = llama_sampler_init_grammar(vocab, jsonGrammar, "root");
            if (!grammar) throw std::runtime_error("Не удалось подготовить формат ответа.");
            llama_sampler_chain_add(sampler.get(), grammar);
        }
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
        ChatResult result{int(tokens.size()), 0, true};
        std::string pending;
        size_t outputBytes = 0;
        for (int i = 0; i < maximumTokens; ++i) {
            llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
            if (llama_vocab_is_eog(vocab, token)) { result.limited = false; break; }
            result.outputTokens += 1;
            std::vector<char> piece(256);
            int size = llama_token_to_piece(vocab, token, piece.data(), int(piece.size()), 0, false);
            if (size < 0) {
                piece.resize(size_t(-size));
                size = llama_token_to_piece(vocab, token, piece.data(), int(piece.size()), 0, false);
            }
            if (size < 0) throw std::runtime_error("Не удалось прочитать ответ помощника.");
            pending.append(piece.data(), size_t(size));
            outputBytes += size_t(size);
            if (outputBytes > 128 * 1024) throw std::runtime_error("Ответ помощника слишком длинный.");
            const auto complete = completeUTF8Prefix(pending);
            if (complete) {
                emit(pending.substr(0, complete));
                pending.erase(0, complete);
            }
            if (i + 1 < maximumTokens) {
                auto next = llama_batch_get_one(&token, 1);
                if (llama_decode(context.get(), next) != 0) {
                    throw std::runtime_error("Генерация ответа завершилась с ошибкой.");
                }
            }
        }
        // At the token cap the final UTF-8 scalar may be incomplete; never emit invalid text.
        if (!pending.empty() && !result.limited) {
            throw std::runtime_error("Помощник вернул незавершённый текст.");
        }
        return result;
    }
};

} // namespace buffera
