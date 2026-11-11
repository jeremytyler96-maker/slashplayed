// The Apple token the device keeps, and the one file that touches it. With it the app gets its own renewed
// provisioning profiles from Apple (spapple, the Rust library: spapple/src/lib.rs), which the JIT helper
// installs (spjit.m's sp_jit_profiles), so a free team's 7-day app keeps opening with no computer.
//
// What's kept (owner decisions, 2026-11-02): the xcode.auth app token Apple issues at a sign-in, with the
// adsid it goes with and the anisette server and machine identity it was made on, as one JSON blob in the
// keychain (this device only, never synced). Never the Apple ID's password, and not the GrandSlam token,
// which stops minting app tokens after about an hour. It comes from slashplayed-companion, which pushes it
// at setup as Library/spappletoken.json (0600); the launcher imports it here at its start and wipes the file.
//
// The token is a credential (CLAUDE.md, "The Apple ID is a credential"): nothing here logs it, its size, or
// any of its fields but the stated expiry's date. Requests to spapple carry it in memory only, zeroed after.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#import "spapple/spapple.h"

static NSString *const service = @"Slashplayed Apple token";
static NSString *const account = @"token";
static NSString *const pushed = @"Library/spappletoken.json";

static NSString *home(NSString *relative) { return [NSHomeDirectory() stringByAppendingPathComponent:relative]; }

static NSMutableData *keychain_get(void) {
    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account, (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    }, &out);
    return st == errSecSuccess ? [(__bridge_transfer NSData *)out mutableCopy] : nil;
}

// After first unlock, not only while unlocked: a refresh may one day run in the background.
static OSStatus keychain_put(NSData *value) {
    SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                (__bridge id)kSecAttrService: service, (__bridge id)kSecAttrAccount: account});
    return SecItemAdd((__bridge CFDictionaryRef) @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account, (__bridge id)kSecValueData: value,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        (__bridge id)kSecAttrSynchronizable: @NO,
    }, NULL);
}

static void zero(NSMutableData *d) {
    if (d.length) memset(d.mutableBytes, 0, d.length);
}

// Zeros, then unlink, as launcher.m's wipe. YES if there was a file.
static BOOL wipe(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat st;
    if (!fstat(fd, &st)) {
        static const char zeros[4096];
        for (off_t o = 0; o < st.st_size; o += sizeof zeros) pwrite(fd, zeros, sizeof zeros, o);
        fsync(fd);
    }
    close(fd);
    unlink(path.fileSystemRepresentation);
    return YES;
}

// The fields spapple's Token needs, all there and of the right kinds; nil when not. Only shapes are checked:
// whether Apple still takes the token, only Apple says.
static NSDictionary *parse(NSData *blob) {
    NSDictionary *t = blob.length ? [NSJSONSerialization JSONObjectWithData:blob options:0 error:nil] : nil;
    if (![t isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *k in @[@"token", @"adsid", @"anisette_url"])
        if (![t[k] isKindOfClass:NSString.class] || ![t[k] length]) return nil;
    for (NSString *k in @[@"expiry", @"duration"])
        if (![t[k] isKindOfClass:NSNumber.class]) return nil;
    return t;
}

static NSString *day(NSDate *date) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:date];
}

// Apple's stated expiry is in milliseconds since 1970.
static NSDate *stated_expiry(NSDictionary *t) {
    return [NSDate dateWithTimeIntervalSince1970:[t[@"expiry"] doubleValue] / 1000];
}

NSString *sp_apple_token_import(void) {
    NSMutableData *blob = [[NSData dataWithContentsOfFile:home(pushed)] mutableCopy];
    if (!wipe(home(pushed))) return nil;
    NSDictionary *t = parse(blob);
    NSString *line;
    if (!t) {
        line = @"apple: the pushed token wasn't one; deleted, nothing imported";
    } else {
        OSStatus st = keychain_put(blob);
        line = st == errSecSuccess
                   ? [NSString stringWithFormat:@"apple: imported the pushed token into the keychain (this device only); Apple says "
                                                @"it's good until %@; the pushed file is deleted", day(stated_expiry(t))]
                   : [NSString stringWithFormat:@"apple: the keychain refused the pushed token (%d); the pushed file is deleted", (int)st];
    }
    zero(blob);
    return line;
}

NSString *sp_apple_token_describe(void) {
    NSMutableData *blob = keychain_get();
    NSDictionary *t = parse(blob);
    zero(blob);
    if (!blob) return @"apple: no token";
    if (!t) return @"apple: the keychain's token is unreadable";
    return [NSString stringWithFormat:@"apple: a token, Apple says good until %@", day(stated_expiry(t))];
}

BOOL sp_apple_token_present(void) {
    NSMutableData *blob = keychain_get();
    BOOL ok = parse(blob) != nil;
    zero(blob);
    return ok;
}

NSString *sp_apple_token_forget(void) {
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef) @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                              (__bridge id)kSecAttrService: service});
    BOOL file = wipe(home(pushed));
    return [NSString stringWithFormat:@"apple: %@%@", st == errSecSuccess ? @"forgot the token" : st == errSecItemNotFound
                                                         ? @"no token to forget" : [NSString stringWithFormat:@"couldn't forget the token: keychain %d", (int)st],
            file ? @"; a pushed one not yet imported is deleted too" : @""];
}

// The app's and its helper's renewed profiles from Apple, with the keychain's token, for team `team` and
// the App IDs `app` and `app`.helper: @{@"app": NSData, @"helper": NSData, @"remade": the App IDs made again
// because they'd lapsed}. Blocks on the network (up to a
// minute or so): never on the main thread. Nil when it can't: *problem says why (no secret in it), *code is
// Apple's error number when Apple sent one, and *http the HTTP status when Apple's own servers refused the
// request. A re-provisioned anisette identity goes back into the keychain with the token.
NSDictionary *sp_apple_profiles(NSString *team, NSString *app, NSString **problem, NSNumber **code, NSNumber **http) {
    NSMutableData *blob = keychain_get();
    NSMutableDictionary *token = [parse(blob) mutableCopy];
    zero(blob);
    if (!token) {
        *problem = blob ? @"the keychain's Apple token is unreadable" : @"there's no Apple token on this device";
        return nil;
    }
    NSMutableData *request = [[NSJSONSerialization dataWithJSONObject:@{
        @"op": @"profiles", @"token": token, @"team": team, @"app": app,
        @"helper": [app stringByAppendingString:@".helper"],
    } options:0 error:nil] mutableCopy];
    [request appendBytes:"" length:1];
    char *raw = spapple_call(request.bytes);
    zero(request);
    NSDictionary *reply = raw ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:strlen(raw)] options:0 error:nil] : nil;
    if (raw) spapple_free(raw);
    if (![reply isKindOfClass:NSDictionary.class]) {
        *problem = @"spapple's reply didn't parse";
        return nil;
    }
    if (![reply[@"ok"] boolValue]) {
        *problem = [reply[@"error"] isKindOfClass:NSString.class] ? reply[@"error"] : @"no reason given";
        if ([reply[@"code"] isKindOfClass:NSNumber.class]) *code = reply[@"code"];
        if ([reply[@"http_status"] isKindOfClass:NSNumber.class]) *http = reply[@"http_status"];
        return nil;
    }
    NSString *state = reply[@"anisette_state"];
    if ([state isKindOfClass:NSString.class] && state.length) {
        token[@"anisette_state"] = state;
        NSMutableData *updated = [[NSJSONSerialization dataWithJSONObject:token options:0 error:nil] mutableCopy];
        OSStatus st = keychain_put(updated);
        zero(updated);
        if (st != errSecSuccess) {
            *problem = [NSString stringWithFormat:@"the keychain refused the token's new anisette identity (%d)", (int)st];
            return nil;
        }
    }
    NSData *a = [[NSData alloc] initWithBase64EncodedString:reply[@"app"] ?: @"" options:0];
    NSData *h = [[NSData alloc] initWithBase64EncodedString:reply[@"helper"] ?: @"" options:0];
    if (!a.length || !h.length) {
        *problem = @"Apple's reply had no profile";
        return nil;
    }
    NSArray *remade = [reply[@"remade"] isKindOfClass:NSArray.class] ? reply[@"remade"] : @[];
    return @{@"app": a, @"helper": h, @"remade": remade};
}

// ---- Renewing the app's profiles at launch

NSArray<NSDictionary *> *sp_jit_profiles(NSArray<NSData *> *install, void (^pump)(double), NSString **problem);  // spjit.m
NSDictionary *sp_profile_plist(NSData *profile);  // spjit.m
NSString *sp_profile_app_id(NSData *profile);  // spjit.m
NSString *sp_app_id(void);  // spjit.m
void sp_launch_say(NSString *s);  // launcher.m

static void say(NSString *s) { sp_launch_say([@"renew: " stringByAppendingString:s]); }

// Renew when the app's latest profile has less than this left (owner, 2026-11-03: about 3 days, so a week's
// free profile renews on any launch in its last 3 days).
static const double renew_within = 3 * 86400;

// Copies of the profiles a renewal installed: iOS checks the app against every installed profile, but the
// app can't read the device's list without the helper's tunnel, so these are what it knows it has.
static NSString *copies_dir(void) { return home(@"Library/spprofiles"); }

static NSArray<NSString *> *sp_profile_copies(void) {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:copies_dir() error:nil])
        if ([name.pathExtension isEqual:@"mobileprovision"]) [paths addObject:[copies_dir() stringByAppendingPathComponent:name]];
    return paths;
}

static NSString *app_dir(void) { return NSBundle.mainBundle.bundlePath; }

// The latest expiry of the profiles the launcher knows for one App ID: the embedded ones (the app's and its
// helper's) and the renewals' copies. Nil when there's none.
static NSDate *latest_for(NSString *appid, NSArray<NSString *> *paths) {
    NSDate *latest = nil;
    for (NSString *path in paths) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (!appid || ![sp_profile_app_id(d) isEqual:appid]) continue;
        NSDate *e = sp_profile_plist(d)[@"ExpirationDate"];
        if ([e isKindOfClass:NSDate.class] && (!latest || [e compare:latest] == NSOrderedDescending)) latest = e;
    }
    return latest;
}

// When the app stops opening: the earlier of its own profiles' last day and its helper's, since without the
// helper's (PlugIns/SPJitHelper.appex, App ID <app>.helper) no game loads either. Both come from one renewal,
// so they match in practice. Nil when the app's can't be told; the app's alone when the helper's can't.
NSDate *sp_profile_expiry(void) {
    NSString *appid = sp_app_id();
    NSMutableArray *paths = [NSMutableArray arrayWithObjects:[app_dir() stringByAppendingPathComponent:@"embedded.mobileprovision"],
                             [app_dir() stringByAppendingPathComponent:@"PlugIns/SPJitHelper.appex/embedded.mobileprovision"], nil];
    [paths addObjectsFromArray:sp_profile_copies()];
    NSDate *app = latest_for(appid, paths), *helper = latest_for([appid stringByAppendingString:@".helper"], paths);
    return app && helper && [helper compare:app] == NSOrderedAscending ? helper : app;
}

// The start screen's word on the renewal (Library/sprenew.txt, one line): "ok <time>" (the app's profiles
// last until then), "signin <time>" (renewing needs a new Apple token on this device, and the app stops
// opening at that time), or "failed <time>" (it couldn't renew this time; it tries again next launch). The
// time is ISO 8601 in UTC, so the note can give the person's own day; "unknown" when it can't be told.
static void write_state(NSString *word, NSDate *until) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", word, until ? [[NSISO8601DateFormatter new] stringFromDate:until] : @"unknown"];
    [line writeToFile:home(@"Library/sprenew.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// What the start screen says under the games about the renewal, from Library/sprenew.txt: nothing when it's
// fine (or nothing's been tried yet), else why the app may stop opening, with the day, in the person's words.
NSString *sp_profiles_note(void) {
    NSString *line = [NSString stringWithContentsOfFile:home(@"Library/sprenew.txt") encoding:NSUTF8StringEncoding error:nil];
    NSArray *parts = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@" "];
    if (parts.count != 2 || [parts[0] isEqual:@"ok"]) return nil;
    NSDate *until = [[NSISO8601DateFormatter new] dateFromString:parts[1]];
    if (until && until.timeIntervalSinceNow < 0) return nil;  // past it the app doesn't open, so a note left is stale
    NSString *when = @"soon";
    if (until && [NSCalendar.currentCalendar isDateInToday:until]) when = @"later today";
    else if (until && [NSCalendar.currentCalendar isDateInTomorrow:until]) when = @"tomorrow";
    else if (until) when = [@"on " stringByAppendingString:[NSDateFormatter localizedStringFromDate:until dateStyle:NSDateFormatterMediumStyle
                                                                                            timeStyle:NSDateFormatterNoStyle]];
    if ([parts[0] isEqual:@"signin"])
        return [NSString stringWithFormat:@"Slashplayed can’t renew its signing on its own, so it stops opening %@. Before then, "
                                          @"run Slashplayed Companion again on the computer you set it up with.", when];
    return [NSString stringWithFormat:@"Slashplayed couldn’t renew its signing. It tries again the next time a game starts "
                                      @"online, and stops opening %@ if it can’t.", when];
}

// Deletes the copies that have expired: they list nothing and keep the app open no longer.
static void prune_copies(void) {
    for (NSString *path in sp_profile_copies()) {
        NSDate *e = sp_profile_plist([NSData dataWithContentsOfFile:path])[@"ExpirationDate"];
        if (![e isKindOfClass:NSDate.class] || e.timeIntervalSinceNow < 0) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
}

// Apple's refusals that mean the token itself no longer works, so only a new sign-in helps (as opposed to the
// network or Apple being down, which the next launch retries). GrandSlam's auth errors, and the developer
// services' "not signed in" family, and a 401 from Apple's own servers (spapple's http_status, never another
// server's). Never the problem's text: it names team and bundle IDs, URLs, and the anisette server's errors,
// where a "401" says nothing about the token. Anything unknown counts as a retry, never as a reason to ask.
static BOOL token_refused(NSNumber *code, NSNumber *http) {
    if (http.integerValue == 401) return YES;
    if (!code) return NO;
    long c = code.longValue;
    return c == 1100 || c == 1101 || c == 401 || (c <= -22000 && c > -23000);
}

// Every launch of a game, before the helper attaches: when the app's profiles have less than 3 days left
// (SP_RENEW=now: whatever's left; SP_RENEW=off: never), new ones from Apple with the keychain's token, installed
// by the helper, with copies kept in Library/spprofiles. It never stops the launch: the profiles still have
// days left, and the start screen says when the next launch can't fix it alone (Library/sprenew.txt).
void sp_profiles_renew(void (^pump)(double)) {
    NSString *mode = NSProcessInfo.processInfo.environment[@"SP_RENEW"];
    if ([mode isEqual:@"off"]) return;
    prune_copies();
    NSDate *until = sp_profile_expiry();
    double left = until ? until.timeIntervalSinceNow : 0;
    if (![mode isEqual:@"now"] && until && left > renew_within) {
        write_state(@"ok", until);
        return;
    }
    NSString *appid = sp_app_id();
    NSRange dot = [appid rangeOfString:@"."];
    if (dot.location == NSNotFound) {
        say(@"no App ID in the embedded profile; not renewing");
        return;
    }
    say([NSString stringWithFormat:@"the app's profiles last until %@ (%.1f days)%@", until ? day(until) : @"an unknown day",
         left / 86400, [mode isEqual:@"now"] ? @"; renewing now (SP_RENEW=now)" : @"; renewing"]);
    if (!sp_apple_token_present()) {
        say(@"no Apple token: renewing needs an Apple sign-in on this device");
        write_state(@"signin", until);
        return;
    }
    // Off the main thread (it blocks on the network), with the launch's pump turning meanwhile. Waited for up to
    // 60 s: past that the launch goes on, since the profiles still have days left, and the next launch retries.
    __block NSDictionary *got = nil;
    __block NSString *why = nil;
    __block NSNumber *code = nil, *http = nil;
    __block BOOL done = NO;
    NSObject *lock = [NSObject new];
    double t = CFAbsoluteTimeGetCurrent();
    NSString *team = [appid substringToIndex:dot.location], *bundle = [appid substringFromIndex:dot.location + 1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *w = nil;
        NSNumber *c = nil, *h = nil;
        NSDictionary *g = sp_apple_profiles(team, bundle, &w, &c, &h);
        @synchronized (lock) {
            got = g, why = w, code = c, http = h, done = YES;
        }
    });
    for (double end = CFAbsoluteTimeGetCurrent() + 60;;) {
        @synchronized (lock) {
            if (done) break;
        }
        if (CFAbsoluteTimeGetCurrent() > end) {
            say(@"Apple didn't answer within 60 s; the next launch tries again");
            write_state(@"failed", until);
            return;
        }
        pump(0.05);
    }
    if (!got) {
        BOOL refused = token_refused(code, http);
        say([NSString stringWithFormat:@"Apple's profiles didn't come after %.2f s (%@%@%@)%@", CFAbsoluteTimeGetCurrent() - t, why,
             code ? [NSString stringWithFormat:@", code %@", code] : @"", http ? [NSString stringWithFormat:@", HTTP %@", http] : @"",
             refused ? @": the token no longer works" : @"; the next launch tries again"]);
        write_state(refused ? @"signin" : @"failed", until);
        return;
    }
    say([NSString stringWithFormat:@"Apple's profiles in %.2f s%@", CFAbsoluteTimeGetCurrent() - t,
         [got[@"remade"] count] ? [NSString stringWithFormat:@", after making %lu lapsed App ID(s) again", (unsigned long)[got[@"remade"] count]] : @""]);
    NSString *problem = nil;
    NSArray *mine = sp_jit_profiles(@[got[@"app"], got[@"helper"]], pump, &problem);
    if (!mine) {
        // Not the launch's problem: the attach right after says what's wrong with the helper, if anything is.
        say([@"the helper didn't install them: " stringByAppendingString:problem ?: @"no reason"]);
        write_state(@"failed", until);
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:copies_dir() withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *which in @[@"app", @"helper"]) {
        NSData *d = got[which];
        NSString *uuid = sp_profile_plist(d)[@"UUID"];
        if ([uuid isKindOfClass:NSString.class]) [d writeToFile:[copies_dir() stringByAppendingPathComponent:[uuid stringByAppendingPathExtension:@"mobileprovision"]] atomically:YES];
    }
    NSDate *now = sp_profile_expiry();
    say([NSString stringWithFormat:@"renewed: the app's profiles last until %@", now ? day(now) : @"an unknown day"]);
    write_state(@"ok", now);
    return;
}
