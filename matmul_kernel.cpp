#include <cstdint>

#ifdef __riscv // Guest RISC-V
    #define KERNEL_API extern "C" __attribute__((naked))

    typedef float float32_t;

    // Must use of RISC-V floating point with strict ordering
    static inline float32_t f32_mul(float32_t a, float32_t b) {
        float32_t r;
        asm volatile ("fmul.s %0, %1, %2, rne" : "=f"(r) : "f" (a), "f" (b));
        return r;
    }

    static inline float32_t f32_fma(float32_t a, float32_t b, float32_t c) {
        float32_t r;
        asm volatile ("fmadd.s %0, %1, %2, %3, rne" : "=f"(r) : "f" (a), "f" (b), "f" (c));
        return r;
    }

    static float32_t i32_to_f32(int32_t x) {
        float32_t r;
        asm volatile ("fcvt.s.w %0, %1, rne" : "=f"(r) : "r"(x));
        return r;
    }

    static inline void halt() {
        #define HTIF_START 0x40008000UL
        *(uint64_t*)(HTIF_START) = 1;
    }

#else // Host
    #include "soft-float.h"
    #define KERNEL_API extern "C"

    // Use the same software floating point implementation as the Cartesi Machine
    typedef uint32_t float32_t;

    static inline float32_t f32_mul(float32_t a, float32_t b) {
        uint32_t fflags;
        return cartesi::i_sfloat32::mul(a, b, FRM_RNE, &fflags);
    }

    static inline float32_t f32_fma(float32_t a, float32_t b, float32_t c) {
        uint32_t fflags;
        return cartesi::i_sfloat32::fma(a, b, c, FRM_RNE, &fflags);
    }

    static inline float32_t i32_to_f32(int32_t a) {
        uint32_t fflags;
        return cartesi::i_sfloat32::cvt_i_f<int32_t>(a, FRM_RNE, &fflags);
    }

    static void halt() {}
#endif

KERNEL_API void kernel_entry(
    float32_t* xout,
    int8_t *xq, float32_t *xs,
    int8_t *wq, float32_t *ws,
    uint64_t n, uint64_t d, uint64_t gs) {
    #pragma omp parallel for
    for (uint64_t i = 0; i < d; i++) {
        uint64_t in = i * n;
        float32_t sum = 0;
        for (uint64_t j = 0; j <= n - gs; j += gs) {
            int32_t ival = 0;
            for (uint64_t k = j; k < gs+j; k++) {
                ival += (int32_t)(xq[k]) * (int32_t)(wq[in + k]);
            }
            sum = f32_fma(i32_to_f32(ival), f32_mul(xs[j / gs], ws[(in  + j) / gs]), sum);
        }
        xout[i] = sum;
    }
    halt();
}
