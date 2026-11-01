// Local trained language identification and named-entity recognition.
#include "json.hpp"
#include "fasttext.h"
#include "onnxruntime_c_api.h"
#include "text-tokenizer.h"
#include "text-pins.h"
#include "script-characters.h"
extern "C" {
#include "sha256.h"
}
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <memory>
#include <set>
#include <sstream>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
using NativePath = std::wstring;
#else
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
using NativePath = std::string;
#endif
using json = nlohmann::json;
static_assert(sizeof(void *) >= 8, "The bounded text worker requires a 64-bit target");

static bool limits() {
#ifdef _WIN32
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    if (_setmode(_fileno(stdin), _O_BINARY) == -1 || _setmode(_fileno(stdout), _O_BINARY) == -1) return false;
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (!job) return false;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY |
        JOB_OBJECT_LIMIT_PROCESS_TIME | JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    info.ProcessMemoryLimit = SIZE_T(2) * 1024 * 1024 * 1024;
    info.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 15LL * 10000000;
    return SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info)) &&
        AssignProcessToJobObject(job, GetCurrentProcess());
#else
    rlimit memory{2ULL * 1024 * 1024 * 1024, 2ULL * 1024 * 1024 * 1024}, cpu{15, 16}, core{0, 0};
    return setrlimit(RLIMIT_AS, &memory) == 0 && setrlimit(RLIMIT_CPU, &cpu) == 0 &&
        setrlimit(RLIMIT_CORE, &core) == 0;
#endif
}

static NativePath native_path(const std::string &text) {
    if (text.empty() || text.size() > 4096 || text.find('\0') != std::string::npos) throw 1;
#ifdef _WIN32
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), nullptr, 0);
    if (count <= 0) throw 1;
    std::wstring path(size_t(count), L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), path.data(), count)) throw 1;
    return path;
#else
    return text;
#endif
}

#ifdef _WIN32
static bool local_drive(NativePath path) {
    if (path.rfind(L"\\\\?\\", 0) == 0) path.erase(0, 4);
    if (path.size() < 3 || path[1] != L':' || (path[2] != L'\\' && path[2] != L'/')) return false;
    wchar_t root[] = {path[0], L':', L'\\', L'\0'};
    UINT drive = GetDriveTypeW(root);
    return drive == DRIVE_FIXED || drive == DRIVE_REMOVABLE || drive == DRIVE_RAMDISK;
}
#endif

static std::vector<unsigned char> verified_file(const NativePath &path, size_t size, const unsigned char *expected) {
    FILE *raw = nullptr;
#ifdef _WIN32
    if (!local_drive(path)) throw 1;
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (handle == INVALID_HANDLE_VALUE) throw 1;
    BY_HANDLE_FILE_INFORMATION info{};
    std::array<wchar_t, 32768> final_path{};
    DWORD length = GetFinalPathNameByHandleW(handle, final_path.data(), DWORD(final_path.size()), FILE_NAME_NORMALIZED);
    if (!GetFileInformationByHandle(handle, &info) || GetFileType(handle) != FILE_TYPE_DISK ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        ((uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow) != size ||
        !length || length >= final_path.size() || !local_drive(NativePath(final_path.data(), length))) {
        CloseHandle(handle); throw 1;
    }
    int fd = _open_osfhandle(reinterpret_cast<intptr_t>(handle), _O_BINARY | _O_RDONLY);
    if (fd == -1) { CloseHandle(handle); throw 1; }
    raw = _fdopen(fd, "rb");
    if (!raw) _close(fd);
#else
    if (path.empty() || path[0] != '/' || path.rfind("//", 0) == 0) throw 1;
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) throw 1;
    struct stat info{};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || uint64_t(info.st_size) != size) { close(fd); throw 1; }
    raw = fdopen(fd, "rb");
    if (!raw) close(fd);
#endif
    std::unique_ptr<FILE, decltype(&fclose)> file(raw, fclose);
    if (!file) throw 1;
    std::vector<unsigned char> bytes(size);
    sha256_t hash;
    sha256_init(&hash);
    for (size_t start = 0; start < size;) {
        size_t count = fread(bytes.data() + start, 1, std::min(size_t(65536), size - start), file.get());
        if (!count) throw 1;
        sha256_update(&hash, bytes.data() + start, count);
        start += count;
    }
    std::array<unsigned char, 32> digest{};
    sha256_final(&hash, digest.data());
    if (ferror(file.get()) || fgetc(file.get()) != EOF || memcmp(digest.data(), expected, digest.size())) throw 1;
    return bytes;
}

static NativePath asset_path(const char *name) {
#ifdef _WIN32
    std::array<wchar_t, 32768> buffer{};
    DWORD count = GetModuleFileNameW(nullptr, buffer.data(), DWORD(buffer.size()));
    if (!count || count >= buffer.size()) throw 1;
    NativePath executable(buffer.data(), count);
    size_t end = executable.find_last_of(L"\\/");
    if (end == NativePath::npos) throw 1;
#else
    std::array<char, 65536> buffer{};
    ssize_t count = readlink("/proc/self/exe", buffer.data(), buffer.size());
    if (count <= 0 || size_t(count) >= buffer.size()) throw 1;
    NativePath executable(buffer.data(), size_t(count));
    size_t end = executable.find_last_of('/');
    if (end == NativePath::npos) throw 1;
#endif
    return executable.substr(0, end + 1) + native_path(name);
}

static std::string language(const std::string &text) {
    auto bytes = verified_file(asset_path("clipboard-language-id.ftz"), language_size, language_sha256);
    std::istringstream model(std::string(bytes.begin(), bytes.end()), std::ios::binary);
    class VerifiedIdentifier final : public fasttext::FastText {
    public:
        void load(std::istream &input) {
            // The public stream overload expects the signature/version to
            // have been consumed by checkModel (as the filename overload does).
            if (!checkModel(input)) throw 1;
            fasttext::FastText::loadModel(input);
        }
    } identifier;
    identifier.load(model);
    std::string flattened;
    for (size_t offset = 0; offset < text.size();) {
        size_t start = offset;
        uint32_t value = unicode_cpt_from_utf8(text, offset);
        auto flags = unicode_cpt_flags_from_cpt(value);
        // Newlines/angle delimiters cannot terminate the private model's line
        // or inject its literal </s> token. They carry no language evidence.
        if (flags.is_whitespace || value == '<' || value == '>') flattened += ' ';
        else if (!flags.is_control && !flags.is_undefined) flattened += text.substr(start, offset - start);
    }
    std::istringstream input(flattened);
    std::vector<std::pair<fasttext::real, std::string>> predictions;
    identifier.predictLine(input, predictions, 1, 0.5f);
    if (predictions.empty() || !std::isfinite(predictions[0].first)) return "und";
    auto code = predictions[0].second;
    if (code.rfind("__label__", 0) != 0) throw 1;
    code.erase(0, 9);
    if (code.size() < 2 || code.size() > 3 || !std::all_of(code.begin(), code.end(), [](char c) { return c >= 'a' && c <= 'z'; })) throw 1;
    if (code == "zh") {
        size_t traditional = 0, simplified = 0;
        for (uint32_t value : unicode_cpts_from_utf8(text)) {
            traditional += std::binary_search(std::begin(traditional_chars), std::end(traditional_chars), value);
            simplified += std::binary_search(std::begin(simplified_chars), std::end(simplified_chars), value);
        }
        code = traditional > simplified ? "zh-Hant" : "zh-Hans";
    }
    return code;
}

static std::vector<float> infer(const std::vector<unsigned char> &model, const clipboard_text::Encoding &encoded) {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) throw 1;
    auto check = [&](OrtStatus *status) { if (status) { api->ReleaseStatus(status); throw 1; } };
    OrtEnv *raw_env = nullptr;
    check(api->CreateEnvWithCustomLogger([](void *, OrtLoggingLevel, const char *, const char *, const char *, const char *) {}, nullptr,
        ORT_LOGGING_LEVEL_FATAL, "clipboard-text", &raw_env));
    std::unique_ptr<OrtEnv, decltype(api->ReleaseEnv)> env(raw_env, api->ReleaseEnv);
    check(api->DisableTelemetryEvents(env.get()));
    OrtSessionOptions *raw_options = nullptr;
    check(api->CreateSessionOptions(&raw_options));
    std::unique_ptr<OrtSessionOptions, decltype(api->ReleaseSessionOptions)> options(raw_options, api->ReleaseSessionOptions);
    check(api->SetSessionExecutionMode(options.get(), ORT_SEQUENTIAL));
    check(api->SetIntraOpNumThreads(options.get(), 2));
    check(api->SetInterOpNumThreads(options.get(), 1));
    check(api->DisableCpuMemArena(options.get()));
    check(api->DisableMemPattern(options.get()));
    check(api->SetSessionGraphOptimizationLevel(options.get(), ORT_ENABLE_EXTENDED));
    OrtSession *raw_session = nullptr;
    // Only verified in-memory ONNX bytes: no model paths, external data,
    // custom operators or non-CPU execution providers reach the runtime.
    check(api->CreateSessionFromArray(env.get(), model.data(), model.size(), options.get(), &raw_session));
    std::unique_ptr<OrtSession, decltype(api->ReleaseSession)> session(raw_session, api->ReleaseSession);
    size_t input_count = 0, output_count = 0;
    check(api->SessionGetInputCount(session.get(), &input_count));
    check(api->SessionGetOutputCount(session.get(), &output_count));
    if (input_count != 3 || output_count != 1) throw 1;
    OrtMemoryInfo *raw_memory = nullptr;
    check(api->CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &raw_memory));
    std::unique_ptr<OrtMemoryInfo, decltype(api->ReleaseMemoryInfo)> memory(raw_memory, api->ReleaseMemoryInfo);
    std::array<std::vector<int64_t>, 3> inputs;
    for (const auto &piece : encoded.pieces) inputs[0].push_back(piece.id);
    inputs[1].assign(encoded.pieces.size(), 1);
    inputs[2].assign(encoded.pieces.size(), 0);
    const int64_t dimensions[] = {1, int64_t(encoded.pieces.size())};
    std::vector<std::unique_ptr<OrtValue, decltype(api->ReleaseValue)>> values;
    std::array<const OrtValue *, 3> pointers{};
    for (size_t i = 0; i < inputs.size(); ++i) {
        OrtValue *value = nullptr;
        check(api->CreateTensorWithDataAsOrtValue(memory.get(), inputs[i].data(), inputs[i].size() * sizeof(int64_t),
            dimensions, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &value));
        values.emplace_back(value, api->ReleaseValue);
        pointers[i] = value;
    }
    const char *names[] = {"input_ids", "attention_mask", "token_type_ids"}, *outputs[] = {"logits"};
    OrtValue *raw_output = nullptr;
    check(api->Run(session.get(), nullptr, names, pointers.data(), pointers.size(), outputs, 1, &raw_output));
    std::unique_ptr<OrtValue, decltype(api->ReleaseValue)> output(raw_output, api->ReleaseValue);
    OrtTensorTypeAndShapeInfo *raw_shape = nullptr;
    check(api->GetTensorTypeAndShape(output.get(), &raw_shape));
    std::unique_ptr<OrtTensorTypeAndShapeInfo, decltype(api->ReleaseTensorTypeAndShapeInfo)> shape(raw_shape, api->ReleaseTensorTypeAndShapeInfo);
    size_t dimensions_count = 0;
    ONNXTensorElementDataType type;
    std::array<int64_t, 3> actual{};
    check(api->GetDimensionsCount(shape.get(), &dimensions_count));
    check(api->GetTensorElementType(shape.get(), &type));
    if (dimensions_count != 3 || type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) throw 1;
    check(api->GetDimensions(shape.get(), actual.data(), actual.size()));
    if (actual[0] != 1 || actual[1] != dimensions[1] || actual[2] != 9) throw 1;
    float *scores = nullptr;
    check(api->GetTensorMutableData(output.get(), reinterpret_cast<void **>(&scores)));
    if (!scores) throw 1;
    std::vector<float> result(scores, scores + encoded.pieces.size() * 9);
    if (!std::all_of(result.begin(), result.end(), [](float v) { return std::isfinite(v); })) throw 1;
    return result;
}

static std::vector<std::string> entities(const std::string &text, const clipboard_text::Encoding &encoded,
                                        const std::vector<float> &scores) {
    std::vector<std::string> result;
    std::set<std::string> seen;
    size_t start = 0, end = 0;
    int current = 0;
    auto finish = [&](bool incomplete = false) {
        if (current && !incomplete && end > start && end - start <= 512) {
            std::string value = text.substr(start, end - start);
            auto points = unicode_cpts_from_utf8(value);
            bool control = std::any_of(points.begin(), points.end(), [](uint32_t c) { return unicode_cpt_flags_from_cpt(c).is_control; });
            if (!control && points.size() <= 128 && seen.insert(value).second && result.size() < 5) result.push_back(value);
        }
        current = 0;
    };
    for (size_t i = 1; i + 1 < encoded.pieces.size(); ++i) {
        const float *values = scores.data() + i * 9;
        int label = int(std::max_element(values, values + 9) - values);
        double denominator = 0;
        for (size_t j = 0; j < 9; ++j) denominator += std::exp(double(values[j]) - values[label]);
        double confidence = 1 / denominator;
        const auto &piece = encoded.pieces[i];
        // DATE/Outside are intentionally excluded from the Mac-equivalent
        // person/place/organization contract. Incomplete final names are omitted.
        if (label < 3 || confidence < 0.7 || piece.end <= piece.start) { finish(); continue; }
        int kind = (label - 3) / 2 + 1;
        bool beginning = label % 2 == 1;
        if (beginning || kind != current) { finish(); current = kind; start = piece.start; }
        end = piece.end;
    }
    finish(encoded.truncated);
    return result;
}

int main() {
    if (!limits()) return 2;
    try {
        std::string bytes;
        std::array<char, 8192> buffer{};
        while (size_t count = fread(buffer.data(), 1, buffer.size(), stdin)) {
            if (bytes.size() + count > 512 * 1024) return 2;
            bytes.append(buffer.data(), count);
        }
        if (ferror(stdin) || bytes.empty()) return 2;
        json input = json::parse(bytes, [](int depth, json::parse_event_t, json &) { if (depth > 8) throw 1; return true; });
        if (input.is_object() && input.size() == 1 && input.value("task", "") == "capability") {
            verified_file(asset_path("clipboard-text-vocab.txt"), vocabulary_size, vocabulary_sha256);
            language("A private synthetic capability check.");
            const char response[] = "{\"available\":true}";
            return fwrite(response, 1, sizeof(response) - 1, stdout) == sizeof(response) - 1 && !fflush(stdout) ? 0 : 2;
        }
        if (!input.is_object() || input.size() != 3 || !input.contains("text") || !input.contains("task") || !input.contains("model")) return 2;
        std::string text = input.at("text").get<std::string>();
        if (text.empty() || text.size() > 65536 || input.at("task").get<std::string>() != "enrichment") return 2;
        json found = json::array();
        bool truncated = false;
        if (!input.at("model").is_null()) {
            auto model = verified_file(native_path(input.at("model").get<std::string>()), entity_size, entity_sha256);
            auto vocabulary = verified_file(asset_path("clipboard-text-vocab.txt"), vocabulary_size, vocabulary_sha256);
            clipboard_text::Tokenizer tokenizer(std::string(vocabulary.begin(), vocabulary.end()));
            auto encoded = tokenizer.encode(text);
            truncated = encoded.truncated;
            found = entities(text, encoded, infer(model, encoded));
        }
        auto code = language(text);
        json output{{"task", "enrichment"}, {"summary", nullptr}, {"language", code == "und" ? json(nullptr) : json(code)},
                    {"entities", found}, {"inputTruncated", truncated}};
        auto encoded = output.dump();
        if (encoded.size() > 4096 || fwrite(encoded.data(), 1, encoded.size(), stdout) != encoded.size() || fflush(stdout)) return 2;
        return 0;
    } catch (...) { return 2; }
}
