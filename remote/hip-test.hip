// A small check that HIP builds and runs on this machine's GPUs (leasehold.ps1 hip-test).
// For each GPU it prints the properties, runs three kernels and checks every result against the CPU:
//   1. a vector add: one rounded add per element, compared exactly;
//   2. a SAXPY with fmaf: one fused multiply-add per element, compared exactly with std::fma;
//   3. a sum of integers: wavefront shuffles, shared memory and a 64-bit atomic.
// A wavefront is 32 lanes on RDNA (RX 7600, gfx1102) and 64 on CDNA (MI300X, gfx942). The sum reads
// warpSize rather than assuming either, so the same code is right on both.
// It also times the vector add for a rough memory bandwidth. Exit status 0 means every check passed.
#include <hip/hip_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK(call)                                                                   \
    do {                                                                              \
        hipError_t err_ = (call);                                                     \
        if (err_ != hipSuccess) {                                                     \
            std::fprintf(stderr, "%s:%d: %s failed: %s\n", __FILE__, __LINE__, #call, \
                         hipGetErrorString(err_));                                    \
            std::exit(2);                                                             \
        }                                                                             \
    } while (0)

__global__ void vector_add(const float* a, const float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

__global__ void saxpy(float alpha, const float* x, float* y, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = fmaf(alpha, x[i], y[i]);
}

// Each thread sums a strided share. Each wavefront then sums its lanes with shuffles, the
// wavefronts of a block meet in shared memory, and one atomic per block adds to the total.
__global__ void sum(const unsigned int* v, int n, unsigned long long* total) {
    __shared__ unsigned long long partial[1024 / 32];  // a slot per wavefront, at either size
    unsigned long long s = 0;
    for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += gridDim.x * blockDim.x) s += v[i];
    for (int offset = warpSize / 2; offset > 0; offset /= 2) s += __shfl_down(s, offset);
    if (threadIdx.x % warpSize == 0) partial[threadIdx.x / warpSize] = s;
    __syncthreads();
    if (threadIdx.x == 0) {
        unsigned long long block = 0;
        const int waves = (blockDim.x + warpSize - 1) / warpSize;
        for (int w = 0; w < waves; ++w) block += partial[w];
        atomicAdd(total, block);
    }
}

static int report(const char* what, long long bad, long long n) {
    if (bad == 0) std::printf("  %-36s ok\n", what);
    else std::printf("  %-36s FAILED: %lld of %lld wrong\n", what, bad, n);
    return bad != 0;
}

static int test_device(int dev) {
    CHECK(hipSetDevice(dev));
    hipDeviceProp_t p;
    CHECK(hipGetDeviceProperties(&p, dev));
    size_t free_bytes = 0, total_bytes = 0;
    CHECK(hipMemGetInfo(&free_bytes, &total_bytes));
    // On RDNA, HIP counts a work-group processor (two compute units) as one multiprocessor, so the
    // RX 7600's 32 compute units show as 16. On CDNA (MI300X) the two counts are the same.
    std::printf("GPU %d: %s (%s), %d multiprocessors, wavefront %d, %.1f GB of VRAM, %.1f GB free\n", dev,
                p.name, p.gcnArchName, p.multiProcessorCount, p.warpSize, total_bytes / 1e9,
                free_bytes / 1e9);

    // Three arrays of n floats, in at most a quarter of the free VRAM: the GPU may be serving a model.
    int n = 1 << 24;
    while (n > (1 << 18) && 3.0 * n * sizeof(float) > free_bytes / 4.0) n /= 2;
    const size_t bytes = size_t(n) * sizeof(float);
    const int threads = 256, blocks = (n + threads - 1) / threads;

    std::vector<float> a(n), b(n), c(n);
    for (int i = 0; i < n; ++i) {
        a[i] = float(i);
        b[i] = 2.0f * float(i);
    }
    float *da = nullptr, *db = nullptr, *dc = nullptr;
    CHECK(hipMalloc(&da, bytes));
    CHECK(hipMalloc(&db, bytes));
    CHECK(hipMalloc(&dc, bytes));
    CHECK(hipMemcpy(da, a.data(), bytes, hipMemcpyHostToDevice));
    CHECK(hipMemcpy(db, b.data(), bytes, hipMemcpyHostToDevice));
    int failed = 0;
    char what[64];

    // 1. i and 2i are exact in float up to 2^24, so the sum rounds once on each side, the same way.
    vector_add<<<blocks, threads>>>(da, db, dc, n);
    CHECK(hipGetLastError());
    CHECK(hipMemcpy(c.data(), dc, bytes, hipMemcpyDeviceToHost));
    long long bad = 0;
    for (int i = 0; i < n; ++i) bad += c[i] != 3.0f * float(i);
    std::snprintf(what, sizeof what, "vector add, %d floats", n);
    failed += report(what, bad, n);

    hipEvent_t start, stop;
    CHECK(hipEventCreate(&start));
    CHECK(hipEventCreate(&stop));
    const int reps = 20;
    CHECK(hipEventRecord(start));
    for (int r = 0; r < reps; ++r) vector_add<<<blocks, threads>>>(da, db, dc, n);
    CHECK(hipGetLastError());
    CHECK(hipEventRecord(stop));
    CHECK(hipEventSynchronize(stop));
    float ms = 0;
    CHECK(hipEventElapsedTime(&ms, start, stop));
    std::printf("  %-36s %.0f GB/s (%d runs, %.3f ms each)\n", "vector add, memory bandwidth",
                3.0 * bytes * reps / (ms / 1e3) / 1e9, reps, ms / reps);

    // 2. alpha * x isn't exact, so this checks the GPU fuses the multiply and the add, rounding once.
    const float alpha = 0.1f;
    saxpy<<<blocks, threads>>>(alpha, da, db, n);
    CHECK(hipGetLastError());
    CHECK(hipMemcpy(c.data(), db, bytes, hipMemcpyDeviceToHost));
    bad = 0;
    for (int i = 0; i < n; ++i) bad += c[i] != std::fma(alpha, a[i], b[i]);
    std::snprintf(what, sizeof what, "SAXPY with fmaf, %d floats", n);
    failed += report(what, bad, n);

    // 3. Varied values below 2^16, so the 64-bit total can't overflow.
    std::vector<unsigned int> v(n);
    unsigned long long expect = 0;
    for (int i = 0; i < n; ++i) {
        v[i] = (i * 2654435761u) >> 16;
        expect += v[i];
    }
    unsigned int* dv = reinterpret_cast<unsigned int*>(dc);  // n of them fit where n floats did
    unsigned long long* dtotal = nullptr;
    CHECK(hipMemcpy(dv, v.data(), bytes, hipMemcpyHostToDevice));
    CHECK(hipMalloc(&dtotal, sizeof *dtotal));
    CHECK(hipMemset(dtotal, 0, sizeof *dtotal));
    sum<<<std::min(blocks, 1024), threads>>>(dv, n, dtotal);
    CHECK(hipGetLastError());
    unsigned long long got = 0;
    CHECK(hipMemcpy(&got, dtotal, sizeof got, hipMemcpyDeviceToHost));
    std::snprintf(what, sizeof what, "sum of %d integers", n);
    failed += report(what, got != expect, 1);
    if (got != expect) std::printf("  expected %llu, got %llu\n", expect, got);

    CHECK(hipEventDestroy(start));
    CHECK(hipEventDestroy(stop));
    CHECK(hipFree(dtotal));
    CHECK(hipFree(da));
    CHECK(hipFree(db));
    CHECK(hipFree(dc));
    return failed;
}

int main() {
    int count = 0;
    hipError_t err = hipGetDeviceCount(&count);
    if (err != hipSuccess || count == 0) {
        std::fprintf(stderr, "HIP sees no GPU: %s\n", err != hipSuccess ? hipGetErrorString(err) : "none found");
        return 2;
    }
    int runtime = 0;
    CHECK(hipRuntimeGetVersion(&runtime));
    // Encoded as major * 10^7 + minor * 10^5 + patch.
    std::printf("HIP runtime %d.%d.%d, %d GPU%s\n", runtime / 10000000, runtime / 100000 % 100,
                runtime % 100000, count, count == 1 ? "" : "s");
    int failed = 0;
    for (int d = 0; d < count; ++d) failed += test_device(d);
    std::printf("%s\n", failed ? "HIP TEST FAILED" : "HIP TEST PASSED");
    return failed ? 1 : 0;
}
