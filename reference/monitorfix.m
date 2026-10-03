// monitorfix: keeps the ASUS XG27ACDNG at 2560x1440@325Hz HDR next to a second external on an M4 Pro.
// Sleeps until macOS reports a display change; then, when the XG27 shows its factory EDID, injects a modified EDID (adds 320/325/345Hz
// single-pipe timings), sets 325Hz + HDR, rotates the Dell AW2521HF to portrait, and restores the layout.
// Build: clang -fobjc-arc -framework Foundation -framework AppKit -framework IOKit -framework CoreGraphics -o monitorfix monitorfix.m
// Run once: ./monitorfix --once    Daemon: ./monitorfix    Undo override: ./monitorfix --reset
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>

static const uint32_t XG_VENDOR = 1715, XG_MODEL = 10228, AW_VENDOR = 4268, AW_MODEL = 41312;
static const int XG_HZ = 325, AW_ROTATION = 270;

typedef CFTypeRef (*CreateF)(CFAllocatorRef, io_service_t);
typedef IOReturn (*SetF)(CFTypeRef, uint32_t, CFDataRef);
typedef IOReturn (*CopyF)(CFTypeRef, CFDataRef *);
static CreateF avCreate; static SetF avSetVirtualEDID; static CopyF avCopyEDID;
static NSData *origEDID, *modEDID;

static void logf_(NSString *s) { NSLog(@"monitorfix: %@", s); }

// Find the AV service whose current EDID is the XG27 (vendor 06b3, product 0x27f4).
static CFTypeRef xgService(NSData **current) {
    io_iterator_t it; CFTypeRef found = NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it)) return NULL;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        CFTypeRef av = avCreate(kCFAllocatorDefault, s); IOObjectRelease(s);
        if (!av) continue;
        CFDataRef e = NULL; avCopyEDID(av, &e);
        NSData *ed = (__bridge_transfer NSData *)e;
        const uint8_t *b = ed.bytes;
        if (!found && ed.length >= 12 && b[8] == 0x06 && b[9] == 0xb3 && b[10] == 0xf4 && b[11] == 0x27) { found = av; *current = ed; }
        else CFRelease(av);
    }
    IOObjectRelease(it);
    return found;
}

static CGDirectDisplayID findDisplay(uint32_t vendor, uint32_t model) {
    uint32_t n = 0; CGDirectDisplayID ids[16];
    CGGetOnlineDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) if (CGDisplayVendorNumber(ids[i]) == vendor && CGDisplayModelNumber(ids[i]) == model) return ids[i];
    return 0;
}

static id mpDisplay(CGDirectDisplayID d) {
    id mgr = [NSClassFromString(@"MPDisplayMgr") new];
    for (id x in [mgr valueForKey:@"displays"]) if ([[x valueForKey:@"displayID"] unsignedIntValue] == d) return x;
    return nil;
}

static BOOL setRefresh(CGDirectDisplayID d, int hz) {
    NSArray *modes = (__bridge_transfer NSArray *)CGDisplayCopyAllDisplayModes(d, NULL);
    for (id o in modes) {
        CGDisplayModeRef m = (__bridge CGDisplayModeRef)o;
        if (CGDisplayModeGetPixelWidth(m) == 2560 && CGDisplayModeGetWidth(m) == 2560 && lround(CGDisplayModeGetRefreshRate(m)) == hz) {
            CGDisplayConfigRef c; CGBeginDisplayConfiguration(&c);
            CGConfigureDisplayWithDisplayMode(c, d, m, NULL);
            CGError e = CGCompleteDisplayConfiguration(c, kCGConfigurePermanently);
            logf_([NSString stringWithFormat:@"set %dHz: %d", hz, e]);
            return e == kCGErrorSuccess;
        }
    }
    return NO;
}

// User's arrangement, in points relative to the built-in display at (0,0):
// XG27 directly above the MacBook, AW2521HF (portrait) to the left of both.
static void applyLayout(void) {
    if (CGMainDisplayID() == 0 || !CGDisplayIsBuiltin(CGMainDisplayID())) { logf_(@"built-in not main, layout skipped"); return; }
    CGDirectDisplayID xg = findDisplay(XG_VENDOR, XG_MODEL), aw = findDisplay(AW_VENDOR, AW_MODEL);
    CGDisplayConfigRef c; CGBeginDisplayConfiguration(&c);
    if (xg) CGConfigureDisplayOrigin(c, xg, 0, -1440);
    if (aw) CGConfigureDisplayOrigin(c, aw, -1080, -1080);
    logf_([NSString stringWithFormat:@"layout: %d", CGCompleteDisplayConfiguration(c, kCGConfigurePermanently)]);
}

// Per-connection progress; reset when a monitor disappears so each fresh plug-in gets set up once,
// and manual changes made afterwards (e.g. picking 345Hz) are left alone.
static BOOL hzDone, hdrDone, layoutDone, awRotDone;
static CFAbsoluteTime injectedAt;

// One pass over the setup. Returns YES when nothing is left to do (so the helper can go idle).
static BOOL step(void) {
    CGDirectDisplayID xg = findDisplay(XG_VENDOR, XG_MODEL), aw = findDisplay(AW_VENDOR, AW_MODEL);
    if (!aw) awRotDone = NO;
    if (!xg) hzDone = hdrDone = layoutDone = NO;
    if (aw && !awRotDone) {
        id a = mpDisplay(aw);
        if (a) { if ([[a valueForKey:@"orientation"] intValue] != AW_ROTATION) [a setValue:@(AW_ROTATION) forKey:@"orientation"]; awRotDone = YES; logf_(@"rotation set"); }
    }
    if (!xg) return (awRotDone || !aw) && CFAbsoluteTimeGetCurrent() - injectedAt > 8; // XG blinks offline right after an inject
    NSData *cur = nil; CFTypeRef av = xgService(&cur);
    if (!av) return NO;                                    // AV service not ready yet
    if ([cur isEqualToData:origEDID]) {                    // fresh plug-in or wake reset the override
        hzDone = hdrDone = layoutDone = NO;
        if (CFAbsoluteTimeGetCurrent() - injectedAt > 3) {
            logf_([NSString stringWithFormat:@"inject EDID: 0x%x", avSetVirtualEDID(av, 1, (__bridge CFDataRef)modEDID)]);
            injectedAt = CFAbsoluteTimeGetCurrent();
        }
        CFRelease(av); return NO;
    }
    CFRelease(av);
    if (![cur isEqualToData:modEDID]) { if (!hzDone) logf_(@"XG27 EDID differs from saved factory copy, skipping"); hzDone = hdrDone = layoutDone = YES; return YES; }
    if (!hzDone) {
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(xg); long hz = lround(CGDisplayModeGetRefreshRate(m)); CGDisplayModeRelease(m);
        if (hz != XG_HZ && !setRefresh(xg, XG_HZ)) return NO; // new modes not listed yet
        hzDone = YES;
    }
    if (!hdrDone) {
        id x = mpDisplay(xg);
        if (!x || ![[x valueForKey:@"hasHDRModes"] boolValue]) return NO;
        if (![[x valueForKey:@"preferHDRModes"] boolValue]) [x setValue:@YES forKey:@"preferHDRModes"];
        hdrDone = YES; logf_(@"HDR on");
    }
    if (!layoutDone) {
        if (aw && CGDisplayBounds(aw).size.width != 1080) return NO; // wait for portrait rotation to land
        applyLayout(); layoutDone = YES;
    }
    return YES;
}

// Short burst of 0.25s checks after a display event, then fully idle (no timers) until the next event.
static NSTimer *burstTimer; static CFAbsoluteTime burstEnd;
static void startBurst(void) {
    burstEnd = CFAbsoluteTimeGetCurrent() + 20;
    if (burstTimer) return;
    burstTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        BOOL done = step();
        if (done || CFAbsoluteTimeGetCurrent() > burstEnd) { [t invalidate]; burstTimer = nil; if (!done) logf_(@"gave up until next display event"); }
    }];
    burstTimer.tolerance = 0.05;
}

static void onReconfig(CGDirectDisplayID d, CGDisplayChangeSummaryFlags f, void *u) {
    if (!(f & kCGDisplayBeginConfigurationFlag)) startBurst();
}

int main(int argc, char **argv) { @autoreleasepool {
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_NOW);
    avCreate = dlsym(io, "IOAVServiceCreateWithService"); avSetVirtualEDID = dlsym(io, "IOAVServiceSetVirtualEDIDMode"); avCopyEDID = dlsym(io, "IOAVServiceCopyEDID");
    if (!avCreate || !avSetVirtualEDID || !avCopyEDID) { logf_(@"private IOAVService API missing on this macOS"); return 1; }
    NSString *dir = [@(argv[0]) stringByDeletingLastPathComponent];
    origEDID = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"xg27.orig.bin"]];
    modEDID = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"xg27.mod.bin"]];
    if (!origEDID || !modEDID) { logf_(@"EDID files missing next to binary"); return 1; }
    NSString *arg = argc > 1 ? @(argv[1]) : @"";
    if ([arg isEqual:@"--reset"]) { NSData *c; CFTypeRef av = xgService(&c); if (av) { avSetVirtualEDID(av, 0, NULL); CFRelease(av); } logf_(@"override cleared"); return 0; }
    // A plain CLI run loop gets no display-change callbacks for other processes' changes; a (windowless, Dock-less) NSApp loop does.
    [NSApplication sharedApplication].activationPolicy = NSApplicationActivationPolicyProhibited;
    CGDisplayRegisterReconfigurationCallback(onReconfig, NULL);
    startBurst();
    if ([arg isEqual:@"--once"]) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:21]]; return 0; }
    [NSApp run];
    return 0;
}}
