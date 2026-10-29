#include "motionwake.h"
#include "iokit.h"
#include <unistd.h>

static CFStringRef kEnabled = CFSTR("Enabled");
static CFStringRef kTimeout = CFSTR("Timeout");
static CFStringRef kSensitivity = CFSTR("Sensitivity");
static CFStringRef kShowDot = CFSTR("ShowOnDashboard");
static CFStringRef kSleepLow = CFSTR("SleepOnLowBattery");
static CFStringRef kSleepBelow = CFSTR("SleepBelow");

static int clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

void mw_prefs_clamp(mw_prefs *p) {
    p->timeout = clamp(p->timeout, MW_MIN_TIMEOUT, MW_MAX_TIMEOUT);
    p->sensitivity = clamp(p->sensitivity, 1, 100);
    p->sleep_below = clamp(p->sleep_below, MW_MIN_SLEEP_BELOW, MW_MAX_SLEEP_BELOW);
}

static int dict_int(CFDictionaryRef d, CFStringRef key, int fallback) {
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    int n = fallback;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &n);
    return n;
}

static bool dict_bool(CFDictionaryRef d, CFStringRef key, bool fallback) {
    CFTypeRef v = d ? CFDictionaryGetValue(d, key) : NULL;
    return v && CFGetTypeID(v) == CFBooleanGetTypeID() ? CFBooleanGetValue(v) : fallback;
}

void mw_prefs_load(mw_prefs *p) {
    *p = (mw_prefs){.enabled = true, .timeout = MW_DEFAULT_TIMEOUT, .sensitivity = MW_DEFAULT_SENSITIVITY,
                    .show_dot = true, .sleep_low = true, .sleep_below = MW_DEFAULT_SLEEP_BELOW};

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)MW_PREFS_PATH,
                                                           sizeof MW_PREFS_PATH - 1, false);
    CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url);
    CFRelease(url);
    CFPropertyListRef plist = NULL;
    if (CFReadStreamOpen(stream)) {
        plist = CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListImmutable, NULL, NULL);
        CFReadStreamClose(stream);
    }
    CFRelease(stream);

    if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        p->enabled = dict_bool(plist, kEnabled, p->enabled);
        p->timeout = dict_int(plist, kTimeout, p->timeout);
        p->sensitivity = dict_int(plist, kSensitivity, p->sensitivity);
        p->show_dot = dict_bool(plist, kShowDot, p->show_dot);
        p->sleep_low = dict_bool(plist, kSleepLow, p->sleep_low);
        p->sleep_below = dict_int(plist, kSleepBelow, p->sleep_below);
    }
    if (plist) CFRelease(plist);
    mw_prefs_clamp(p);
}

static void set_int(CFMutableDictionaryRef d, CFStringRef key, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

static void set_bool(CFMutableDictionaryRef d, CFStringRef key, bool v) {
    CFDictionarySetValue(d, key, v ? kCFBooleanTrue : kCFBooleanFalse);
}

bool mw_prefs_save(const mw_prefs *in) {
    mw_prefs p = *in;
    mw_prefs_clamp(&p);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    set_bool(d, kEnabled, p.enabled);
    set_int(d, kTimeout, p.timeout);
    set_int(d, kSensitivity, p.sensitivity);
    set_bool(d, kShowDot, p.show_dot);
    set_bool(d, kSleepLow, p.sleep_low);
    set_int(d, kSleepBelow, p.sleep_below);
    CFDataRef data = CFPropertyListCreateData(NULL, d, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    CFRelease(d);
    if (!data) return false;

    // Write a temp file and rename it, so the daemon never reads half a plist.
    static const char tmp[] = MW_PREFS_PATH ".tmp";
    bool ok = false;
    FILE *f = fopen(tmp, "w");
    if (f) {
        ok = fwrite(CFDataGetBytePtr(data), 1, CFDataGetLength(data), f) == (size_t)CFDataGetLength(data);
        ok = (fclose(f) == 0) && ok;
        if (getuid() == 0) chown(tmp, 501, 501); // keep it writable by the app, which runs as mobile
        ok = ok && rename(tmp, MW_PREFS_PATH) == 0;
    }
    CFRelease(data);
    if (ok)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR(MW_NOTIFY_PREFS),
                                             NULL, NULL, true);
    return ok;
}

bool mw_battery_read(mw_battery *b) {
    *b = (mw_battery){.percent = -1};
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = blob ? IOPSCopyPowerSourcesList(blob) : NULL;
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef ps = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
        CFStringRef type = ps ? CFDictionaryGetValue(ps, CFSTR("Type")) : NULL;
        if (!type || CFStringCompare(type, CFSTR("InternalBattery"), 0) != kCFCompareEqualTo) continue;
        int cur = dict_int(ps, CFSTR("Current Capacity"), -1), max = dict_int(ps, CFSTR("Max Capacity"), 100);
        if (cur >= 0 && max > 0) b->percent = (cur * 100 + max / 2) / max;
        CFStringRef state = CFDictionaryGetValue(ps, CFSTR("Power Source State"));
        b->external = state && CFStringCompare(state, CFSTR("AC Power"), 0) == kCFCompareEqualTo;
        break;
    }
    if (list) CFRelease(list);
    if (blob) CFRelease(blob);
    return b->percent >= 0;
}

// Sensitivity 50 asks for 6% of the picture to change by 16 grey levels; 100 asks for 1% by 6.
float mw_needed_percent(int sensitivity) { return 1.0f + (100 - sensitivity) * 0.1f; }
int mw_cell_threshold(int sensitivity) { return 6 + (100 - sensitivity) / 5; }
