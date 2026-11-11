// chip-input (11 Nov 2026): what a controller player had beside the game on the Mac, rebuilt in the
// AppKit shim because the device can't run the Mac's helpers. #included at the end of the generated
// libspAppKit.m (gen_stubs.py EXTRA_INCLUDES), after spevent.m.
//
// - NSPasteboard. The generated shim had it as a stub class that answers everything with nil, so the
//   game's Cmd+V pasted nothing and its copies went nowhere. Here it's the general pasteboard over
//   UIPasteboard, text only, which is all a game's edit box moves.

// Its own lines, "[sp:AppKit] chip: …", like sploading.m's: these aren't the client's calls into stubs.
// Never the clipboard's or the transcript's text: lengths only (chat goes through both).
static void sp_chip_say(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void sp_chip_say(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    os_log(OS_LOG_DEFAULT, "[sp:AppKit] chip: %{public}s", s.UTF8String);
    fprintf(stderr, "[sp:AppKit] chip: %s\n", s.UTF8String);
}

// ---- NSPasteboard: the general pasteboard, text only, over UIPasteboard.
//
// NSPasteboardTypeString was a zeroed blob in the generated shim (it reads as nil), and a client built
// against it may still pass nil, so nil is text too; so are the legacy and plain-text UTIs. Reading
// another app's text shows iOS's "Allow Paste" prompt (Settings > Slashplayed > Paste from Other Apps
// turns it off); hasStrings, types and changeCount don't, so only an actual paste asks. Text this app
// put there (dictation, the game's own copy) never asks.

static BOOL sp_pb_is_text(id type) {
    if (!type) return YES;
    if (![type isKindOfClass:NSString.class]) return NO;
    return [type isEqual:sp_NSPasteboardTypeString] || [type isEqual:@"NSStringPboardType"] ||
           [type isEqual:@"public.plain-text"] || [type isEqual:@"public.text"];
}

static NSString *sp_pb_read(const char *why) {
    NSString *s = UIPasteboard.generalPasteboard.string;
    static int logged;
    if (logged++ < 20) sp_chip_say(@"pasteboard: %s read %lu chars", why, (unsigned long)s.length);
    return s;
}

static void sp_pb_write(NSString *s, const char *why) {
    UIPasteboard.generalPasteboard.string = s ?: @"";
    static int logged;
    if (logged++ < 20) sp_chip_say(@"pasteboard: %s wrote %lu chars", why, (unsigned long)s.length);
}

@implementation NSPasteboard (SPChipInput)
+ (id)generalPasteboard {
    static id pb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pb = [[self alloc] init]; });
    return pb;
}
- (NSInteger)changeCount {
    return UIPasteboard.generalPasteboard.changeCount;
}
- (NSInteger)clearContents {
    UIPasteboard.generalPasteboard.items = @[];
    return UIPasteboard.generalPasteboard.changeCount;
}
// The older way to start a copy: setString:forType: follows, so nothing is cleared here.
- (NSInteger)declareTypes:(NSArray *)types owner:(id)owner {
    return UIPasteboard.generalPasteboard.changeCount;
}
- (NSArray *)types {
    return UIPasteboard.generalPasteboard.hasStrings ? @[ sp_NSPasteboardTypeString ] : @[];
}
- (NSString *)availableTypeFromArray:(NSArray *)types {
    if (!UIPasteboard.generalPasteboard.hasStrings) return nil;
    for (id type in types)
        if (sp_pb_is_text(type)) return type;
    return nil;
}
- (NSString *)stringForType:(NSString *)type {
    return sp_pb_is_text(type) ? sp_pb_read("stringForType:") : nil;
}
- (NSData *)dataForType:(NSString *)type {
    return sp_pb_is_text(type) ? [sp_pb_read("dataForType:") dataUsingEncoding:NSUTF8StringEncoding] : nil;
}
- (BOOL)setString:(NSString *)string forType:(NSString *)type {
    if (!sp_pb_is_text(type) || ![string isKindOfClass:NSString.class]) return NO;
    sp_pb_write(string, "setString:forType:");
    return YES;
}
- (BOOL)setData:(NSData *)data forType:(NSString *)type {
    NSString *s = sp_pb_is_text(type) && data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!s) return NO;
    sp_pb_write(s, "setData:forType:");
    return YES;
}
@end
