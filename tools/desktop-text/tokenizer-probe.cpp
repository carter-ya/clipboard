// Test-only executable. Never included in the application package.
#include "text-tokenizer.h"
#include "json.hpp"
#include <fstream>
#include <iostream>
#include <iterator>
int main(int argc, char **argv) {
    try {
        if (argc != 2) return 2;
        std::ifstream vocabulary(argv[1], std::ios::binary);
        if (!vocabulary) return 2;
        std::string bytes((std::istreambuf_iterator<char>(vocabulary)), {});
        clipboard_text::Tokenizer tokenizer(bytes);
        nlohmann::json input;
        std::cin >> input;
        if (!input.is_array()) return 2;
        nlohmann::json results = nlohmann::json::array();
        for (const auto &item : input) {
            std::string text = item.get<std::string>();
            if (text.size() > 65536) return 2;
            auto encoded = tokenizer.encode(text);
            nlohmann::json pieces = nlohmann::json::array();
            for (const auto &piece : encoded.pieces) pieces.push_back({piece.id, piece.start, piece.end});
            results.push_back({{"pieces", pieces}, {"truncated", encoded.truncated}});
        }
        std::cout << results.dump();
        return 0;
    } catch (...) { return 2; }
}
