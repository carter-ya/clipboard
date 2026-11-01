#include "llama.h"
#include "json.hpp"
#include "model-pin.h"
#include "model-cpu.h"
extern "C" {
#include "sha256.h"
}
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#else
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

using json = nlohmann::json;
static_assert(sizeof(void *) >= 8, "The bounded language worker requires a 64-bit target");
static constexpr size_t input_limit = 512 * 1024;
static constexpr size_t text_limit = 65536;
static constexpr int context_tokens = 4096;
static constexpr int generated_tokens = 192;
static constexpr int batch_tokens = 128;

static bool limits() {
#ifdef _WIN32
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (!job) return false;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};
    limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY |
        JOB_OBJECT_LIMIT_PROCESS_TIME | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    limit.ProcessMemoryLimit = SIZE_T(4) * 1024 * 1024 * 1024;
    limit.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 120LL * 10000000;
    // The owned job handle lives until this process exits. Closing a live job
    // early would kill the current worker before its bounded response is read.
    return SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limit, sizeof(limit)) &&
        AssignProcessToJobObject(job, GetCurrentProcess());
#else
    rlimit memory{4ULL * 1024 * 1024 * 1024, 4ULL * 1024 * 1024 * 1024};
    rlimit cpu{120, 121};
    rlimit core{0, 0};
    return setrlimit(RLIMIT_AS, &memory) == 0 && setrlimit(RLIMIT_CPU, &cpu) == 0 &&
        setrlimit(RLIMIT_CORE, &core) == 0;
#endif
}

static FILE *open_model(const std::string &path) {
    if (path.empty() || path.size() > 4096 || path.find('\0') != std::string::npos) return nullptr;
#ifdef _WIN32
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), int(path.size()), nullptr, 0);
    if (count < 3) return nullptr;
    std::wstring wide(size_t(count), L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), int(path.size()), wide.data(), count)) return nullptr;
    std::wstring local = wide;
    if (local.rfind(L"\\\\?\\", 0) == 0) local.erase(0, 4);
    if (local.size() < 3 || local[1] != L':' || (local[2] != L'\\' && local[2] != L'/')) return nullptr;
    wchar_t root[] = {local[0], L':', L'\\', L'\0'};
    UINT drive = GetDriveTypeW(root);
    if (drive != DRIVE_FIXED && drive != DRIVE_REMOVABLE && drive != DRIVE_RAMDISK) return nullptr;
    HANDLE handle = CreateFileW(wide.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return nullptr;
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(handle, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        ((uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow) != model_size) {
        CloseHandle(handle); return nullptr;
    }
    int fd = _open_osfhandle(reinterpret_cast<intptr_t>(handle), _O_BINARY | _O_RDONLY);
    if (fd == -1) { CloseHandle(handle); return nullptr; }
    FILE *file = _fdopen(fd, "rb");
    if (!file) _close(fd);
#else
    if (path[0] != '/' || path.rfind("//", 0) == 0) return nullptr;
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nullptr;
    struct stat info{};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || uint64_t(info.st_size) != model_size) {
        close(fd); return nullptr;
    }
    FILE *file = fdopen(fd, "rb");
    if (!file) close(fd);
#endif
    return file;
}

static bool verify_model(FILE *file) {
    sha256_t hash;
    sha256_init(&hash);
    std::array<unsigned char, 65536> buffer{};
    uint64_t total = 0;
    while (size_t count = fread(buffer.data(), 1, buffer.size(), file)) {
        total += count;
        if (total > model_size) return false;
        sha256_update(&hash, buffer.data(), count);
    }
    std::array<unsigned char, 32> digest{};
    sha256_final(&hash, digest.data());
    if (ferror(file) || total != model_size || memcmp(digest.data(), model_sha256, digest.size())) return false;
#ifdef _WIN32
    return _fseeki64(file, 0, SEEK_SET) == 0;
#else
    return fseeko(file, 0, SEEK_SET) == 0;
#endif
}

static std::vector<llama_token> tokenize(const llama_vocab *vocab, const std::string &text, bool special) {
    int n = -llama_tokenize(vocab, text.data(), int(text.size()), nullptr, 0, false, special);
    if (n <= 0 || n > 65536) throw 1;
    std::vector<llama_token> tokens(size_t(n), 0);
    if (llama_tokenize(vocab, text.data(), int(text.size()), tokens.data(), n, false, special) != n) throw 1;
    return tokens;
}

static std::string generate(llama_model *model, const std::string &text,
                            const std::string &language, bool &truncated) {
    const llama_vocab *vocab = llama_model_get_vocab(model);
    std::string instruction = "Write one concise sentence summarizing the input's main point, not merely its opening. Keep it under 160 characters. Return only the sentence, without preamble, quotations, bullets or reasoning. Reply in " + language + ".";
    std::string task_prompt = "Summarize the main point of the following source in one sentence. Preserve facts, event order, purposes and plans. Do not turn a purpose into a completed action. For example, 'The shop closed early to repair its heater' means it closed FOR repairs, not AFTER repairs were completed. Do not invent details. Reply in " + language + ".\n<source>\n";
    if (language == "Simplified Chinese") task_prompt = u8"请用简体中文写一句摘要，概括以下内容的核心意思。保留原文事实，不要编造信息。只输出摘要。\n<source>\n";
    if (language == "Traditional Chinese") task_prompt = u8"請用繁體中文寫一句摘要，概括以下內容的核心意思。保留原文事實，不要編造資訊。只輸出摘要。\n<source>\n";
    if (language == "Japanese") task_prompt = u8"次の内容の要点を日本語の一文で要約してください。原文の事実を保ち、情報を付け加えないでください。要約だけを出力してください。\n<source>\n";
    if (language == "Korean") task_prompt = u8"다음 내용의 핵심을 한국어 한 문장으로 요약하세요. 원문의 사실을 유지하고 새로운 정보를 추가하지 마세요. 요약만 출력하세요.\n<source>\n";
    if (language == "German") task_prompt = u8"Fasse den Hauptinhalt der folgenden Quelle in einem deutschen Satz zusammen. Bewahre die Fakten, erfinde keine Details und gib nur die Zusammenfassung aus.\n<source>\n";
    if (language == "Spanish") task_prompt = u8"Resume la idea principal del siguiente texto en una sola frase en español. Conserva los hechos, no inventes detalles y devuelve solo el resumen.\n<source>\n";
    auto prompt = tokenize(vocab, "<|im_start|>system\n" + instruction + "<|im_end|>\n<|im_start|>user\n" + task_prompt, true);
    auto content = tokenize(vocab, text, false);
    auto tail = tokenize(vocab, "\n</source><|im_end|>\n<|im_start|>assistant\n", true);
    if (prompt.size() + tail.size() + generated_tokens >= context_tokens) throw 1;
    size_t maximum = context_tokens - generated_tokens - prompt.size() - tail.size();
    truncated = content.size() > maximum;
    if (truncated) content.resize(maximum);
    prompt.insert(prompt.end(), content.begin(), content.end());
    prompt.insert(prompt.end(), tail.begin(), tail.end());
    llama_context_params parameters = llama_context_default_params();
    parameters.n_ctx = context_tokens;
    parameters.n_batch = batch_tokens;
    parameters.n_ubatch = batch_tokens;
    parameters.n_threads = 2;
    parameters.n_threads_batch = 2;
    parameters.no_perf = true;
    std::unique_ptr<llama_context, decltype(&llama_free)> context(llama_init_from_model(model, parameters), llama_free);
    if (!context) throw 1;
    std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)> batch(llama_batch_ext_init(context.get()), llama_batch_ext_free);
    if (!batch) throw 1;
    for (size_t start = 0; start < prompt.size(); start += batch_tokens) {
        llama_batch_ext_clear(batch.get());
        size_t count = std::min(size_t(batch_tokens), prompt.size() - start);
        for (size_t i = 0; i < count; ++i) {
            int index = llama_batch_ext_add_token(batch.get(), 0, prompt[start + i]);
            llama_pos position = llama_pos(start + i);
            if (index < 0 || !llama_batch_ext_set_pos(batch.get(), index, &position)) throw 1;
            if (start + i + 1 == prompt.size()) llama_batch_ext_set_output_logits(batch.get(), index, true);
        }
        if (llama_process(context.get(), LLAMA_PROCESS_TYPE_DECODE, batch.get())) throw 1;
    }
    llama_sampler_chain_params sample_parameters = llama_sampler_chain_default_params();
    sample_parameters.no_perf = true;
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(sample_parameters), llama_sampler_free);
    if (!sampler) throw 1;
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.8f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(42));
    std::string output;
    for (int i = 0; i < generated_tokens; ++i) {
        llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        char bytes[256];
        int count = llama_token_to_piece(vocab, token, bytes, sizeof(bytes), 0, false);
        if (count <= 0 || count > int(sizeof(bytes)) || output.size() + size_t(count) > 2048) throw 1;
        output.append(bytes, size_t(count));
        if (output.find_first_not_of(" \t\r\n") != std::string::npos && output.find('\n', output.find_first_not_of(" \t\r\n")) != std::string::npos) break;
        llama_batch_ext_clear(batch.get());
        int index = llama_batch_ext_add_token(batch.get(), 0, token);
        llama_pos position = llama_pos(prompt.size() + size_t(i));
        if (index < 0 || !llama_batch_ext_set_pos(batch.get(), index, &position)) throw 1;
        llama_batch_ext_set_output_logits(batch.get(), index, true);
        if (llama_process(context.get(), LLAMA_PROCESS_TYPE_DECODE, batch.get())) throw 1;
    }
    return output;
}

int main() {
    if (!model_cpu_supported()) return 11;
    if (!limits()) return 3;
    int stage = 4;
    // No SDK diagnostics, prompts, paths or generated text enter stderr logs.
    llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    try {
        std::string bytes;
        std::array<char, 8192> chunk{};
        while (size_t count = fread(chunk.data(), 1, chunk.size(), stdin)) {
            if (bytes.size() + count > input_limit) return 2;
            bytes.append(chunk.data(), count);
        }
        if (ferror(stdin) || bytes.empty()) return 2;
        stage = 5;
        json request = json::parse(bytes, [](int depth, json::parse_event_t, json &) {
            if (depth > 8) throw 1;
            return true;
        });
        if (!request.is_object() || request.size() < 3 || request.size() > 4) return 2;
        for (auto entry = request.begin(); entry != request.end(); ++entry) {
            if (entry.key() != "model" && entry.key() != "text" && entry.key() != "task" && entry.key() != "language") return 2;
        }
        std::string path = request.at("model").get<std::string>();
        std::string text = request.at("text").get<std::string>();
        std::string task = request.at("task").get<std::string>();
        std::string language = !request.contains("language") || request.at("language").is_null()
            ? "English" : request.at("language").get<std::string>();
        if (language.empty() || language.size() > 96 || std::any_of(language.begin(), language.end(), [](unsigned char c) {
            return c < 32 || c == 127 || c == '<' || c == '>' || c == '"' || c == '\\' || c == '{' || c == '}';
        })) return 2;
        if (text.empty() || text.size() > text_limit || task != "summary") return 2;
        std::unique_ptr<FILE, decltype(&fclose)> file(open_model(path), fclose);
        if (!file) return 6;
        if (!verify_model(file.get())) return 7;
        stage = 8;
        llama_backend_init();
        llama_model_params parameters = llama_model_default_params();
        parameters.n_gpu_layers = 0;
        parameters.use_extra_bufts = false;
        parameters.load_mode = LLAMA_LOAD_MODE_MMAP;
        parameters.lazy_mode = LLAMA_LAZY_MODE_OFF;
        std::unique_ptr<llama_model, decltype(&llama_model_free)> model(llama_model_load_from_file_ptr(file.get(), parameters), llama_model_free);
        if (!model) return 8;
        stage = 9;
        bool truncated = false;
        std::string output = generate(model.get(), text, language, truncated);
        json response{{"task", task}, {"summary", nullptr}, {"language", nullptr},
                      {"entities", json::array()}, {"inputTruncated", truncated}};
        if (output.find_first_not_of(" \t\r\n") == std::string::npos) return 9;
        stage = 10;
        response["summary"] = output;
        std::string serialized = response.dump();
        if (serialized.size() > 4096 || fwrite(serialized.data(), 1, serialized.size(), stdout) != serialized.size() || fflush(stdout)) return 2;
        return 0;
    } catch (...) { return stage; }
}
