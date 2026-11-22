#include "CDigUpWindows.h"
#if defined(__x86_64__)
#include <immintrin.h>
#include <intrin.h>

__attribute__((target("avx,f16c")))
static void expand(const uint16_t *src, float *dst, size_t count) {
    for (size_t i = 0; i < count; i += 8) {
        __m128i bits = _mm_loadu_si128((const __m128i *)(src + i));
        _mm256_storeu_ps(dst + i, _mm256_cvtph_ps(bits));
    }
}

static int has_f16c(void) {
    int regs[4];
    __cpuid(regs, 1);
    const int flags = (1 << 27) | (1 << 28) | (1 << 29);
    return (regs[2] & flags) == flags && (_xgetbv(0) & 6) == 6;
}
#endif

int digup_expand_half(const void *src, float *dst, size_t count) {
#if defined(__x86_64__)
    if (count % 8 == 0 && has_f16c()) {
        expand((const uint16_t *)src, dst, count);
        return 1;
    }
#endif
    return 0;
}
