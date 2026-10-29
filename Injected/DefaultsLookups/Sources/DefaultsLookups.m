// DefaultsLookups — lets a running app say which preferences it has looked up.
//
// A setting nobody has stored yet exists only in the app's code: its key is
// a Swift string literal and its `@AppStorage` default never leaves Swift. The
// one moment it becomes visible is when the app reads it, so this listens to
// the reads, keeps the set in memory, and writes it — whole, as the app's
// current answer — to /tmp/BaguetteLookups-<udid>-<bundle id>.plist, which
// `SimctlDefaults.lookups(of:)` reads and `PreferenceLookups(answer:)` parses.
//
// Measured against a real SwiftUI app on iOS 27.0 (docs/features/defaults/design.md):
//
//   - `@AppStorage` reads through -[NSUserDefaults stringForKey:] (and the
//     other typed getters), called from SwiftUI. The app's own
//     `UserDefaults.standard.bool(forKey:)` is called from the app's image.
//     So the getters are where to listen, and the getter names the type.
//   - UIKit, Metal, CoreText, … read ~50 keys of their own. The *immediate*
//     caller tells them apart: only reads made by an image inside the app
//     bundle, or by SwiftUI on the app's behalf, are the app's. A stack walk
//     can't: in a debug build every stack passes through the app's
//     .debug.dylib (that is where `main` lives).
//   - Hooking _CFPreferencesCopyAppValue… instead sees nothing: Foundation's
//     calls into CoreFoundation never leave the shared cache, so dyld
//     interposing doesn't reach them.
//
// Two traps the probe hit, both guarded below: KVC on NSUserDefaults
// (`valueForKey:`) routes back through `objectForKey:`, so anything this file
// does inside a hook must not read defaults (the thread-local `gInside`); and
// `class_getInstanceMethod` returns an inherited method, so swizzling a
// selector NSUserDefaults doesn't define itself would change NSObject.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <os/log.h>

static NSString *gAnswerPath;
static NSString *gBundlePath;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableOrderedSet<NSArray *> *gLookups;        // @[key, suite or NSNull, getter, by]
static NSMutableOrderedSet<NSArray *> *gObserved;       // @[key, suite or NSNull], watched by SwiftUI
static NSMutableDictionary<NSArray *, id> *gRegistered; // @[key, suite or NSNull] -> value
static BOOL gWriteScheduled;
static dispatch_queue_t gWriter;
static __thread int gInside;
static const void *kSuiteKey = &kSuiteKey;

static os_log_t Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.baguette.defaults", "lookups"); });
    return log;
}

/// Who made a call, by its immediate caller: @"app" for an image inside
/// the app bundle (its binary, its .debug.dylib, its own frameworks),
/// @"swiftui" for SwiftUI, nil for anyone else. SwiftUI reads for
/// `@AppStorage` *and* for its own flags; `PreferenceLookups` tells the two
/// apart by whether SwiftUI also observes the key, so both are reported.
static NSString *Caller(void *returnAddress) {
    Dl_info info;
    if (!dladdr(returnAddress, &info) || !info.dli_fname) return nil;
    const char *image = info.dli_fname;
    if (strncmp(image, gBundlePath.UTF8String, gBundlePath.length) == 0) return @"app";
    const char *name = strrchr(image, '/');
    return name && strcmp(name, "/SwiftUI") == 0 ? @"swiftui" : nil;
}

/// The suite a defaults object was made for, or NSNull for the app's
/// standard defaults. Remembered at `initWithSuiteName:` rather than read
/// off the object, which would mean reading defaults inside a hook.
static id SuiteOf(NSUserDefaults *defaults) {
    return objc_getAssociatedObject(defaults, kSuiteKey) ?: NSNull.null;
}

/// Where this app writes its answer, or nil when it can't answer (no
/// SIMULATOR_UDID or bundle id). Exported: Injected/build.sh refuses a dylib
/// with no exported symbols (an empty one once shipped and did nothing), and
/// everything else here is static.
__attribute__((visibility("default")))
NSString *DefaultsLookupsAnswerPath(void) {
    return gAnswerPath;
}

static void WriteAnswer(void) {
    os_unfair_lock_lock(&gLock);
    gWriteScheduled = NO;
    NSMutableArray *lookups = [NSMutableArray arrayWithCapacity:gLookups.count];
    for (NSArray *entry in gLookups) {
        NSMutableDictionary *row = [@{ @"key": entry[0], @"getter": entry[2], @"by": entry[3] } mutableCopy];
        if (entry[1] != NSNull.null) row[@"suite"] = entry[1];
        [lookups addObject:row];
    }
    NSMutableArray *observed = [NSMutableArray arrayWithCapacity:gObserved.count];
    for (NSArray *slot in gObserved) {
        NSMutableDictionary *row = [@{ @"key": slot[0] } mutableCopy];
        if (slot[1] != NSNull.null) row[@"suite"] = slot[1];
        [observed addObject:row];
    }
    NSMutableArray *registered = [NSMutableArray arrayWithCapacity:gRegistered.count];
    [gRegistered enumerateKeysAndObjectsUsingBlock:^(NSArray *slot, id value, BOOL *stop) {
        NSMutableDictionary *row = [@{ @"key": slot[0], @"value": value } mutableCopy];
        if (slot[1] != NSNull.null) row[@"suite"] = slot[1];
        [registered addObject:row];
    }];
    os_unfair_lock_unlock(&gLock);

    NSDictionary *answer = @{
        @"pid": @(getpid()), @"lookups": lookups, @"registered": registered, @"observed": observed,
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:answer
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:NULL];
    // Atomic: baguette reads this at any moment and must see a whole answer.
    [data writeToFile:gAnswerPath atomically:YES];
}

/// Coalesce: an app reads dozens of keys while its first screen builds, and
/// the answer only needs to land once they settle.
static void ScheduleWrite(void) {
    if (gWriteScheduled) return;
    gWriteScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), gWriter, ^{ WriteAnswer(); });
}

static void Heard(NSString *key, NSUserDefaults *defaults, NSString *getter, void *returnAddress) {
    if (gInside || ![key isKindOfClass:NSString.class]) return;
    NSString *by = Caller(returnAddress);
    if (!by) return;
    gInside = 1;
    NSArray *entry = @[ key, SuiteOf(defaults), getter, by ];
    os_unfair_lock_lock(&gLock);
    if (![gLookups containsObject:entry]) {
        [gLookups addObject:entry];
        ScheduleWrite();
    }
    os_unfair_lock_unlock(&gLock);
    gInside = 0;
}

/// The method NSUserDefaults defines *itself* for `selector`, or NULL —
/// never one it inherits, whose swizzle would reach every NSObject.
static Method OwnMethod(SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(NSUserDefaults.class, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count && !found; i++) {
        if (method_getName(methods[i]) == selector) found = methods[i];
    }
    free(methods);
    return found;
}

/// Listen to one `-<getter>ForKey:` without changing what it returns.
#define LISTEN(SELECTOR, RETURN, GETTER) do { \
    SEL sel = @selector(SELECTOR); \
    Method method = OwnMethod(sel); \
    if (!method) { os_log(Log(), "no %{public}s on NSUserDefaults", sel_getName(sel)); break; } \
    RETURN (*original)(id, SEL, NSString *) = (void *)method_getImplementation(method); \
    method_setImplementation(method, imp_implementationWithBlock(^RETURN(NSUserDefaults *self_, NSString *key) { \
        void *caller = __builtin_return_address(0); \
        RETURN value = original(self_, sel, key); \
        Heard(key, self_, GETTER, caller); \
        return value; \
    })); \
} while (0)

static void ListenToSuites(void) {
    SEL sel = @selector(initWithSuiteName:);
    Method method = OwnMethod(sel);
    if (!method) return;
    id (*original)(id, SEL, NSString *) = (void *)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^id(NSUserDefaults *self_, NSString *suite) {
        NSUserDefaults *made = original(self_, sel, suite);
        // A suite named for the app itself is its standard defaults.
        if (made && suite.length && ![suite isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {
            objc_setAssociatedObject(made, kSuiteKey, [suite copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return made;
    }));
}

static void ListenToRegistrations(void) {
    SEL sel = @selector(registerDefaults:);
    Method method = OwnMethod(sel);
    if (!method) return;
    void (*original)(id, SEL, NSDictionary *) = (void *)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^(NSUserDefaults *self_, NSDictionary *fallbacks) {
        void *caller = __builtin_return_address(0);
        original(self_, sel, fallbacks);
        if (gInside || !Caller(caller)) return;
        gInside = 1;
        id suite = SuiteOf(self_);
        os_unfair_lock_lock(&gLock);
        [fallbacks enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            // Only what a plist can carry: the answer is a plist.
            if (![key isKindOfClass:NSString.class]
                || ![NSPropertyListSerialization propertyList:value
                                             isValidForFormat:NSPropertyListBinaryFormat_v1_0]) return;
            gRegistered[@[ key, suite ]] = value;
        }];
        ScheduleWrite();
        os_unfair_lock_unlock(&gLock);
        gInside = 0;
    }));
}

/// `@AppStorage` observes its key so the view updates when it changes;
/// SwiftUI's own flags are read but never observed. That is the line
/// between them, so the keys SwiftUI observes are part of the answer.
static void ListenToObservers(void) {
    // NSUserDefaults inherits this from NSObject (measured, iOS 27.0), so
    // it gets an override of its own that forwards to the inherited one —
    // swizzling the inherited method would reach every observed object.
    SEL sel = @selector(addObserver:forKeyPath:options:context:);
    Method inherited = class_getInstanceMethod(NSUserDefaults.class, sel);
    if (!inherited || OwnMethod(sel)) { os_log(Log(), "addObserver:forKeyPath: not inherited as expected"); return; }
    void (*original)(id, SEL, id, NSString *, NSKeyValueObservingOptions, void *) = (void *)method_getImplementation(inherited);
    class_addMethod(NSUserDefaults.class, sel, imp_implementationWithBlock(
        ^(NSUserDefaults *self_, id observer, NSString *keyPath, NSKeyValueObservingOptions options, void *context) {
        void *caller = __builtin_return_address(0);
        original(self_, sel, observer, keyPath, options, context);
        if (gInside || ![keyPath isKindOfClass:NSString.class]
            || ![Caller(caller) isEqualToString:@"swiftui"]) return;
        gInside = 1;
        NSArray *slot = @[ keyPath, SuiteOf(self_) ];
        os_unfair_lock_lock(&gLock);
        if (![gObserved containsObject:slot]) {
            [gObserved addObject:slot];
            ScheduleWrite();
        }
        os_unfair_lock_unlock(&gLock);
        gInside = 0;
    }), method_getTypeEncoding(inherited));
}

__attribute__((constructor)) static void DefaultsLookupsLoad(void) {
    const char *udid = getenv("SIMULATOR_UDID");
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    // Without both there is no file baguette would look for.
    if (!udid || !bundleID.length) return;

    gAnswerPath = [NSString stringWithFormat:@"/tmp/BaguetteLookups-%s-%@.plist", udid, bundleID];
    gBundlePath = [NSBundle.mainBundle.bundlePath stringByAppendingString:@"/"];
    gLookups = [NSMutableOrderedSet orderedSet];
    gObserved = [NSMutableOrderedSet orderedSet];
    gRegistered = [NSMutableDictionary dictionary];
    gWriter = dispatch_queue_create("com.baguette.defaults.lookups", DISPATCH_QUEUE_SERIAL);

    ListenToSuites();
    ListenToRegistrations();
    ListenToObservers();
    LISTEN(objectForKey:, id, @"object");
    LISTEN(stringForKey:, NSString *, @"string");
    LISTEN(boolForKey:, BOOL, @"bool");
    LISTEN(integerForKey:, NSInteger, @"integer");
    LISTEN(doubleForKey:, double, @"double");
    LISTEN(floatForKey:, float, @"float");
    LISTEN(arrayForKey:, NSArray *, @"array");
    LISTEN(dictionaryForKey:, NSDictionary *, @"dictionary");
    LISTEN(stringArrayForKey:, NSArray *, @"stringArray");
    LISTEN(dataForKey:, NSData *, @"data");
    LISTEN(URLForKey:, NSURL *, @"url");

    // Answer at once, empty: a running app that has read nothing yet still
    // answers — "nothing yet" — rather than looking like one that can't.
    dispatch_async(gWriter, ^{ WriteAnswer(); });
    os_log(Log(), "listening for %{public}@ → %{public}@", bundleID, gAnswerPath);
}
