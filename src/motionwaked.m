// motionwaked: watches the room through the front camera while the iPad is on power, turns the
// screen on when something moves and off again once the room has been still for a while.
//
// Only SpringBoard may drive the backlight on iOS 9, so "screen off" is a lock (the backlight goes
// out a few seconds later) and "screen on" opens the dashboard web clip with an unlock. Auto-Lock
// should be Never: this daemon does the locking. While watching it holds "PreventUserIdleSystemSleep",
// or the iPad would sleep once locked and the camera would stop with it.
//
// On battery the camera stays off. If "sleep on low battery" is on and the battery is at or below
// its level, the iPad locks once it has been left untouched for the screen-off time, and sleeps.
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include "iokit.h"
#include "motionwake.h"
#include <arpa/inet.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <netinet/in.h>
#include <notify.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/stat.h>

#define GRID_W 24 // the picture is compared as a grid of cell averages, 8x8 pixels each at 192x144
#define GRID_H 18
#define CELLS (GRID_W * GRID_H)
#define HITS_NEEDED 2       // frames in a row over the line before it counts as movement
#define SETTLE_SECONDS 3.0  // after the screen changes, its own light change is not movement
#define MANUAL_QUIET 30.0   // after a lock by hand, the room must be still this long before waking again
#define CAMERA_FPS 5

static mw_prefs prefs;
static mw_battery battery;
static IOPMAssertionID awake;
static AVCaptureSession *session;
static int lock_token, display_token;

static double last_activity; // movement, a touch, plugging in or our own wake
static double last_motion, settle_until, our_lock_at, camera_retry_at;
static int wanted = -1;  // on power with the feature on, so the camera should be running
static bool manual_hold; // locked by hand: stay dark until the room is empty
static double manual_at;
static int hits;
static float level, luma; // the latest frame: % of the picture that changed, mean brightness
static int frames, fps;
static volatile int cell_threshold;
static volatile bool reset_reference;

// Private calls, looked up at start.
static int (*SBSLaunchApplicationWithIdentifierAndLaunchOptions)(CFStringRef, CFDictionaryRef, Boolean);
static CFStringRef SBSApplicationLaunchOptionUnlockDeviceKey;
static Boolean (*SBSOpenSensitiveURLAndUnlock)(CFURLRef, Boolean);
static mach_port_t (*SBSSpringBoardServerPort)(void);
static void (*SBSLockDevice)(mach_port_t, Boolean);
static void (*SBSUndimScreen)(void);
static double (*BKSHIDServicesLastUserEventTime)(void); // seconds on the mach_absolute_time clock

static void logline(const char *fmt, ...) {
    struct stat st;
    if (stat(MW_LOG_PATH, &st) == 0 && st.st_size > 128 * 1024) rename(MW_LOG_PATH, MW_LOG_PATH ".1");
    FILE *f = fopen(MW_LOG_PATH, "a");
    if (!f) return;
    char ts[32];
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(f, "%s ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * (double)tb.numer / tb.denom / 1e9;
}

static void *private_sym(const char *framework, const char *name) {
    char path[256];
    snprintf(path, sizeof path, "/System/Library/PrivateFrameworks/%s.framework/%s", framework, framework);
    void *h = dlopen(path, RTLD_NOW);
    void *p = h ? dlsym(h, name) : NULL;
    if (!p) logline("missing %s", name);
    return p;
}

static uint64_t notify_state(int token) {
    uint64_t v = 0;
    notify_get_state(token, &v);
    return v;
}

static bool locked(void) { return notify_state(lock_token) != 0; }
static bool display_on(void) { return notify_state(display_token) != 0; }
static bool watching(void) { return session != nil; }

static void note_touches(void) {
    if (!BKSHIDServicesLastUserEventTime) return;
    double t = BKSHIDServicesLastUserEventTime();
    if (t > last_activity && t <= now_s()) last_activity = t;
}

static void settle(void) {
    settle_until = now_s() + SETTLE_SECONDS;
    reset_reference = true;
    hits = 0;
}

static void screen_off(const char *why) {
    if (!SBSLockDevice || !SBSSpringBoardServerPort || now_s() - our_lock_at < 10) return;
    our_lock_at = now_s();
    settle();
    SBSLockDevice(SBSSpringBoardServerPort(), true);
    logline("screen off: %s", why);
}

// The home-screen web clip to wake into: the full-screen one titled "Dashboard", or failing that
// the first full-screen one. Looked up on every wake, so a re-added clip is picked up.
static NSString *dashboard_clip(void) {
    NSString *dir = @"/var/mobile/Library/WebClips", *found = nil;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if (![name.pathExtension isEqual:@"webclip"]) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingFormat:@"/%@/Info.plist", name]];
        if (![info[@"FullScreen"] boolValue]) continue;
        if ([info[@"Title"] isEqual:@"Dashboard"]) return name.stringByDeletingPathExtension;
        if (!found) found = name.stringByDeletingPathExtension;
    }
    return found;
}

static void screen_on(void) {
    settle();
    last_activity = now_s();
    // Opening the clip's webapp: URL with unlock brings the running dashboard back in front.
    // (Unlocking on its own would land on the home screen.)
    NSString *clip = dashboard_clip();
    if (clip && SBSOpenSensitiveURLAndUnlock &&
        SBSOpenSensitiveURLAndUnlock((__bridge CFURLRef)[NSURL URLWithString:[@"webapp:" stringByAppendingString:clip]], true)) {
        logline("screen on: movement %.1f%%", level);
        return;
    }
    if (SBSUndimScreen) SBSUndimScreen();
    if (!SBSLaunchApplicationWithIdentifierAndLaunchOptions || !SBSApplicationLaunchOptionUnlockDeviceKey) return;
    // No dashboard clip: launching SpringBoard itself with the unlock option unlocks to the home screen.
    const void *k = SBSApplicationLaunchOptionUnlockDeviceKey, *v = kCFBooleanTrue;
    CFDictionaryRef opts = CFDictionaryCreate(NULL, &k, &v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int r = SBSLaunchApplicationWithIdentifierAndLaunchOptions(CFSTR("com.apple.springboard"), opts, false);
    CFRelease(opts);
    logline("screen on: movement %.1f%%, no dashboard clip%s", level, r ? " (unlock failed)" : "");
}

static void on_frame(float changed, float mean);

// The camera: each frame becomes a grid of cell averages, compared with the frame before.
@interface Watcher : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation Watcher {
    float _ref[CELLS];
    bool _haveRef;
}

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    if (reset_reference) {
        reset_reference = false;
        _haveRef = false;
    }
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px || CVPixelBufferLockBaseAddress(px, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    size_t w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(px, 0);
    const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(px, 0);
    size_t cw = w / GRID_W, ch = h / GRID_H;
    float cur[CELLS], total = 0;
    for (int gy = 0; gy < GRID_H; gy++) {
        for (int gx = 0; gx < GRID_W; gx++) {
            unsigned sum = 0, n = 0;
            for (size_t r = gy * ch; r < (gy + 1) * ch; r += 2)
                for (size_t x = gx * cw; x < (gx + 1) * cw; x += 2, n++) sum += y[r * stride + x];
            cur[gy * GRID_W + gx] = n ? (float)sum / n : 0;
            total += cur[gy * GRID_W + gx];
        }
    }
    CVPixelBufferUnlockBaseAddress(px, kCVPixelBufferLock_ReadOnly);

    float changed = 0;
    if (_haveRef) {
        // Take out a change of the whole picture (exposure, a lamp) so only local change counts.
        float shift = 0;
        for (int i = 0; i < CELLS; i++) shift += cur[i] - _ref[i];
        shift /= CELLS;
        int over = 0, thr = cell_threshold;
        for (int i = 0; i < CELLS; i++) over += fabsf(cur[i] - _ref[i] - shift) > thr;
        changed = over * 100.0f / CELLS;
    }
    bool first = !_haveRef;
    memcpy(_ref, cur, sizeof cur);
    _haveRef = true;
    float mean = total / CELLS;
    if (first) return;
    dispatch_async(dispatch_get_main_queue(), ^{ on_frame(changed, mean); });
}
@end

static Watcher *watcher;

static void on_frame(float changed, float mean) {
    double now = now_s();
    level = changed;
    luma = mean;
    frames++;
    if (now < settle_until) return;
    hits = changed >= mw_needed_percent(prefs.sensitivity) ? hits + 1 : 0;
    if (hits < HITS_NEEDED) return;
    last_motion = last_activity = now;
    if (manual_hold) return;
    if (locked() || !display_on()) screen_on();
}

static void start_camera(void) {
    if (session || now_s() < camera_retry_at) return;
    camera_retry_at = now_s() + 30;
    AVCaptureDevice *front = nil;
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo])
        if (d.position == AVCaptureDevicePositionFront) front = d;
    NSError *err = nil;
    AVCaptureDeviceInput *input = front ? [AVCaptureDeviceInput deviceInputWithDevice:front error:&err] : nil;
    if (!input) {
        logline("no front camera: %s", err.localizedDescription.UTF8String ?: "not found");
        return;
    }
    session = [AVCaptureSession new];
    session.sessionPreset = AVCaptureSessionPresetLow;
    [session addInput:input];
    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
    out.alwaysDiscardsLateVideoFrames = YES;
    [out setSampleBufferDelegate:watcher queue:dispatch_queue_create("uk.lbsi.motionwake.camera", DISPATCH_QUEUE_SERIAL)];
    [session addOutput:out];
    // Five frames a second is plenty to catch someone walking in and keeps the camera's power down.
    if ([front lockForConfiguration:nil]) {
        CMTime t = CMTimeMake(1, CAMERA_FPS);
        for (AVFrameRateRange *r in front.activeFormat.videoSupportedFrameRateRanges)
            if (r.minFrameRate <= CAMERA_FPS && CAMERA_FPS <= r.maxFrameRate) front.activeVideoMinFrameDuration = t;
        [front unlockForConfiguration];
    }
    [session startRunning];
    settle();
    last_activity = now_s();
    IOPMAssertionCreateWithName(CFSTR("PreventUserIdleSystemSleep"), kIOPMAssertionLevelOn,
                                CFSTR("MotionWake: watching for movement"), &awake);
}

static void stop_camera(void) {
    if (!session) return;
    [session stopRunning];
    session = nil;
    if (awake) IOPMAssertionRelease(awake);
    awake = 0;
    level = 0;
}

// Decide whether the camera should run, and whether the screen has been still long enough.
static void evaluate(void) {
    mw_battery_read(&battery);
    bool want = prefs.enabled && battery.external;
    if (want != wanted) {
        wanted = want;
        camera_retry_at = 0;
        logline("%s", want ? "watching (on power)" : !prefs.enabled ? "not watching: turned off" : "not watching: on battery");
    }
    if (want) start_camera();
    else stop_camera();

    note_touches();
    double now = now_s(), still = now - last_activity;
    bool on = display_on() && !locked();

    if (manual_hold && (!locked() || now - fmax(last_motion, manual_at) >= MANUAL_QUIET)) {
        manual_hold = false;
        if (locked()) logline("room still for %.0f s, movement wakes the screen again", MANUAL_QUIET);
    }

    if (watching() && on && still >= prefs.timeout) {
        char why[64];
        snprintf(why, sizeof why, "still for %.0f s", still);
        screen_off(why);
    } else if (!battery.external && prefs.sleep_low && battery.percent >= 0 && battery.percent <= prefs.sleep_below && on &&
               still >= prefs.timeout) {
        char why[64];
        snprintf(why, sizeof why, "battery %d%%, untouched for %.0f s", battery.percent, still);
        screen_off(why);
    }
}

static void reload(void) {
    mw_prefs old = prefs;
    mw_prefs_load(&prefs);
    cell_threshold = mw_cell_threshold(prefs.sensitivity);
    if (memcmp(&old, &prefs, sizeof prefs) != 0)
        logline("settings: %s, off after %d s, sensitivity %d, dot %s, sleep on battery %s at %d%%", prefs.enabled ? "on" : "off",
                prefs.timeout, prefs.sensitivity, prefs.show_dot ? "on" : "off", prefs.sleep_low ? "on" : "off", prefs.sleep_below);
}

// GET /status on 127.0.0.1, for the settings app and the dashboard page (hence the CORS header).
static NSString *status_json(void) {
    double now = now_s();
    const char *screen = !display_on() ? "off" : locked() ? "locked" : "on";
    const char *state = watching() ? (manual_hold ? "held" : "watching") : !prefs.enabled ? "off" : "battery";
    return [NSString stringWithFormat:@"{\"state\":\"%s\",\"external\":%s,\"battery\":%d,\"motion\":%s,\"level\":%.1f,"
                                      @"\"needed\":%.1f,\"luma\":%.0f,\"fps\":%d,\"stillFor\":%.0f,\"timeout\":%d,"
                                      @"\"screen\":\"%s\",\"showDot\":%s,\"sleepLow\":%s,\"sleepBelow\":%d}",
                                      state, battery.external ? "true" : "false", battery.percent,
                                      watching() && now - last_motion < 1.0 ? "true" : "false", level,
                                      mw_needed_percent(prefs.sensitivity), luma, fps, now - last_activity, prefs.timeout,
                                      screen, prefs.show_dot ? "true" : "false", prefs.sleep_low ? "true" : "false",
                                      prefs.sleep_below];
}

static void serve_status(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr = {.sin_len = sizeof addr, .sin_family = AF_INET, .sin_port = htons(MW_STATUS_PORT)};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 8) != 0) {
        static bool said;
        if (!said) logline("status port %d busy, trying again", MW_STATUS_PORT);
        said = true;
        close(fd);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ serve_status(); });
        return;
    }
    static dispatch_source_t src; // ARC frees a local one as soon as this returns
    src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        int c = accept(fd, NULL, NULL);
        if (c < 0) return;
        struct timeval tv = {.tv_sec = 1};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        char req[1024];
        read(c, req, sizeof req); // any request gets the status
        NSData *body = [status_json() dataUsingEncoding:NSUTF8StringEncoding];
        NSString *head = [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n"
                                                    @"Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n"
                                                    @"Content-Length: %lu\r\nConnection: close\r\n\r\n",
                                                    (unsigned long)body.length];
        write(c, head.UTF8String, strlen(head.UTF8String));
        write(c, body.bytes, body.length);
        close(c);
    });
    dispatch_resume(src);
}

static void on_power_change(void *ctx) {
    last_activity = now_s(); // someone just plugged it in or pulled the cable
    evaluate();
}

static void on_prefs_change(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    reload();
    evaluate();
}

static io_connect_t root_port;
static void on_system_power(void *ref, io_service_t service, uint32_t type, void *arg) {
    if (type == kIOMessageCanSystemSleep || type == kIOMessageSystemWillSleep) IOAllowPowerChange(root_port, (intptr_t)arg);
    if (type == kIOMessageSystemHasPoweredOn) evaluate();
}

int main(void) {
    @autoreleasepool {
        signal(SIGTERM, SIG_IGN);
        signal(SIGPIPE, SIG_IGN);
        // Sources are kept in statics: ARC may release a local one after its last use.
        static dispatch_source_t term, tick;
        term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{
            stop_camera();
            unlink(MW_PID_PATH);
            logline("stopped");
            exit(0);
        });
        dispatch_resume(term);

        FILE *pid = fopen(MW_PID_PATH, "w");
        if (pid) {
            fprintf(pid, "%d\n", getpid());
            fclose(pid);
        }

        SBSLaunchApplicationWithIdentifierAndLaunchOptions =
            private_sym("SpringBoardServices", "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
        CFStringRef *unlock_key = private_sym("SpringBoardServices", "SBSApplicationLaunchOptionUnlockDeviceKey");
        SBSApplicationLaunchOptionUnlockDeviceKey = unlock_key ? *unlock_key : NULL;
        SBSOpenSensitiveURLAndUnlock = private_sym("SpringBoardServices", "SBSOpenSensitiveURLAndUnlock");
        SBSSpringBoardServerPort = private_sym("SpringBoardServices", "SBSSpringBoardServerPort");
        SBSLockDevice = private_sym("SpringBoardServices", "SBSLockDevice");
        SBSUndimScreen = private_sym("SpringBoardServices", "SBSUndimScreen");
        BKSHIDServicesLastUserEventTime = private_sym("BackBoardServices", "BKSHIDServicesLastUserEventTime");

        // SpringBoard posts these whenever the lock or the display changes; either one changes the light.
        notify_register_dispatch("com.apple.springboard.lockstate", &lock_token, dispatch_get_main_queue(), ^(int t) {
            if (locked() && now_s() - our_lock_at > 3 && !manual_hold) {
                manual_hold = true;
                manual_at = now_s();
                logline("locked by hand: staying dark until the room has been still for %.0f s", MANUAL_QUIET);
            }
            settle();
        });
        notify_register_dispatch("com.apple.iokit.hid.displayStatus", &display_token, dispatch_get_main_queue(), ^(int t) {
            settle();
        });

        watcher = [Watcher new];
        reload();
        logline("started");
        last_activity = now_s();
        serve_status();

        [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionWasInterruptedNotification object:nil
                                                           queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            last_activity = now_s(); // another app took the camera, so someone is using the iPad
            logline("camera interrupted");
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionInterruptionEndedNotification object:nil
                                                           queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            settle();
            logline("camera back");
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:nil
                                                           queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            logline("camera error: %s", [n.userInfo[AVCaptureSessionErrorKey] localizedDescription].UTF8String ?: "?");
            stop_camera(); // evaluate() starts it again on the next tick
        }];

        CFRunLoopAddSource(CFRunLoopGetCurrent(), IOPSNotificationCreateRunLoopSource(on_power_change, NULL),
                           kCFRunLoopDefaultMode);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, on_prefs_change,
                                        CFSTR(MW_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        IONotificationPortRef power_port;
        io_object_t power_notifier;
        root_port = IORegisterForSystemPower(NULL, &power_port, on_system_power, &power_notifier);
        if (root_port)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(power_port), kCFRunLoopDefaultMode);

        tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(tick, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(tick, ^{
            fps = frames;
            frames = 0;
            evaluate();
        });
        dispatch_resume(tick);

        CFRunLoopRun();
    }
    return 0;
}
