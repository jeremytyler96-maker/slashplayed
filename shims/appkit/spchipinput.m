// chip-input (11 Nov 2026): the two Mac helpers a controller player had beside the game, rebuilt in the
// AppKit shim because the device can't run them, plus the clipboard both of them (and Cmd+V) need.
// #included at the end of the generated libspAppKit.m (gen_stubs.py EXTRA_INCLUDES), after spevent.m,
// whose event queue it posts to (sp_event, sp_post) and whose pump calls sp_chip_poll.
//
// - NSPasteboard. The generated shim had it as a stub class that answers everything with nil, so the
//   game's Cmd+V pasted nothing and its copies went nowhere. Here it's the general pasteboard over
//   UIPasteboard, text only, which is all a game's edit box moves.
// - Dictation. Hold Share (DualSense Create) and Circle: the microphone records and the speech is
//   transcribed on the device; on release (and a 250 ms tail, so the last word isn't cut off) the text
//   goes to the clipboard as one line and one Cmd+V goes into the client's event queue, where a key
//   from the keyboard would. The Glyph addon opens its own edit box on the same chord and takes the
//   paste; nothing in it changes.
// - Touchpad swipes. A one-finger swipe on a DualSense's (or DualShock 4's) touchpad presses F16 (up),
//   F17 (down), F18 (left), or F19 (right), as the Mac's touchpad daemon did, for addon bindings. The
//   engine's touchpad cursor (GamePadTouchCursorEnable) keeps working: this only reads the touchpad.
//
// Controllers are polled from the client's event pump, never given handlers: the client sets its own
// GameController handlers, a GCControllerElement has one slot for each, and setting ours would silently
// take the client's away. Polling reads the same state without touching them.

#import <AVFAudio/AVFAudio.h>
#import <Speech/Speech.h>

__asm__(".linker_option \"-framework\", \"AVFAudio\"");
__asm__(".linker_option \"-framework\", \"Speech\"");

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

// ---- keys into the client's queue, as spevent.m's sp_key makes them from a keyboard

// A down now and its up 50 ms later. Together they'd reach the client in one pump, and a game that
// reads key state once a frame could see neither; a real key is never that short.
static void sp_chip_tap(unsigned short mac, NSString *chars, BOOL command) {
    BOOL press_command = command && !(sp_mod_flags & SPDevLCmd);  // unless the keyboard's left Command is down
    if (press_command) {
        sp_set_modifier(SPCommand, SPDevLCmd, YES);
        SPEvent *f = sp_event(SPFlagsChanged);
        f->keyCode = 0x37;  // left Command
        sp_post(f);
    }
    unichar fc = sp_function_char(mac);
    NSUInteger extra = fc >= 0xF700 ? SPFunction : 0;
    SPEvent *down = sp_event(SPKeyDown);
    down->keyCode = mac;
    down->characters = down->charactersIgnoringModifiers = chars;
    down->modifierFlags |= extra;
    sp_post(down);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SPEvent *up = sp_event(SPKeyUp);
        up->keyCode = mac;
        up->characters = up->charactersIgnoringModifiers = chars;
        up->modifierFlags |= extra;
        sp_post(up);
        if (press_command) {
            sp_set_modifier(SPCommand, SPDevLCmd, NO);
            SPEvent *f = sp_event(SPFlagsChanged);
            f->keyCode = 0x37;
            sp_post(f);
        }
    });
}

static void sp_chip_function_key(unsigned short mac) {
    unichar fc = sp_function_char(mac);
    sp_chip_tap(mac, [NSString stringWithCharacters:&fc length:1], NO);
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

// ---- the on-screen dot while the microphone is on (top right, above the cursor)

static UIView *sp_chip_dot;

static void sp_chip_show_dot(BOOL on) {
    UIView *root = sp_window.rootViewController.view;
    if (on && !sp_chip_dot && root) {
        sp_chip_dot = [[UIView alloc] initWithFrame:CGRectMake(root.bounds.size.width - 18, 8, 10, 10)];
        sp_chip_dot.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        sp_chip_dot.backgroundColor = UIColor.systemRedColor;
        sp_chip_dot.layer.cornerRadius = 5;
        sp_chip_dot.layer.zPosition = 3000;
        sp_chip_dot.userInteractionEnabled = NO;
        [root addSubview:sp_chip_dot];
    }
    sp_chip_dot.hidden = !on;
}

// ---- dictation
//
// SFSpeechRecognizer with requiresOnDeviceRecognition, never the network. iOS 26's SpeechAnalyzer
// and SpeechTranscriber are Swift-only (no Objective-C interface in the SDK), and the shims are
// Objective-C built with clang alone. English: the device's locale when it's English, else en-US.
//
// The app now has NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription for this, and
// only this records: the client's own capture requests are still answered "denied" and its input
// units refused (spaudiotoolbox.m, "no microphone"), so voice chat stays off. That shim only binds the
// client's imports (rewrite-map.txt applies to the client); this file links the real AVFAudio, whose
// AVAudioEngine goes to the real AudioToolbox. Permission is asked on the first chord, not at launch.
//
// The session: the AudioToolbox shim keeps it Playback, which has no input. While the chord is held
// it's PlayAndRecord, mixing (the game's sound keeps playing), on the speaker rather than the receiver,
// and on Bluetooth headphones' A2DP route rather than HFP's call-quality one; then Playback again.

typedef enum { SPDictIdle, SPDictAsking, SPDictRecording, SPDictTail, SPDictFinishing } SPDictState;
static SPDictState sp_dict_state;
static unsigned sp_dict_gen;  // a recording's number; callbacks from an older one are dropped
static AVAudioEngine *sp_dict_engine;
static SFSpeechAudioBufferRecognitionRequest *sp_dict_request;
static SFSpeechRecognitionTask *sp_dict_task;
static NSString *sp_dict_text;  // the latest transcription, partial until the final one
static NSTimeInterval sp_dict_started;
static BOOL sp_chord_held;
static volatile unsigned sp_dict_buffers; // audio buffers handed to the request this recording
static volatile float sp_dict_peak;       // its loudest sample, 0..1
static const NSTimeInterval sp_chord_grace = 0.2; // s the chord must stay apart to count as let go (sp_chip_poll)
static __weak GCController *sp_dict_controller;

static const char *sp_dict_err(NSError *e) {
    return e ? [NSString stringWithFormat:@"%@ %ld", e.domain, (long)e.code].UTF8String : "";
}

static SFSpeechRecognizer *sp_dict_recognizer(void) {
    static SFSpeechRecognizer *rec;
    if (rec) return rec;
    NSLocale *here = NSLocale.currentLocale;
    NSLocale *locale = [[here objectForKey:NSLocaleLanguageCode] isEqual:@"en"] ? here
                     : [NSLocale localeWithLocaleIdentifier:@"en-US"];
    SFSpeechRecognizer *r = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!r.supportsOnDeviceRecognition && ![locale.localeIdentifier isEqual:@"en-US"]) {
        sp_chip_say(@"dictation: no on-device recognizer for %@, trying en-US", locale.localeIdentifier);
        r = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    }
    if (!r || !r.supportsOnDeviceRecognition) {
        sp_chip_say(@"dictation: on-device speech recognition unavailable (%s); nothing recorded",
                    r ? "no on-device model" : "no recognizer");
        return nil;
    }
    sp_chip_say(@"dictation: recognizer %@, on device", r.locale.localeIdentifier);
    return rec = r;
}

static void sp_dict_session(BOOL record) {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    NSError *err = nil;
    BOOL ok = record
        ? [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker |
                         AVAudioSessionCategoryOptionAllowBluetoothA2DP
                   error:&err]
        : [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers error:&err];
    if (ok) ok = [s setActive:YES error:&err];
    sp_chip_say(@"dictation: session %s: %s%s", record ? "PlayAndRecord" : "Playback", ok ? "ok" : "failed ",
                sp_dict_err(err));
}

// Microphone off, session back to Playback. The transcription carries on with what it has.
static void sp_dict_stop_audio(void) {
    if (!sp_dict_engine) return;
    [sp_dict_engine.inputNode removeTapOnBus:0];
    [sp_dict_engine stop];
    sp_dict_engine = nil;
    sp_dict_session(NO);
    sp_chip_show_dot(NO);
    sp_chip_say(@"dictation: stop, %.1f s recorded, %u buffers, peak %.3f", NSProcessInfo.processInfo.systemUptime - sp_dict_started, sp_dict_buffers, sp_dict_peak);
}

static void sp_dict_cancel(const char *why) {
    if (sp_dict_state == SPDictIdle || sp_dict_state == SPDictAsking) return;
    sp_dict_stop_audio();
    [sp_dict_task cancel];
    sp_dict_task = nil;
    sp_dict_request = nil;
    sp_dict_state = SPDictIdle;
    sp_dict_gen++;
    sp_chip_say(@"dictation: cancelled (%s), nothing pasted", why);
}

// One line, at most 1000 characters (never splitting a composed character), on the clipboard, then
// one Cmd+V.
static void sp_dict_finish(unsigned gen, const char *why) {
    if (gen != sp_dict_gen || sp_dict_state == SPDictIdle) return;
    sp_dict_stop_audio();
    [sp_dict_task cancel];  // done already when it's final; else stop waiting on it
    sp_dict_task = nil;
    sp_dict_request = nil;
    sp_dict_state = SPDictIdle;
    NSArray *words = [sp_dict_text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *line = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
                      componentsJoinedByString:@" "];
    if (line.length > 1000) line = [line substringToIndex:[line rangeOfComposedCharacterSequenceAtIndex:1000].location];
    if (!line.length) {
        sp_chip_say(@"dictation: result (%s): no text, nothing pasted", why);
        return;
    }
    sp_pb_write(line, "dictation");
    sp_chip_tap(0x09 /* V */, @"v", YES);
    sp_chip_say(@"dictation: result (%s): %lu chars, Cmd+V posted", why, (unsigned long)line.length);
}

static void sp_dict_record(void) {
    SFSpeechRecognizer *rec = sp_dict_recognizer();
    if (!rec) return;
    if (!rec.isAvailable) {
        sp_chip_say(@"dictation: recognizer not available right now; nothing recorded");
        return;
    }
    sp_dict_session(YES);
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (format.sampleRate <= 0 || !format.channelCount) {
        sp_chip_say(@"dictation: no audio input (%.0f Hz, %u channels); nothing recorded", format.sampleRate,
                    (unsigned)format.channelCount);
        sp_dict_session(NO);
        return;
    }
    SFSpeechAudioBufferRecognitionRequest *request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    request.requiresOnDeviceRecognition = YES;
    request.shouldReportPartialResults = YES;  // what's heard so far, if the final result is slow to come
    request.addsPunctuation = YES;
    request.taskHint = SFSpeechRecognitionTaskHintDictation;
    unsigned gen = ++sp_dict_gen;
    sp_dict_text = @"";
    sp_dict_task = [rec recognitionTaskWithRequest:request resultHandler:^(SFSpeechRecognitionResult *r, NSError *e) {
        NSString *text = r.bestTranscription.formattedString;
        BOOL final = r.isFinal;
        // iOS's own words for the failure (11 Nov 2026: "kLSRErrorDomain 201" alone was misread as Dictation being off,
        // and it was on). The description is the framework's, never the transcript.
        NSString *err = e ? [NSString stringWithFormat:@"error %@ %ld: %@", e.domain, (long)e.code, e.localizedDescription] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != sp_dict_gen) return;
            if (text) sp_dict_text = text;
            if (final || err) sp_dict_finish(gen, final ? "final" : err.UTF8String);
        });
    }];
    // How much audio reached the request, and how loud it got: told at the stop (sp_dict_buffers, sp_dict_peak).
    sp_dict_buffers = 0;
    sp_dict_peak = 0;
    [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        sp_dict_buffers++;
        float *ch = buf.floatChannelData ? buf.floatChannelData[0] : NULL;
        for (AVAudioFrameCount i = 0; ch && i < buf.frameLength; i++) {
            float v = fabsf(ch[i]);
            if (v > sp_dict_peak) sp_dict_peak = v;
        }
        [request appendAudioPCMBuffer:buf];
    }];
    [engine prepare];
    NSError *err = nil;
    if (![engine startAndReturnError:&err]) {
        [input removeTapOnBus:0];
        [sp_dict_task cancel];
        sp_dict_task = nil;
        sp_dict_gen++;
        sp_dict_session(NO);
        sp_chip_say(@"dictation: microphone didn't start (%s); nothing recorded", sp_dict_err(err));
        return;
    }
    sp_dict_engine = engine;
    sp_dict_request = request;
    sp_dict_state = SPDictRecording;
    sp_dict_started = NSProcessInfo.processInfo.systemUptime;
    sp_chip_show_dot(YES);
    sp_chip_say(@"dictation: start, %.0f Hz %u ch, %@", format.sampleRate, (unsigned)format.channelCount,
                rec.locale.localeIdentifier);
}

static BOOL sp_dict_allowed(BOOL say) {
    AVAudioApplicationRecordPermission mic = AVAudioApplication.sharedInstance.recordPermission;
    SFSpeechRecognizerAuthorizationStatus speech = SFSpeechRecognizer.authorizationStatus;
    if (mic == AVAudioApplicationRecordPermissionGranted && speech == SFSpeechRecognizerAuthorizationStatusAuthorized)
        return YES;
    if (say)
        sp_chip_say(@"dictation: not allowed (microphone %s, speech recognition %s; Settings > Slashplayed); nothing recorded",
                    mic == AVAudioApplicationRecordPermissionGranted ? "allowed"
                    : mic == AVAudioApplicationRecordPermissionDenied ? "denied" : "not asked",
                    speech == SFSpeechRecognizerAuthorizationStatusAuthorized ? "allowed"
                    : speech == SFSpeechRecognizerAuthorizationStatusNotDetermined ? "not asked" : "denied or restricted");
    return NO;
}

// Asked on the first chord. The answer comes after the person taps; if the chord is still held then,
// recording starts, else the next chord records.
static void sp_dict_ask(void) {
    sp_dict_state = SPDictAsking;
    sp_chip_say(@"dictation: asking for microphone and speech recognition");
    void (^done)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            sp_dict_state = SPDictIdle;
            if (!sp_dict_allowed(YES)) return;
            if (sp_chord_held) sp_dict_record();
            else sp_chip_say(@"dictation: allowed; hold Share and Circle again to speak");
        });
    };
    void (^speech)(void) = ^{
        if (SFSpeechRecognizer.authorizationStatus != SFSpeechRecognizerAuthorizationStatusNotDetermined) {
            done();
            return;
        }
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) { done(); }];
    };
    if (AVAudioApplication.sharedInstance.recordPermission == AVAudioApplicationRecordPermissionUndetermined)
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), speech);
        }];
    else
        speech();
}

static void sp_dict_chord_down(GCController *c) {
    switch (sp_dict_state) {
    case SPDictIdle:
        sp_dict_controller = c;
        if (sp_dict_allowed(NO)) {
            sp_dict_record();
        } else if (AVAudioApplication.sharedInstance.recordPermission == AVAudioApplicationRecordPermissionUndetermined ||
                   SFSpeechRecognizer.authorizationStatus == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
            if (AVAudioApplication.sharedInstance.recordPermission != AVAudioApplicationRecordPermissionDenied) sp_dict_ask();
            else sp_dict_allowed(YES);
        } else {
            sp_dict_allowed(YES);
        }
        break;
    case SPDictAsking: break;
    default: sp_chip_say(@"dictation: chord while the last one is still finishing; ignored"); break;
    }
}

static void sp_dict_chord_up(void) {
    if (sp_dict_state != SPDictRecording) return;
    sp_dict_state = SPDictTail;
    unsigned gen = sp_dict_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gen != sp_dict_gen || sp_dict_state != SPDictTail) return;
        sp_dict_stop_audio();
        sp_dict_state = SPDictFinishing;
        [sp_dict_request endAudio];
        // The final result usually follows in well under a second; past 3 s, what was heard so far.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            sp_dict_finish(gen, "timeout");
        });
    });
}

// ---- touchpad swipes
//
// The touchpad's primary finger is a dpad, -1..1 on each axis, and reads 0,0 with no finger on it. A
// contact runs from the first sample off 0,0 to the first back on it. It's a swipe when the larger axis
// travelled at least 0.8 (two-fifths of the pad) and the finger lifted within 0.6 s, with no touchpad click and
// no second finger at any point: a tap or a click never moves that far, and a slow drag (the touchpad
// cursor) takes longer. +y is up, as for GameController's dpads. A jump of most of the pad between two
// samples is a new finger, not a swipe (in case a lift ever goes unseen between samples).

enum { SP_F16 = 0x6A, SP_F17 = 0x40, SP_F18 = 0x4F, SP_F19 = 0x50 };
// 0.8 of the pad's 2.0 (11 Nov 2026, first device test: swipes of 0.95 read as nothing).
static const float sp_swipe_travel = 0.8f, sp_swipe_jump = 0.9f;
static const NSTimeInterval sp_swipe_time = 0.6;

@interface SPChipPad : NSObject {
@public
    BOOL touching, spoiled;
    float x0, y0, x, y;
    NSTimeInterval t0;
}
@end
@implementation SPChipPad
@end

static void sp_swipe_sample(SPChipPad *p, GCControllerDirectionPad *primary, GCControllerDirectionPad *secondary,
                            GCControllerButtonInput *click, NSTimeInterval now) {
    float x = primary.xAxis.value, y = primary.yAxis.value;
    BOOL contact = x != 0 || y != 0;
    BOOL spoil = click.isPressed || secondary.xAxis.value != 0 || secondary.yAxis.value != 0;
    if (p->touching && contact && (fabsf(x - p->x) > sp_swipe_jump || fabsf(y - p->y) > sp_swipe_jump))
        p->touching = NO;
    if (!p->touching) {
        if (!contact) return;
        p->touching = YES;
        p->spoiled = spoil;
        p->x0 = p->x = x;
        p->y0 = p->y = y;
        p->t0 = now;
        return;
    }
    if (contact) {
        p->x = x;
        p->y = y;
        p->spoiled |= spoil;
        return;
    }
    p->touching = NO;
    float dx = p->x - p->x0, dy = p->y - p->y0, ax = fabsf(dx), ay = fabsf(dy);
    NSTimeInterval held = now - p->t0;
    unsigned short key = 0;
    if (!p->spoiled && held <= sp_swipe_time && MAX(ax, ay) >= sp_swipe_travel)
        key = ay > ax ? (dy > 0 ? SP_F16 : SP_F17) : (dx < 0 ? SP_F18 : SP_F19);
    static int logged;
    if (key || logged < 30) {
        logged++;
        sp_chip_say(@"touchpad: contact %.2f s, travel %+.2f,%+.2f%s -> %s", held, dx, dy, p->spoiled ? " (click or 2 fingers)" : "",
                    key == SP_F16 ? "F16" : key == SP_F17 ? "F17" : key == SP_F18 ? "F18" : key == SP_F19 ? "F19" : "none");
    }
    if (key) sp_chip_function_key(key);
}

// ---- controllers

static NSMutableArray<GCController *> *sp_chip_controllers;
static NSMapTable<GCController *, SPChipPad *> *sp_chip_pads;

static void sp_chip_connect(GCController *c) {
    if (!c || [sp_chip_controllers containsObject:c]) return;
    [sp_chip_controllers addObject:c];
    GCExtendedGamepad *gp = c.extendedGamepad;
    BOOL pad = [gp isKindOfClass:GCDualSenseGamepad.class] || [gp isKindOfClass:GCDualShockGamepad.class];
    if (pad) [sp_chip_pads setObject:[[SPChipPad alloc] init] forKey:c];
    // iOS's long press of Create (buttonOptions) takes a screenshot or a recording, and while its
    // recognizer runs, the app sees the press late or never. Share is held as a modifier (Glyph, the
    // dictation chord), so the system's gesture is off for it: GameController's documented opt-out.
    if (gp.buttonOptions) gp.buttonOptions.preferredSystemGestureState = GCSystemGestureStateDisabled;
    sp_chip_say(@"controller connected: %@ (%s)%s%s", c.vendorName, object_getClassName(gp),
                pad ? ", touchpad swipes on" : "", gp.buttonOptions ? ", Share's system gesture off" : "");
}

static void sp_chip_disconnect(GCController *c) {
    if (![sp_chip_controllers containsObject:c]) return;
    [sp_chip_controllers removeObject:c];
    [sp_chip_pads removeObjectForKey:c];
    sp_chip_say(@"controller disconnected: %@", c.vendorName);
    // A controller gone mid-chord isn't a release: nothing is pasted.
    if (c == sp_dict_controller) {
        sp_chord_held = NO;
        sp_dict_cancel("controller disconnected");
    }
}

static void sp_chip_setup(void) {
    sp_chip_controllers = [NSMutableArray array];
    sp_chip_pads = [NSMapTable weakToStrongObjectsMapTable];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { sp_chip_connect(n.object); }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { sp_chip_disconnect(n.object); }];
    // Backgrounded, the system stops the input anyway; the half-heard sentence isn't pasted later.
    [nc addObserverForName:UISceneDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { sp_dict_cancel("app went to the background"); }];
    for (GCController *c in GCController.controllers) sp_chip_connect(c);
}

// From -nextEventMatchingMask:… (spevent.m), which the client calls many times a frame: sampled at
// most every 8 ms.
static void sp_chip_poll(void) {
    static uint64_t last;
    uint64_t now_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now_ns - last < 8000000) return;
    last = now_ns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sp_chip_setup(); });
    NSTimeInterval now = now_ns / 1e9;
    GCController *chord = nil;
    for (GCController *c in sp_chip_controllers) {
        GCExtendedGamepad *gp = c.extendedGamepad;
        if (!chord && gp.buttonOptions.isPressed && gp.buttonB.isPressed) chord = c;
        SPChipPad *p = [sp_chip_pads objectForKey:c];
        if (!p) continue;
        if ([gp isKindOfClass:GCDualSenseGamepad.class]) {
            GCDualSenseGamepad *ds = (GCDualSenseGamepad *)gp;
            sp_swipe_sample(p, ds.touchpadPrimary, ds.touchpadSecondary, ds.touchpadButton, now);
        } else {
            GCDualShockGamepad *ds = (GCDualShockGamepad *)gp;
            sp_swipe_sample(p, ds.touchpadPrimary, ds.touchpadSecondary, ds.touchpadButton, now);
        }
    }
    // A release counts only once the chord has stayed apart for sp_chord_grace (11 Nov 2026, chip-input,
    // the first device test): every recording stopped 0.2-0.3 s in with the buttons held, so one of the
    // two reads up for a sample or two mid-hold. Which one, and how long the chord lasted, is logged.
    static NSTimeInterval chord_t0, apart_since;
    static BOOL share_was, circle_was;
    if (chord) {
        apart_since = 0;
        share_was = circle_was = YES;
        if (!sp_chord_held) {
            sp_chord_held = YES;
            chord_t0 = now;
            sp_dict_chord_down(chord);
        }
    } else if (sp_chord_held) {
        if (apart_since == 0) {
            apart_since = now;
            BOOL share = NO, circle = NO;
            for (GCController *c in sp_chip_controllers) {
                share = share || c.extendedGamepad.buttonOptions.isPressed;
                circle = circle || c.extendedGamepad.buttonB.isPressed;
            }
            share_was = share;
            circle_was = circle;
        }
        if (now - apart_since >= sp_chord_grace) {
            sp_chord_held = NO;
            sp_chip_say(@"dictation: chord up after %.2f s (first to let go: %s)", apart_since - chord_t0,
                        !share_was && !circle_was ? "both" : (!share_was ? "Share" : "Circle"));
            apart_since = 0;
            sp_dict_chord_up();
        }
    }
}
