#include "model-cpu.h"
#include <initializer_list>

int main() {
    constexpr uint32_t features = (1u << 9) | (1u << 12) | (1u << 19) | (1u << 20) |
        (1u << 22) | (1u << 23) | (1u << 26) | (1u << 27) | (1u << 28) | (1u << 29);
    constexpr uint32_t scalar = (1u << 3) | (1u << 5) | (1u << 8);
    if (!model_x64_features(features, scalar, 6, 1u << 5)) return 1;
    for (int bit : {9, 12, 19, 20, 22, 23, 26, 27, 28, 29}) {
        if (model_x64_features(features & ~(1u << bit), scalar, 6, 1u << 5)) return 2;
    }
    for (int bit : {3, 5, 8}) {
        if (model_x64_features(features, scalar & ~(1u << bit), 6, 1u << 5)) return 3;
    }
    for (uint64_t state : {0, 2, 4}) {
        if (model_x64_features(features, scalar, state, 1u << 5)) return 4;
    }
    if (model_x64_features(features, scalar, 6, 0)) return 5;
    return 0;
}
