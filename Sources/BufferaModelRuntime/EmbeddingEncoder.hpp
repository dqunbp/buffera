#pragma once

#include "llama.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace buffera {

struct EmbeddingResult {
    std::vector<std::vector<float>> vectors;
    bool truncated = false;
};

/// The index identity includes these token limits and both task prefixes.
/// Tokenization treats clipboard text as literal text, including apparent special tokens.
class EmbeddingEncoder {
    static constexpr size_t bodyLimit = 512;
    static constexpr size_t overlap = 64;
    static constexpr size_t maximumChunks = 32;
    llama_model * model;
    const llama_vocab * vocab;
    std::unique_ptr<llama_context, decltype(&llama_free)> context;

    std::vector<llama_token> tokenize(const std::string & text) const {
        std::vector<llama_token> tokens(text.size() + 32);
        int count = llama_tokenize(vocab, text.data(), int(text.size()), tokens.data(),
                                   int(tokens.size()), false, false);
        if (count < 0) throw std::runtime_error("Не удалось подготовить текст для поиска.");
        tokens.resize(size_t(count));
        return tokens;
    }

    std::vector<float> encode(const std::vector<llama_token> & prefix,
                              const std::vector<llama_token> & body,
                              size_t start, size_t end) {
        std::vector<llama_token> tokens;
        if (llama_vocab_get_add_bos(vocab)) tokens.push_back(llama_vocab_bos(vocab));
        tokens.insert(tokens.end(), prefix.begin(), prefix.end());
        tokens.insert(tokens.end(), body.begin() + start, body.begin() + end);
        if (llama_vocab_get_add_eos(vocab)) tokens.push_back(llama_vocab_eos(vocab));
        if (tokens.size() > 576) throw std::runtime_error("Текст не помещается в окно модели поиска.");
        if (auto memory = llama_get_memory(context.get())) llama_memory_clear(memory, false);
        auto batch = llama_batch_init(int(tokens.size()), 0, 1);
        for (size_t i = 0; i < tokens.size(); ++i) {
            batch.token[i] = tokens[i];
            batch.pos[i] = int(i);
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            batch.logits[i] = true;
        }
        batch.n_tokens = int(tokens.size());
        const int status = llama_model_has_encoder(model) ? llama_encode(context.get(), batch)
                                                         : llama_decode(context.get(), batch);
        llama_batch_free(batch);
        if (status != 0) throw std::runtime_error("Не удалось вычислить эмбеддинг.");
        const float * values = llama_get_embeddings_seq(context.get(), 0);
        if (!values || llama_model_n_embd_out(model) != 768) {
            throw std::runtime_error("Модель вернула эмбеддинг неожиданного размера.");
        }
        std::vector<float> result(values, values + 768);
        double norm = 0;
        for (float value : result) {
            if (!std::isfinite(value)) throw std::runtime_error("Эмбеддинг содержит некорректные числа.");
            norm += double(value) * value;
        }
        if (norm < 1e-12) throw std::runtime_error("Модель вернула пустой эмбеддинг.");
        for (float & value : result) value = float(value / std::sqrt(norm));
        return result;
    }

public:
    explicit EmbeddingEncoder(llama_model * value) : model(value), vocab(llama_model_get_vocab(value)),
        context(nullptr, llama_free) {
        auto parameters = llama_context_default_params();
        parameters.n_ctx = 576;
        parameters.n_batch = 576;
        parameters.n_ubatch = 576;
        parameters.n_seq_max = 1;
        parameters.n_threads = int(std::max(1u, std::min(8u, std::thread::hardware_concurrency())));
        parameters.n_threads_batch = parameters.n_threads;
        parameters.embeddings = true;
        parameters.no_perf = true;
        parameters.attention_type = LLAMA_ATTENTION_TYPE_NON_CAUSAL;
        parameters.pooling_type = LLAMA_POOLING_TYPE_MEAN;
        context.reset(llama_init_from_model(model, parameters));
        if (!context) throw std::runtime_error("Не удалось выделить память для модели поиска.");
    }

    EmbeddingResult embed(const std::string & text, bool query) {
        if (text.empty() || text.size() > 128 * 1024) {
            throw std::runtime_error("Текст запроса слишком длинный или пустой.");
        }
        const auto body = tokenize(text);
        if (body.empty() || (query && body.size() > bodyLimit)) {
            throw std::runtime_error("Поисковый запрос превышает 512 токенов или пустой.");
        }
        const auto prefix = tokenize(query ? "task: search result | query: " : "title: none | text: ");
        EmbeddingResult result;
        for (size_t start = 0; start < body.size(); start += bodyLimit - overlap) {
            const size_t end = std::min(start + bodyLimit, body.size());
            result.vectors.push_back(encode(prefix, body, start, end));
            if (end == body.size()) break;
            if (result.vectors.size() == maximumChunks) {
                result.truncated = true;
                break;
            }
        }
        return result;
    }
};

} // namespace buffera
