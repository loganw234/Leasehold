// A small HIP check: prints the GPU's properties, then adds two vectors on it and checks every result.
// The wavefront size it prints is 32 on RDNA (RX 7600, gfx1102) and 64 on CDNA (MI300X, gfx942),
// so portable kernels read warpSize instead of assuming one or the other.
#include <hip/hip_runtime.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK(call)                                                                  \
    do {                                                                             \
        hipError_t err_ = (call);                                                    \
        if (err_ != hipSuccess) {                                                    \
            std::fprintf(stderr, "%s:%d %s failed: %s\n", __FILE__, __LINE__, #call, \
                         hipGetErrorString(err_));                                   \
            std::exit(1);                                                            \
        }                                                                            \
    } while (0)

__global__ void add(const float* a, const float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    hipDeviceProp_t prop;
    CHECK(hipGetDeviceProperties(&prop, 0));
    std::printf("device: %s (%s), %d compute units, wavefront size %d, %.1f GB\n", prop.name,
                prop.gcnArchName, prop.multiProcessorCount, prop.warpSize,
                prop.totalGlobalMem / 1e9);

    const int n = 1 << 24;
    const size_t bytes = n * sizeof(float);
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

    add<<<(n + 255) / 256, 256>>>(da, db, dc, n);
    CHECK(hipGetLastError());
    CHECK(hipDeviceSynchronize());
    CHECK(hipMemcpy(c.data(), dc, bytes, hipMemcpyDeviceToHost));

    // i and 2i are exact in float, so the GPU's one rounded add must equal the host's 3.0f * i.
    int bad = 0;
    for (int i = 0; i < n; ++i) {
        if (c[i] != 3.0f * float(i)) ++bad;
    }
    std::printf("vector add of %d floats: %s\n", n, bad ? "FAILED" : "ok");

    CHECK(hipFree(da));
    CHECK(hipFree(db));
    CHECK(hipFree(dc));
    return bad ? 1 : 0;
}
