#include "sensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

/* ============================================================
   温度与功耗都不需要 root：
   - 温度：IOHIDEventSystemClient 的 AppleVendor 温度传感器
   - 功耗：AppleSMC 的 PSTR（系统总功耗），与 Stats 同源
   ============================================================ */

/* ---- private IOHID event-system API ---- */
typedef struct __IOHIDEventSystemClient  *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient      *IOHIDServiceClientRef;
typedef struct __IOHIDEvent              *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);

#define kHIDEventTypeTemperature 15
#define kAppleVendorTopCase      0xff00
#define kAppleVendorUsageTemp    5

/* 客户端、传感器列表及名称都缓存下来，避免每次轮询重建与重复拷贝属性（重建本身会推高功耗读数） */
#define MAX_CACHED_NAMES 256
static pthread_mutex_t           s_hid_lock = PTHREAD_MUTEX_INITIALIZER;
static IOHIDEventSystemClientRef s_client = NULL;
static CFArrayRef                s_services = NULL;
static CFAbsoluteTime            s_last_scan = 0;
static char                      s_names[MAX_CACHED_NAMES][96];
static CFIndex                   s_names_count = 0;

static void copy_service_name(IOHIDServiceClientRef svc, char *dst, size_t dstSize)
{
    const char *nm = "unknown";
    char buf[96] = {0};
    CFTypeRef prod = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
    if (prod && CFGetTypeID(prod) == CFStringGetTypeID()) {
        if (CFStringGetCString((CFStringRef)prod, buf, sizeof(buf), kCFStringEncodingUTF8))
            nm = buf;
    }
    if (prod) CFRelease(prod);
    strncpy(dst, nm, dstSize - 1);
    dst[dstSize - 1] = '\0';
}

static void hid_ensure(int force)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (s_client && s_services && !force && (now - s_last_scan) < 30.0) return;

    if (s_services) { CFRelease(s_services); s_services = NULL; }
    s_names_count = 0;

    if (!s_client) {
        s_client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!s_client) return;

        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        int         page   = kAppleVendorTopCase;
        int         usage  = kAppleVendorUsageTemp;
        CFNumberRef nPage  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
        CFNumberRef nUsage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
        const void *vals[] = { nPage, nUsage };

        CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(s_client, matching);
        CFRelease(matching);
        CFRelease(nPage);
        CFRelease(nUsage);
    }

    s_services = IOHIDEventSystemClientCopyServices(s_client);
    s_last_scan = now;
    if (s_services) {
        CFIndex n = CFArrayGetCount(s_services);
        CFIndex limit = n < MAX_CACHED_NAMES ? n : MAX_CACHED_NAMES;
        for (CFIndex i = 0; i < limit; i++) {
            IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(s_services, i);
            if (svc) {
                copy_service_name(svc, s_names[i], sizeof(s_names[i]));
            } else {
                strncpy(s_names[i], "unknown", sizeof(s_names[i]) - 1);
                s_names[i][sizeof(s_names[i]) - 1] = '\0';
            }
        }
        s_names_count = limit;
    }
}

int sensors_read_temperatures(TempSensor *out, int max)
{
    pthread_mutex_lock(&s_hid_lock);
    hid_ensure(0);
    if (!s_services) {
        pthread_mutex_unlock(&s_hid_lock);
        return 0;
    }

    int count = 0;
    CFIndex n = CFArrayGetCount(s_services);
    for (CFIndex i = 0; i < n && count < max; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(s_services, i);
        if (!svc) continue;

        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;

        double v = IOHIDEventGetFloatValue(ev, kHIDEventTypeTemperature << 16);
        CFRelease(ev);
        if (!(v > 0.0 && v < 150.0)) continue;

        if (i < s_names_count) {
            memcpy(out[count].name, s_names[i], sizeof(out[count].name));
        } else {
            copy_service_name(svc, out[count].name, sizeof(out[count].name));
        }
        out[count].value = v;
        count++;
    }
    pthread_mutex_unlock(&s_hid_lock);
    return count;
}

const char *sensor_name(const TempSensor *s) { return s->name; }

/* ---------------- SMC ---------------- */
#define KERNEL_INDEX_SMC     2
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_READ_BYTES   5

typedef struct { uint8_t major, minor, build, reserved[1]; uint16_t release; } vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } pLimit_t;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } keyInfo_t;
typedef struct {
    uint32_t  key;
    vers_t    vers;
    pLimit_t  pLimitData;
    keyInfo_t keyInfo;
    uint8_t   result, status, data8;
    uint32_t  data32;
    uint8_t   bytes[32];
} SMCParamStruct;

static pthread_mutex_t s_smc_lock = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t    g_smc = 0;

#define SMC_KEYINFO_CACHE_SIZE 16
typedef struct {
    uint32_t  key;
    keyInfo_t info;
    int       valid;
} SMCKeyCacheEntry;
static SMCKeyCacheEntry g_smc_cache[SMC_KEYINFO_CACHE_SIZE];

static int smc_open(void)
{
    if (g_smc) return 1;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_smc);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess) { g_smc = 0; return 0; }
    return 1;
}

static kern_return_t smc_call(SMCParamStruct *in, SMCParamStruct *out)
{
    size_t outSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(g_smc, KERNEL_INDEX_SMC,
                                     in, sizeof(SMCParamStruct), out, &outSize);
}

static uint32_t fourcc(const char *s)
{
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static int smc_lookup_keyinfo(uint32_t k, keyInfo_t *outInfo)
{
    int freeSlot = -1;
    for (int i = 0; i < SMC_KEYINFO_CACHE_SIZE; i++) {
        if (g_smc_cache[i].valid) {
            if (g_smc_cache[i].key == k) {
                *outInfo = g_smc_cache[i].info;
                return 1;
            }
        } else if (freeSlot < 0) {
            freeSlot = i;
        }
    }

    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key   = k;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return 0;

    if (out.keyInfo.dataSize == 0 || out.keyInfo.dataSize > 32) return 0;
    *outInfo = out.keyInfo;

    if (freeSlot >= 0) {
        g_smc_cache[freeSlot].key   = k;
        g_smc_cache[freeSlot].info  = out.keyInfo;
        g_smc_cache[freeSlot].valid = 1;
    }
    return 1;
}

/* 读一个 SMC 键的浮点值；缓存 keyInfo 以减半内核调用，失败返回 NAN */
static double smc_read_float(const char *key)
{
    pthread_mutex_lock(&s_smc_lock);
    if (!smc_open()) {
        pthread_mutex_unlock(&s_smc_lock);
        return NAN;
    }

    uint32_t k = fourcc(key);
    keyInfo_t info;
    if (!smc_lookup_keyinfo(k, &info)) {
        pthread_mutex_unlock(&s_smc_lock);
        return NAN;
    }

    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key              = k;
    in.keyInfo.dataSize = info.dataSize;
    in.data8            = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) {
        /* 连接或缓存失效时清理一次并重试 */
        for (int i = 0; i < SMC_KEYINFO_CACHE_SIZE; i++) {
            if (g_smc_cache[i].key == k) g_smc_cache[i].valid = 0;
        }
        pthread_mutex_unlock(&s_smc_lock);
        return NAN;
    }

    uint32_t type = info.dataType;
    double val = NAN;
    if (type == fourcc("flt ") || type == fourcc("tlf ")) {
        float f;
        memcpy(&f, out.bytes, 4);
        val = (double)f;
    } else if (type == fourcc("sp78")) {
        val = (double)((int16_t)((out.bytes[0] << 8) | out.bytes[1])) / 256.0;
    } else if (type == fourcc("ui16")) {
        val = (double)((out.bytes[0] << 8) | out.bytes[1]);
    } else if (type == fourcc("fpe2")) {
        val = (double)((out.bytes[0] << 8) | out.bytes[1]) / 4.0;
    }
    pthread_mutex_unlock(&s_smc_lock);
    return val;
}

/* ---------------- 电池遥测（SMC 不可用时的兜底） ---------------- */
double sensors_chip_w(void)
{
    double w = smc_read_float("PZC0");
    return isfinite(w) && w >= 0.0 && w < 500.0 ? w : NAN;
}

static pthread_mutex_t s_io_lock = PTHREAD_MUTEX_INITIALIZER;
static io_service_t    s_battery = 0;
static int             s_battery_probed = 0;
static io_service_t    s_clpc = 0;
static int             s_clpc_probed = 0;
static io_service_t    s_agx = 0;
static int             s_agx_probed = 0;
static io_service_t    s_pm_root = 0;
static int             s_pm_root_probed = 0;

static io_service_t cached_battery(void)
{
    if (!s_battery_probed) {
        s_battery = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("AppleSmartBattery"));
        s_battery_probed = 1;
    }
    return s_battery;
}

static CFTypeRef battery_prop(CFStringRef key)
{
    pthread_mutex_lock(&s_io_lock);
    io_service_t svc = cached_battery();
    CFTypeRef v = svc ? IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0) : NULL;
    pthread_mutex_unlock(&s_io_lock);
    return v;
}

/* 系统总功耗，单位 mW。优先用 SMC PSTR（实时），兜底用电池遥测 */
double sensors_system_mw(void)
{
    double w = smc_read_float("PSTR");
    if (isfinite(w) && w > 0.2 && w < 500.0) return w * 1000.0;

    double result = -1.0;
    CFTypeRef t = battery_prop(CFSTR("PowerTelemetryData"));
    if (t && CFGetTypeID(t) == CFDictionaryGetTypeID()) {
        CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)t, CFSTR("SystemLoad"));
        if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
            long long mw = 0;
            CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &mw);
            if (mw > 0) result = (double)mw;
        }
    }
    if (t) CFRelease(t);
    return result;
}

int sensors_on_ac(void)
{
    int onAC = 0;
    CFTypeRef ext = battery_prop(CFSTR("ExternalConnected"));
    if (ext) {
        onAC = CFBooleanGetValue((CFBooleanRef)ext);
        CFRelease(ext);
    }
    return onAC;
}

/* 电池充放电功率（W） */
double sensors_battery_w(void)
{
    double w = smc_read_float("PPBR");
    return isfinite(w) ? w : NAN;
}

/* 读取 AppleCLPC 当前封装功耗上限（W）；未限制或不可用返回 -1.0 */
double sensors_pkg_power_cap_w(void)
{
    pthread_mutex_lock(&s_io_lock);
    if (!s_clpc_probed) {
        s_clpc = IOServiceGetMatchingService(kIOMainPortDefault,
                                             IOServiceMatching("AppleCLPC"));
        s_clpc_probed = 1;
    }
    io_service_t clpc = s_clpc;
    CFTypeRef v = clpc ? IORegistryEntryCreateCFProperty(clpc, CFSTR("`pkg-avg-therm-power-target"),
                                                         kCFAllocatorDefault, 0) : NULL;
    pthread_mutex_unlock(&s_io_lock);
    if (!v) return -1.0;
    double res = -1.0;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int64_t raw = -1;
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &raw);
        if (raw >= 0) res = (double)raw / 16777216.0;
    }
    CFRelease(v);
    return res;
}

/* 读取 AGX GPU 当前 MaxGPUAbsolutePower（mW）；不可用返回 -1 */
int64_t sensors_gpu_power_cap_mw(void)
{
    pthread_mutex_lock(&s_io_lock);
    if (!s_agx_probed) {
        const char *classes[] = {
            "AGXAcceleratorG17G", "AGXAcceleratorG17X", "AGXAcceleratorG16G",
            "AGXAcceleratorG15X", "AGXAcceleratorG15G", "AGXAcceleratorG14X",
            "AGXAcceleratorG13G", "AGXAccelerator", NULL
        };
        for (int i = 0; classes[i]; i++) {
            s_agx = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(classes[i]));
            if (s_agx) break;
        }
        s_agx_probed = 1;
    }
    io_service_t agx = s_agx;
    CFTypeRef v = agx ? IORegistryEntryCreateCFProperty(agx, CFSTR("MaxGPUAbsolutePower"),
                                                        kCFAllocatorDefault, 0) : NULL;
    pthread_mutex_unlock(&s_io_lock);
    if (!v) return -1;
    int64_t mw = -1;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &mw);
    }
    CFRelease(v);
    return mw;
}

/* 读取 IOPMrootDomain SleepDisabled；不可用返回 -1 */
int sensors_sleep_disabled(void)
{
    pthread_mutex_lock(&s_io_lock);
    if (!s_pm_root_probed) {
        s_pm_root = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPMrootDomain"));
        s_pm_root_probed = 1;
    }
    io_service_t root = s_pm_root;
    CFTypeRef v = root ? IORegistryEntryCreateCFProperty(root, CFSTR("SleepDisabled"),
                                                         kCFAllocatorDefault, 0) : NULL;
    pthread_mutex_unlock(&s_io_lock);
    if (!v) return -1;
    int res = -1;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        res = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int n = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n)) {
            res = (n != 0) ? 1 : 0;
        }
    }
    CFRelease(v);
    return res;
}
