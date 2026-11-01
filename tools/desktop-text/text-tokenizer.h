// Cased BERT normalization follows huggingface/tokenizers v0.22.1 (Apache-2.0).
// This C++ implementation adds bounded input, source UTF-8 spans and literal
// handling of copied special-token text. Full attribution is packaged.
#pragma once
#include "unicode.h"
#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace clipboard_text {
struct Piece {
    int64_t id;
    size_t start, end;
};
struct Encoding {
    std::vector<Piece> pieces;
    bool truncated = false;
};
struct Character {
    std::string bytes;
    size_t start, end;
};

// Cased BERT normalization/WordPiece. Keep offsets in the original UTF-8
// source, including when normalization removes a control character. Literal
// [CLS]/[SEP] in copied text are ordinary punctuation/letters, never controls.
class Tokenizer {
    std::unordered_map<std::string, int64_t> vocabulary;
    static bool chinese(uint32_t value) {
        return (value >= 0x4e00 && value <= 0x9fff) || (value >= 0x3400 && value <= 0x4dbf) ||
            (value >= 0x20000 && value <= 0x2a6df) || (value >= 0x2a700 && value <= 0x2b73f) ||
            (value >= 0x2b740 && value <= 0x2b81f) || (value >= 0x2b920 && value <= 0x2ceaf) ||
            (value >= 0xf900 && value <= 0xfaff) || (value >= 0x2f800 && value <= 0x2fa1f);
    }
    static bool ascii_punctuation(uint32_t value) {
        return (value >= 33 && value <= 47) || (value >= 58 && value <= 64) ||
            (value >= 91 && value <= 96) || (value >= 123 && value <= 126);
    }
    std::vector<Piece> word(const std::vector<Character> &characters) const {
        std::vector<Piece> result;
        if (characters.size() <= 100) {
            size_t start = 0;
            while (start < characters.size()) {
                bool found = false;
                for (size_t end = characters.size(); end > start; --end) {
                    std::string candidate = start ? "##" : "";
                    for (size_t i = start; i < end; ++i) candidate += characters[i].bytes;
                    auto entry = vocabulary.find(candidate);
                    if (entry == vocabulary.end()) continue;
                    result.push_back({entry->second, characters[start].start, characters[end - 1].end});
                    start = end;
                    found = true;
                    break;
                }
                if (!found) { result.clear(); break; }
            }
        }
        if (result.empty()) result.push_back({100, characters.front().start, characters.back().end});
        return result;
    }
public:
    explicit Tokenizer(const std::string &data) {
        std::istringstream input(data);
        std::string line;
        int64_t index = 0;
        while (std::getline(input, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty() || !vocabulary.emplace(line, index++).second) throw 1;
        }
        if (vocabulary.size() != 119547 || vocabulary.at("[UNK]") != 100 ||
            vocabulary.at("[CLS]") != 101 || vocabulary.at("[SEP]") != 102) throw 1;
    }
    Encoding encode(const std::string &text) const {
        Encoding result{{{101, 0, 0}}, false};
        std::vector<Character> current;
        auto flush = [&]() {
            if (current.empty()) return;
            auto values = word(current);
            for (const auto &piece : values) {
                if (result.pieces.size() >= 511) { result.truncated = true; break; }
                result.pieces.push_back(piece);
            }
            current.clear();
        };
        for (size_t offset = 0; offset < text.size();) {
            size_t start = offset;
            uint32_t value = unicode_cpt_from_utf8(text, offset);
            auto flags = unicode_cpt_flags_from_cpt(value);
            if (value == 0 || value == 0xfffd ||
                ((flags.is_control || flags.is_undefined) && value != 9 && value != 10 && value != 13)) continue;
            if (flags.is_whitespace || value == 9 || value == 10 || value == 13) { flush(); continue; }
            bool isolated = chinese(value) || ascii_punctuation(value) || flags.is_punctuation;
            if (isolated) flush();
            current.push_back({text.substr(start, offset - start), start, offset});
            if (isolated) flush();
            if (result.truncated) break;
        }
        if (!result.truncated) flush();
        result.pieces.push_back({102, 0, 0});
        return result;
    }
};
} // namespace clipboard_text
