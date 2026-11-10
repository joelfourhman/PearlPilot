/* Driver API only: no CUDA toolkit, kernels, clocks or driver installation. */
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    void *lib = dlopen("libcuda.so.1", RTLD_NOW);
    if (!lib) { fprintf(stderr, "libcuda.so.1 unavailable: %s\n", dlerror()); return 2; }
    int (*init)(unsigned) = dlsym(lib, "cuInit");
    int (*count)(int *) = dlsym(lib, "cuDeviceGetCount");
    int (*name)(char *, int, int) = dlsym(lib, "cuDeviceGetName");
    int (*cap)(int *, int *, int) = dlsym(lib, "cuDeviceComputeCapability");
    int devices = 0, rc;
    if (!init || !count || !name || !cap) { fprintf(stderr, "NVIDIA driver API symbols missing\n"); return 3; }
    if ((rc = init(0)) || (rc = count(&devices)) || devices < 1) {
        fprintf(stderr, "CUDA initialization failed, code=%d, devices=%d\n", rc, devices); return 4;
    }
    for (int i = 0; i < devices; ++i) {
        char gpu[256] = {0}; int major = 0, minor = 0;
        if (name(gpu, sizeof gpu, i) || cap(&major, &minor, i)) return 5;
        printf("GPU %d: %s sm_%d%d\n", i, gpu, major, minor);
    }
    dlclose(lib);
    return 0;
}
