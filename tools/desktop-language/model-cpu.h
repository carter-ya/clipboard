#pragma once
#include <cstdint>
#if defined(_M_X64)
#include <intrin.h>
#elif defined(__x86_64__)
#include <cpuid.h>
#endif

// The application and this entry point retain their baseline ISA. Only GGML's
// x64 kernels use AVX2; refuse them before any SDK initialization if unavailable.
inline bool model_x64_features(uint32_t ecx, uint32_t ebx, uint64_t xcr0, uint32_t extended) {
    constexpr uint32_t needed = (1u << 9) | (1u << 12) | (1u << 19) | (1u << 20) |
        (1u << 22) | (1u << 23) | (1u << 26) | (1u << 27) | (1u << 28) | (1u << 29);
    // MSVC /arch:AVX2 may also emit BMI instructions. Require the full
    // associated x86-64-v3 scalar feature set, including LZCNT and MOVBE.
    constexpr uint32_t needed_ebx = (1u << 3) | (1u << 5) | (1u << 8);
    return (ecx & needed) == needed && (ebx & needed_ebx) == needed_ebx &&
        (extended & (1u << 5)) != 0 && (xcr0 & 6) == 6;
}

inline bool model_cpu_supported() {
#if defined(_M_X64)
    int info[4]{};
    __cpuid(info, 0);
    if (info[0] < 7) return false;
    __cpuidex(info, 1, 0);
    uint32_t ecx = uint32_t(info[2]);
    if (!(ecx & (1u << 27))) return false;
    uint64_t state = _xgetbv(0);
    __cpuidex(info, 7, 0);
    uint32_t ebx = uint32_t(info[1]);
    __cpuid(info, int(0x80000000u));
    if (uint32_t(info[0]) < 0x80000001u) return false;
    __cpuid(info, int(0x80000001u));
    return model_x64_features(ecx, ebx, state, uint32_t(info[2]));
#elif defined(__x86_64__)
    unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
    if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx) || !(ecx & (1u << 27))) return false;
    uint32_t low = 0, high = 0;
    __asm__ volatile("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
    uint32_t features = ecx;
    if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx)) return false;
    uint32_t scalar = ebx;
    if (!__get_cpuid(0x80000001u, &eax, &ebx, &ecx, &edx)) return false;
    return model_x64_features(features, scalar, (uint64_t(high) << 32) | low, ecx);
#else
    return true;
#endif
}
