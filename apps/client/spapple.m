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
// the App IDs `app` and `app`.helper: @{@"app": NSData, @"helper": NSData}. Blocks on the network (up to a
// minute or so): never on the main thread. Nil when it can't: *problem says why (no secret in it), and
// *code is Apple's error number when Apple sent one. A re-provisioned anisette identity goes back into the
// keychain with the token.
NSDictionary *sp_apple_profiles(NSString *team, NSString *app, NSString **problem, NSNumber **code) {
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
    return @{@"app": a, @"helper": h};
}
