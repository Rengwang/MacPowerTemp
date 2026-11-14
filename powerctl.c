/* powerctl.c — Privileged helper for MacPowerTemp power capping & Ultra Low Power Mode */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const int64_t Q24_SCALE = 16777216LL;

static io_service_t find_clpc(void) {
    return IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"));
}

static io_service_t find_agx(void) {
    const char *classes[] = {
        "AGXAcceleratorG17G", "AGXAcceleratorG17X", "AGXAcceleratorG16G",
        "AGXAcceleratorG15X", "AGXAcceleratorG15G", "AGXAcceleratorG14X",
        "AGXAcceleratorG13G", "AGXAccelerator", NULL
    };
    for (int i = 0; classes[i]; i++) {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(classes[i]));
        if (svc) return svc;
    }
    return 0;
}

static int set_clpc_pkg_target(int64_t raw_val) {
    io_service_t clpc = find_clpc();
    if (!clpc) {
        fprintf(stderr, "AppleCLPC service not found\n");
        return 1;
    }
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &raw_val);
    CFDictionarySetValue(dict, CFSTR("`pkg-avg-therm-power-target"), num);
    kern_return_t kr = IORegistryEntrySetCFProperties(clpc, dict);
    CFRelease(num);
    CFRelease(dict);
    IOObjectRelease(clpc);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "AppleCLPC write failed: 0x%x\n", kr);
        return 1;
    }
    return 0;
}

static int set_agx_gpu_cap(int64_t mw) {
    io_service_t agx = find_agx();
    if (!agx) {
        fprintf(stderr, "AGX service not found\n");
        return 1;
    }
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dict, CFSTR("SetMaxGPUAbsolutePower"), kCFBooleanTrue);
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &mw);
    CFDictionarySetValue(dict, CFSTR("AbsoluteTarget"), num);
    kern_return_t kr = IORegistryEntrySetCFProperties(agx, dict);
    CFRelease(num);
    CFRelease(dict);
    IOObjectRelease(agx);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "AGX write failed: 0x%x\n", kr);
        return 1;
    }
    return 0;
}

static int run_pmset(char *const argv[]) {
    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/usr/bin/pmset", NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "posix_spawn pmset failed: %d\n", rc);
        return 1;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 1;
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: powerctl <cap W | gpu mW | ultra W mW | restore gpu_mW [batt_lpm ac_lpm]>\n");
        return 2;
    }
    const char *cmd = argv[1];

    if (strcmp(cmd, "cap") == 0 && argc >= 3) {
        double watts = strtod(argv[2], NULL);
        if (!(watts >= 1.0 && watts <= 60.0)) {
            fprintf(stderr, "Invalid watts (1.0 - 60.0): %s\n", argv[2]);
            return 2;
        }
        int64_t raw = (int64_t)llround(watts * (double)Q24_SCALE);
        return set_clpc_pkg_target(raw);
    }

    if (strcmp(cmd, "gpu") == 0 && argc >= 3) {
        int64_t mw = strtoll(argv[2], NULL, 10);
        if (mw < 500 || mw > 100000) {
            fprintf(stderr, "Invalid GPU mW (500 - 100000): %s\n", argv[2]);
            return 2;
        }
        return set_agx_gpu_cap(mw);
    }

    if (strcmp(cmd, "ultra") == 0 && argc >= 4) {
        double watts = strtod(argv[2], NULL);
        int64_t mw = strtoll(argv[3], NULL, 10);
        if (!(watts >= 1.0 && watts <= 10.0) || mw < 500 || mw > 10000) {
            fprintf(stderr, "Invalid ultra parameters\n");
            return 2;
        }
        int64_t raw = (int64_t)llround(watts * (double)Q24_SCALE);
        if (set_clpc_pkg_target(raw) != 0) return 1;
        set_agx_gpu_cap(mw); /* best-effort GPU cap */
        char *pm_args[] = { "/usr/bin/pmset", "-a", "lowpowermode", "1", NULL };
        if (run_pmset(pm_args) != 0) return 1;
        return 0;
    }

    if (strcmp(cmd, "restore") == 0) {
        int rc = set_clpc_pkg_target(-Q24_SCALE);
        if (argc >= 3) {
            int64_t orig_mw = strtoll(argv[2], NULL, 10);
            if (orig_mw >= 1000 && orig_mw <= 200000) {
                if (set_agx_gpu_cap(orig_mw) != 0) rc = 1;
            }
        }
        if (argc >= 5) {
            int batt = atoi(argv[3]);
            int ac = atoi(argv[4]);
            if ((batt == 0 || batt == 1) && (ac == 0 || ac == 1)) {
                char batt_s[4], ac_s[4];
                snprintf(batt_s, sizeof(batt_s), "%d", batt);
                snprintf(ac_s, sizeof(ac_s), "%d", ac);
                char *pm_b[] = { "/usr/bin/pmset", "-b", "lowpowermode", batt_s, NULL };
                char *pm_c[] = { "/usr/bin/pmset", "-c", "lowpowermode", ac_s, NULL };
                if (run_pmset(pm_b) != 0) rc = 1;
                if (run_pmset(pm_c) != 0) rc = 1;
            }
        }
        return rc;
    }

    fprintf(stderr, "Unknown command or missing args\n");
    return 2;
}
