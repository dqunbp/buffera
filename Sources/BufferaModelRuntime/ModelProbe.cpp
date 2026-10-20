// Runs fixed synthetic checks only. Production search/chat will use a separate API.
// Keeping inference in a child process makes cancellation and memory release immediate.
#include "llama.h"
#include "ggml-backend.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using Model = std::unique_ptr<llama_model, decltype(&llama_model_free)>;
using Context = std::unique_ptr<llama_context, decltype(&llama_free)>;
using Sampler = std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)>;

static void runtimeLog(ggml_log_level level, const char * text, void *) {
    if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR) std::fputs(text, stderr);
}

static std::string jsonString(const std::string & text) {
    std::ostringstream result;
    result << '"';
    for (unsigned char c : text) {
        switch (c) {
            case '"': result << "\\\""; break;
            case '\\': result << "\\\\"; break;
            case '\n': result << "\\n"; break;
            case '\r': result << "\\r"; break;
            case '\t': result << "\\t"; break;
            default:
                if (c < 0x20) {
                    result << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c)
                           << std::dec;
                } else {
                    result << c;
                }
        }
    }
    result << '"';
    return result.str();
}

static std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text) {
    std::vector<llama_token> tokens(text.size() + 32);
    int count = llama_tokenize(vocab, text.data(), int(text.size()), tokens.data(),
                               int(tokens.size()), true, true);
    if (count < 0) {
        throw std::runtime_error("Не удалось подготовить текст проверки.");
    }
    tokens.resize(count);
    if (tokens.empty() || tokens.size() > 384) {
        throw std::runtime_error("Неподходящая длина тестового текста.");
    }
    return tokens;
}

static Context makeContext(llama_model * model, bool embedding) {
    auto params = llama_context_default_params();
    params.n_ctx = 512;
    params.n_batch = 512;
    params.n_ubatch = 512;
    params.n_seq_max = 1;
    params.n_threads = int(std::max(1u, std::min(8u, std::thread::hardware_concurrency())));
    params.n_threads_batch = params.n_threads;
    params.embeddings = embedding;
    params.no_perf = true;
    if (embedding) {
        // EmbeddingGemma 2 is a bidirectional encoder with mean pooling.
        params.attention_type = LLAMA_ATTENTION_TYPE_NON_CAUSAL;
        params.pooling_type = LLAMA_POOLING_TYPE_MEAN;
    }
    Context context(llama_init_from_model(model, params), llama_free);
    if (!context) throw std::runtime_error("Не удалось выделить память для модели.");
    return context;
}

static std::vector<float> embed(llama_model * model, const std::string & text) {
    auto context = makeContext(model, true);
    auto tokens = tokenize(llama_model_get_vocab(model), "title: none | text: " + text);
    auto batch = llama_batch_init(int(tokens.size()), 0, 1);
    for (size_t i = 0; i < tokens.size(); ++i) {
        batch.token[i] = tokens[i];
        batch.pos[i] = int(i);
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = true;
    }
    batch.n_tokens = int(tokens.size());
    int status = llama_model_has_encoder(model) ? llama_encode(context.get(), batch)
                                               : llama_decode(context.get(), batch);
    llama_batch_free(batch);
    if (status != 0) throw std::runtime_error("Модель не смогла вычислить эмбеддинг.");
    int dimension = llama_model_n_embd_out(model);
    const float * values = llama_get_embeddings_seq(context.get(), 0);
    if (!values || dimension != 768) {
        throw std::runtime_error("Модель вернула эмбеддинг неожиданного размера.");
    }
    std::vector<float> result(values, values + dimension);
    double norm = 0;
    for (float value : result) {
        if (!std::isfinite(value)) throw std::runtime_error("Эмбеддинг содержит некорректные числа.");
        norm += double(value) * value;
    }
    if (norm < 1e-12) throw std::runtime_error("Модель вернула пустой эмбеддинг.");
    for (float & value : result) value = float(value / std::sqrt(norm));
    return result;
}

static double cosine(const std::vector<float> & left, const std::vector<float> & right) {
    double result = 0;
    for (size_t i = 0; i < left.size(); ++i) result += double(left[i]) * right[i];
    return result;
}

static std::string checkEmbeddings(llama_model * model) {
    // Similarity is reported for inspection, not used as an invented quality threshold.
    const std::vector<std::string> samples = {
        "Не удалось подключиться к базе данных.",
        "Could not connect to the database.",
        "raise ConnectionError(\"connection refused\")"
    };
    std::vector<std::vector<float>> embeddings;
    for (const auto & text : samples) embeddings.push_back(embed(model, text));
    std::ostringstream result;
    result << "\"summary\":\"Русский, английский и код: получены 3 корректных эмбеддинга по 768 чисел.\","
           << "\"dimensions\":768,\"samples\":[";
    for (size_t i = 0; i < samples.size(); ++i) {
        if (i) result << ',';
        result << "{\"input\":" << jsonString(samples[i]) << ",\"dimensions\":768}";
    }
    result << "],\"similarities\":{\"ru_en\":" << cosine(embeddings[0], embeddings[1])
           << ",\"ru_code\":" << cosine(embeddings[0], embeddings[2]) << '}';
    return result.str();
}

// A token limit can leave an incomplete final UTF-8 character. Do not emit invalid JSON.
static void trimIncompleteUTF8(std::string & text) {
    if (text.empty()) return;
    size_t start = text.size() - 1;
    while (start > 0 && (static_cast<unsigned char>(text[start]) & 0xc0) == 0x80) --start;
    unsigned char lead = static_cast<unsigned char>(text[start]);
    size_t expected = lead < 0x80 ? 1 : (lead & 0xe0) == 0xc0 ? 2 :
                      (lead & 0xf0) == 0xe0 ? 3 : (lead & 0xf8) == 0xf0 ? 4 : 1;
    if (text.size() - start < expected) text.resize(start);
}

static std::string generate(llama_model * model, const std::string & request) {
    auto context = makeContext(model, false);
    const auto * vocab = llama_model_get_vocab(model);
    // Exact single-user, no-thinking Gemma 4 format from its published chat_template.jinja.
    // llama_chat_apply_template does not support this newer template.
    auto tokens = tokenize(vocab, "<|turn>user\n" + request + "<turn|>\n<|turn>model\n");
    auto batch = llama_batch_get_one(tokens.data(), int(tokens.size()));
    if (llama_decode(context.get(), batch) != 0) {
        throw std::runtime_error("Модель не смогла обработать тестовый запрос.");
    }
    Sampler sampler(llama_sampler_init_greedy(), llama_sampler_free);
    if (!sampler) throw std::runtime_error("Не удалось подготовить генерацию.");
    std::string output;
    for (int i = 0; i < 96; ++i) {
        llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        std::vector<char> piece(256);
        int size = llama_token_to_piece(vocab, token, piece.data(), int(piece.size()), 0, false);
        if (size < 0) {
            piece.resize(size_t(-size));
            size = llama_token_to_piece(vocab, token, piece.data(), int(piece.size()), 0, false);
        }
        if (size < 0) throw std::runtime_error("Не удалось прочитать ответ модели.");
        output.append(piece.data(), size_t(size));
        batch = llama_batch_get_one(&token, 1);
        if (llama_decode(context.get(), batch) != 0) {
            throw std::runtime_error("Генерация ответа завершилась с ошибкой.");
        }
    }
    trimIncompleteUTF8(output);
    if (output.find_first_not_of(" \n\r\t") == std::string::npos) {
        throw std::runtime_error("Модель вернула пустой ответ.");
    }
    return output;
}

static std::string checkChat(llama_model * model) {
    const std::vector<std::string> samples = {
        "Ответь одним коротким предложением по-русски: для чего нужен буфер обмена?",
        "In one short English sentence, what is a computer clipboard?",
        "What does this Python code return? Reply briefly: sum([1, 2, 3])"
    };
    std::ostringstream result;
    result << "\"summary\":\"Модель ответила на 3 тестовых запроса: русский, английский и код.\","
           << "\"samples\":[";
    for (size_t i = 0; i < samples.size(); ++i) {
        if (i) result << ',';
        result << "{\"input\":" << jsonString(samples[i])
               << ",\"output\":" << jsonString(generate(model, samples[i])) << '}';
    }
    result << ']';
    return result.str();
}

int main(int argc, char ** argv) {
    const auto started = std::chrono::steady_clock::now();
    try {
        if (argc != 3 || (std::string(argv[1]) != "embedding" && std::string(argv[1]) != "chat")) {
            throw std::runtime_error("Использование: BufferaModelProbe embedding|chat /путь/к/модели.gguf");
        }
        const std::filesystem::path modelPath(argv[2]);
        if (!modelPath.is_absolute() || !std::filesystem::is_regular_file(modelPath)) {
            throw std::runtime_error("Файл модели не найден.");
        }
        const auto binary = std::filesystem::canonical(argv[0]);
        const auto backends = binary.parent_path().parent_path() / "Frameworks" / "BufferaModels";
        // Only packaged backends are loaded. There is no server or external process command.
        llama_log_set(runtimeLog, nullptr);
        ggml_log_set(runtimeLog, nullptr);
        ggml_backend_load_all_from_path(backends.c_str());
        llama_backend_init();
        auto params = llama_model_default_params();
        params.n_gpu_layers = -1;
        params.check_tensors = true;
        Model model(llama_model_load_from_file(modelPath.c_str(), params), llama_model_free);
        if (!model) throw std::runtime_error("Не удалось открыть модель. Проверьте файл и свободную память.");
        char architecture[128] = {};
        llama_model_meta_val_str(model.get(), "general.architecture", architecture, sizeof(architecture));
        const std::string expected = std::string(argv[1]) == "embedding" ? "gemma-embedding2" : "gemma4";
        if (std::string(architecture) != expected) {
            throw std::runtime_error("Эта модель не подходит для выбранной проверки.");
        }
        const std::string result = std::string(argv[1]) == "embedding"
            ? checkEmbeddings(model.get()) : checkChat(model.get());
        model.reset();
        llama_backend_free();
        double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        std::cout << "{\"success\":true," << result << ",\"seconds\":" << seconds << "}\n";
        return 0;
    } catch (const std::exception & error) {
        std::cout << "{\"success\":false,\"summary\":" << jsonString(error.what()) << "}\n";
        return 1;
    }
}
