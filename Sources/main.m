// Ramble — talk, and it types. A menu-bar dictation app that runs entirely on this Mac.
// ⌃⌥Space   dictate and paste at the cursor
// ⌃⌥⇧Space  dictate a note into ~/Documents/Ramble Notes/<date>.md
// ⌃⌥M       record a meeting (your mic + the call's audio) into ~/Documents/Ramble Notes/Meetings/
// Tap the hotkey to start and tap again to stop, or hold it and release to stop.
// Esc while recording cancels. Speech-to-text runs locally with whisper.cpp.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <ApplicationServices/ApplicationServices.h>

// MARK: - Settings (edit, then run ./build.sh)

static NSString *const kModelFile   = @"ggml-large-v3-turbo-q5_0.bin";
static NSString *const kOllamaModel = @"llama3.2:3b";  // used only when "Clean up with Ollama" is on
static const UInt32 kDictateKey = kVK_Space, kDictateMods = controlKey | optionKey;
static const UInt32 kNoteKey    = kVK_Space, kNoteMods    = controlKey | optionKey | shiftKey;
static const UInt32 kMeetingKey = kVK_ANSI_M, kMeetingMods = controlKey | optionKey;
static NSString *const kDictateLabel = @"⌃⌥Space";
static NSString *const kNoteLabel    = @"⌃⌥⇧Space";
static NSString *const kMeetingLabel = @"⌃⌥M";
static const NSTimeInterval kHoldThreshold = 0.4;      // held longer than this = push-to-talk
static const NSTimeInterval kMinimumClip   = 0.4;

static NSUserDefaults *Defaults(void) { return NSUserDefaults.standardUserDefaults; }
static NSURL *Home(void) { return NSFileManager.defaultManager.homeDirectoryForCurrentUser; }
static NSURL *SupportDir(void) { return [Home() URLByAppendingPathComponent:@"Library/Application Support/Ramble"]; }
static NSString *ModelPath(void) {
    return [[SupportDir() URLByAppendingPathComponent:@"models"] URLByAppendingPathComponent:kModelFile].path;
}
static NSURL *VocabularyFile(void) { return [SupportDir() URLByAppendingPathComponent:@"vocabulary.txt"]; }
static NSURL *HistoryFile(void) { return [SupportDir() URLByAppendingPathComponent:@"history.jsonl"]; }
static NSURL *NotesDir(void) { return [Home() URLByAppendingPathComponent:@"Documents/Ramble Notes"]; }
static NSURL *MeetingsDir(void) { return [NotesDir() URLByAppendingPathComponent:@"Meetings"]; }
static NSURL *RecordingsDir(void) { return [SupportDir() URLByAppendingPathComponent:@"Recordings"]; }
static NSString *WhisperPath(void) {
    NSString *local = [SupportDir() URLByAppendingPathComponent:@"whisper.cpp/build/bin/whisper-cli"].path;
    for (NSString *p in @[local, @"/opt/homebrew/bin/whisper-cli", @"/usr/local/bin/whisper-cli"])
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;
}
static NSError *Err(NSString *msg) {
    return [NSError errorWithDomain:@"Ramble" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}
static NSColor *Brand(CGFloat t) {  // 0 = tangerine, 1 = raspberry
    NSColor *a = [NSColor colorWithSRGBRed:1.0 green:0.616 blue:0.282 alpha:1];
    NSColor *b = [NSColor colorWithSRGBRed:0.839 green:0.157 blue:0.408 alpha:1];
    return [a blendedColorWithFraction:t ofColor:b];
}
static void Play(NSString *name) {
    if ([Defaults() boolForKey:@"sounds"]) [[NSSound soundNamed:name] play];
}

typedef NS_ENUM(NSInteger, Mode)  { ModePaste, ModeNote };
typedef NS_ENUM(NSInteger, Phase) { PhaseIdle, PhaseRecording, PhaseTranscribing };

// MARK: - Global hotkeys (Carbon; needs no extra permission)

typedef void (^HotKeyBlock)(BOOL pressed);
static NSMutableDictionary<NSNumber *, HotKeyBlock> *gHotKeyBlocks;
static NSMutableDictionary<NSNumber *, NSValue *> *gHotKeyRefs;

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *ctx) {
    EventHotKeyID hk;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk);
    HotKeyBlock block = gHotKeyBlocks[@(hk.id)];
    if (block) block(GetEventKind(event) == kEventHotKeyPressed);
    return noErr;
}

static void InstallHotKeyHandler(void) {
    gHotKeyBlocks = [NSMutableDictionary new];
    gHotKeyRefs = [NSMutableDictionary new];
    EventTypeSpec specs[2] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
    InstallApplicationEventHandler(&HotKeyHandler, 2, specs, NULL, NULL);
}

static void UnregisterHotKey(UInt32 hid) {
    NSValue *v = gHotKeyRefs[@(hid)];
    if (v) UnregisterEventHotKey((EventHotKeyRef)v.pointerValue);
    [gHotKeyRefs removeObjectForKey:@(hid)];
    [gHotKeyBlocks removeObjectForKey:@(hid)];
}

static BOOL RegisterHotKey(UInt32 hid, UInt32 code, UInt32 mods, HotKeyBlock block) {
    UnregisterHotKey(hid);
    EventHotKeyRef ref = NULL;
    EventHotKeyID hk = {.signature = 'RMBL', .id = hid};
    if (RegisterEventHotKey(code, mods, hk, GetApplicationEventTarget(), 0, &ref) != noErr || !ref) return NO;
    gHotKeyRefs[@(hid)] = [NSValue valueWithPointer:ref];
    gHotKeyBlocks[@(hid)] = [block copy];
    return YES;
}

// MARK: - Speech to text (whisper.cpp)

static NSString *VocabularyText(void) {
    return [NSString stringWithContentsOfURL:VocabularyFile() encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

static NSString *VocabularyPrompt(void) {
    NSMutableArray *words = [NSMutableArray new];
    for (NSString *line in [VocabularyText() componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *w = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (w.length && ![w hasPrefix:@"#"]) [words addObject:w];
    }
    return words.count ? [words componentsJoinedByString:@", "] : nil;
}

static NSString *Tidy(NSString *raw) {
    NSString *t = [raw stringByReplacingOccurrencesOfString:@"\\[[A-Z_ ]+\\]" withString:@""
                                                    options:NSRegularExpressionSearch range:NSMakeRange(0, raw.length)];
    t = [t stringByReplacingOccurrencesOfString:@"(?i)\\((music|applause|laughs|laughter|silence|inaudible|sighs|coughs)\\)"
                                     withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    t = [t stringByReplacingOccurrencesOfString:@"\\s+" withString:@" "
                                        options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    return [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *Transcribe(NSURL *wav, NSError **error) {
    NSString *exe = WhisperPath();
    if (!exe) { *error = Err(@"Speech engine (whisper-cli) not found"); return nil; }
    if (![NSFileManager.defaultManager fileExistsAtPath:ModelPath()]) {
        *error = Err([@"Speech model missing at " stringByAppendingString:ModelPath()]); return nil;
    }
    NSString *language = [Defaults() stringForKey:@"language"] ?: @"en";
    NSMutableArray *args = [@[@"-m", ModelPath(), @"-f", wav.path, @"-l", language, @"-nt", @"-np"] mutableCopy];
    NSString *vocab = VocabularyPrompt();
    if (vocab) [args addObjectsFromArray:@[@"--prompt", vocab]];

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:exe];
    task.arguments = args;
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    NSString *errPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"ramble-err-%@.txt", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createFileAtPath:errPath contents:nil attributes:nil];
    task.standardError = [NSFileHandle fileHandleForWritingAtPath:errPath];
    if (![task launchAndReturnError:error]) return nil;
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *errText = [NSString stringWithContentsOfFile:errPath encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:errPath error:nil];
    if (task.terminationStatus != 0) {
        NSArray *lines = [[errText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                          componentsSeparatedByString:@"\n"];
        NSString *last = lines.lastObject ?: [NSString stringWithFormat:@"exit %d", task.terminationStatus];
        *error = Err([@"Transcription failed: " stringByAppendingString:last]);
        return nil;
    }
    return Tidy([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"");
}

// MARK: - Optional cleanup through a local Ollama model

static NSString *CleanWithOllama(NSString *text) {
    NSString *instructions =
        @"Clean up this dictated text. Remove filler words (um, uh, you know, like), fix punctuation and "
        @"capitalization, and apply the speaker's self-corrections. Keep the speaker's wording and meaning. "
        @"Do not add anything, answer questions, or summarize. Reply with only the cleaned text.\n\nText:\n";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:11434/api/generate"]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model": kOllamaModel, @"prompt": [instructions stringByAppendingString:text],
        @"stream": @NO, @"options": @{@"temperature": @0}} options:0 error:nil];
    __block NSString *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *response = [json isKindOfClass:NSDictionary.class] ? json[@"response"] : nil;
        if ([response isKindOfClass:NSString.class]) {
            NSMutableCharacterSet *trim = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
            [trim addCharactersInString:@"\""];
            NSString *cleaned = [response stringByTrimmingCharactersInSet:trim];
            if (cleaned.length) result = cleaned;
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result;
}

// MARK: - Output: paste, notes, history

/// Puts text on the clipboard, presses ⌘V, then restores the previous clipboard.
/// Returns NO when Accessibility access is missing (the text is left on the clipboard).
static BOOL PasteText(NSString *text) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSMutableArray<NSPasteboardItem *> *saved = [NSMutableArray new];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSPasteboardItem *copy = [NSPasteboardItem new];
        for (NSPasteboardType type in item.types) {
            NSData *d = [item dataForType:type];
            if (d) [copy setData:d forType:type];
        }
        [saved addObject:copy];
    }
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    if (!AXIsProcessTrusted()) return NO;

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    for (int down = 1; down >= 0; down--) {
        CGEventRef e = CGEventCreateKeyboardEvent(src, kVK_ANSI_V, down);
        CGEventSetFlags(e, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
    }
    if (src) CFRelease(src);
    NSInteger ours = pb.changeCount;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (pb.changeCount != ours || saved.count == 0) return;
        [pb clearContents];
        [pb writeObjects:saved];
    });
    return YES;
}

static NSURL *AppendNote(NSString *text, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:NotesDir() withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSDate *now = [NSDate date];
    NSDateFormatter *dayFmt = [NSDateFormatter new];  dayFmt.dateFormat = @"yyyy-MM-dd";
    NSDateFormatter *timeFmt = [NSDateFormatter new]; timeFmt.dateFormat = @"HH:mm";
    NSString *day = [dayFmt stringFromDate:now];
    NSURL *file = [NotesDir() URLByAppendingPathComponent:[day stringByAppendingString:@".md"]];
    NSString *entry = [NSString stringWithFormat:@"## %@\n\n%@\n\n", [timeFmt stringFromDate:now], text];
    if ([fm fileExistsAtPath:file.path]) {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingToURL:file error:error];
        if (!h) return nil;
        [h seekToEndOfFile];
        [h writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } else {
        NSString *content = [NSString stringWithFormat:@"# %@\n\n%@", day, entry];
        if (![content writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:error]) return nil;
    }
    return file;
}

static void AppendHistory(NSDictionary *entry) {
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:entry options:0 error:nil] mutableCopy];
    if (!line) return;
    [line appendBytes:"\n" length:1];
    NSString *path = HistoryFile().path;
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:line];
    [h closeFile];
}

static NSArray *LoadHistory(void) {
    NSString *raw = [NSString stringWithContentsOfURL:HistoryFile() encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) [out addObject:obj];
    }
    return out;
}

// MARK: - Meetings: record your mic and the call audio, transcribe both, merge into Me / Them

@interface Segment : NSObject
@property double start, end;
@property (copy) NSString *text;
@property BOOL me;
@end
@implementation Segment
@end

static NSSet<NSString *> *WordSet(NSString *s) {
    NSMutableSet *set = [NSMutableSet new];
    for (NSString *w in [s.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet])
        if (w.length > 1) [set addObject:w];
    return set;
}

static NSString *Clock(double t) {
    int s = (int)t;
    return s >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60]
                     : [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

/// Whisper often starts a segment at the beginning of its 30-second window, before anyone
/// actually speaks. Move each start to where the audio first rises above that stretch's noise floor.
static void RefineStarts(NSArray<Segment *> *segs, NSURL *wav) {
    AVAudioFile *f = [[AVAudioFile alloc] initForReading:wav commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:nil];
    if (!f) return;
    double rate = f.processingFormat.sampleRate;
    AVAudioFrameCount win = (AVAudioFrameCount)(rate * 0.02);
    for (Segment *s in segs) {
        AVAudioFramePosition from = (AVAudioFramePosition)(s.start * rate);
        AVAudioFramePosition to = MIN((AVAudioFramePosition)(s.end * rate), f.length);
        if (to - from < win * 2) continue;
        AVAudioFrameCount n = (AVAudioFrameCount)MIN(to - from, (AVAudioFramePosition)(rate * 30));
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:n];
        f.framePosition = from;
        if (![f readIntoBuffer:buf frameCount:n error:nil] || !buf.floatChannelData) continue;
        const float *ch = buf.floatChannelData[0];
        NSUInteger windows = buf.frameLength / win;
        float *db = calloc(windows, sizeof(float));
        float floorDb = 0;
        for (NSUInteger w = 0; w < windows; w++) {
            float sum = 0;
            for (AVAudioFrameCount k = 0; k < win; k++) { float v = ch[w * win + k]; sum += v * v; }
            db[w] = 20 * log10f(sqrtf(sum / win) + 1e-9f);
            floorDb = w == 0 ? db[w] : fminf(floorDb, db[w]);
        }
        float threshold = fmaxf(-48, floorDb + 12);
        for (NSUInteger w = 0; w < windows; w++)
            if (db[w] > threshold) { s.start = MIN(s.end, (from + (double)w * win) / rate); break; }
        free(db);
    }
}

/// Runs whisper on one track and returns timestamped segments. `progress` gets 0…1.
static NSArray<Segment *> *TranscribeSegments(NSURL *wav, BOOL me, void (^progress)(double), NSError **error) {
    NSString *exe = WhisperPath();
    if (!exe) { if (error) *error = Err(@"Speech engine (whisper-cli) not found"); return nil; }
    NSString *language = [Defaults() stringForKey:@"language"] ?: @"en";
    NSMutableArray *args = [@[@"-m", ModelPath(), @"-f", wav.path, @"-l", language,
                              @"-np", @"-pp", @"-mc", @"0", @"-sns"] mutableCopy];
    NSString *vocab = VocabularyPrompt();
    if (vocab) [args addObjectsFromArray:@[@"--prompt", vocab]];

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:exe];
    task.arguments = args;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = err;
    NSMutableString *errLog = [NSMutableString new];
    NSRegularExpression *pRe = [NSRegularExpression regularExpressionWithPattern:@"progress = +(\\d+)%" options:0 error:nil];
    err.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) return;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (errLog) { [errLog appendString:s]; }
        for (NSTextCheckingResult *m in [pRe matchesInString:s options:0 range:NSMakeRange(0, s.length)])
            if (progress) progress([s substringWithRange:[m rangeAtIndex:1]].doubleValue / 100.0);
    };
    if (![task launchAndReturnError:error]) return nil;
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    err.fileHandleForReading.readabilityHandler = nil;
    if (task.terminationStatus != 0) {
        NSString *log;
        @synchronized (errLog) { log = [errLog copy]; }
        NSArray *lines = [[log stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                          componentsSeparatedByString:@"\n"];
        if (error) *error = Err([@"Transcription failed: " stringByAppendingString:lines.lastObject ?: @"unknown error"]);
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"^\\[(\\d+):(\\d+):(\\d+)\\.(\\d+) --> (\\d+):(\\d+):(\\d+)\\.(\\d+)\\]\\s*(.*)$"
                             options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSMutableArray<Segment *> *segs = [NSMutableArray new];
    for (NSTextCheckingResult *m in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        double v[8];
        for (int i = 0; i < 8; i++) v[i] = [text substringWithRange:[m rangeAtIndex:i + 1]].doubleValue;
        Segment *s = [Segment new];
        s.start = v[0] * 3600 + v[1] * 60 + v[2] + v[3] / 1000;
        s.end = v[4] * 3600 + v[5] * 60 + v[6] + v[7] / 1000;
        s.text = Tidy([text substringWithRange:[m rangeAtIndex:9]]);
        s.me = me;
        if (s.text.length) [segs addObject:s];
    }
    RefineStarts(segs, wav);
    // Whisper sometimes "hears" stock phrases in long silences. Drop them when nothing else
    // on the same track is nearby.
    NSSet *stock = [NSSet setWithArray:@[@"thank you.", @"thank you", @"thanks for watching!", @"thanks for watching.",
        @"thank you for watching.", @"thank you for watching!", @"thank you so much for watching!", @"you",
        @"bye.", @"subtitles by the amara.org community", @"."]];
    NSMutableArray *kept = [NSMutableArray new];
    for (NSUInteger i = 0; i < segs.count; i++) {
        Segment *s = segs[i];
        if ([stock containsObject:s.text.lowercaseString]) {
            BOOL near = (i > 0 && s.start - segs[i - 1].end < 15) || (i + 1 < segs.count && segs[i + 1].start - s.end < 15);
            if (!near) continue;
        }
        [kept addObject:s];
    }
    return kept;
}

/// Merges both tracks into a Markdown transcript.
static NSString *BuildTranscript(NSArray<Segment *> *me, NSArray<Segment *> *them, NSDate *started,
                                 NSTimeInterval duration, BOOL hadCallAudio,
                                 NSUInteger *meWords, NSUInteger *allWords, NSString **preview) {
    // If your mic picked up the call through speakers, those lines show up on both tracks.
    // Keep them only as "Them".
    NSMutableArray<Segment *> *mine = [NSMutableArray new];
    for (Segment *m in me) {
        NSSet *mw = WordSet(m.text);
        BOOL echo = NO;
        for (Segment *t in them) {
            if (t.start > m.end + 2 || t.end < m.start - 2 || !mw.count) continue;
            NSMutableSet *shared = [mw mutableCopy];
            [shared intersectSet:WordSet(t.text)];
            if ((double)shared.count / mw.count >= 0.6) { echo = YES; break; }
        }
        if (!echo) [mine addObject:m];
    }
    NSMutableArray<Segment *> *all = [[mine arrayByAddingObjectsFromArray:them] mutableCopy];
    [all sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(Segment *a, Segment *b) {
        return a.start < b.start ? NSOrderedAscending : a.start > b.start ? NSOrderedDescending : NSOrderedSame;
    }];

    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"EEE, MMM d 'at' h:mm a";
    NSMutableString *md = [NSMutableString stringWithFormat:@"# Meeting · %@\n\n", [f stringFromDate:started]];
    int minutes = MAX(1, (int)round(duration / 60));
    [md appendFormat:@"*%d min · recorded with Ramble · **Me** is your microphone, **Them** is everyone else on the call.*\n",
                     minutes];
    if (!hadCallAudio) [md appendString:@"\n> No call audio was captured, so this only has your side.\n"];
    [md appendString:@"\n"];

    NSUInteger mineCount = 0, total = 0;
    NSMutableString *plain = [NSMutableString new];
    Segment *prev = nil;
    for (Segment *s in all) {
        NSUInteger n = [s.text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].count;
        total += n;
        if (s.me) mineCount += n;
        if (!prev || prev.me != s.me || s.start - prev.end > 20) {
            [md appendFormat:@"%@**%@** · %@\n", prev ? @"\n\n" : @"", s.me ? @"Me" : @"Them", Clock(s.start)];
            [md appendString:s.text];
            if (plain.length < 400) [plain appendFormat:@"%@%@: %@", plain.length ? @" " : @"", s.me ? @"Me" : @"Them", s.text];
        } else {
            [md appendFormat:@" %@", s.text];
            if (plain.length < 400) [plain appendFormat:@" %@", s.text];
        }
        prev = s;
    }
    if (!all.count) [md appendString:@"Ramble didn't hear anyone say anything.\n"];
    [md appendString:@"\n"];
    if (meWords) *meWords = mineCount;
    if (allWords) *allWords = total;
    if (preview) *preview = plain.length > 400 ? [[plain substringToIndex:400] stringByAppendingString:@"…"] : plain;
    return md;
}

/// Records the microphone with AVAudioRecorder and everything the Mac plays (the call) with
/// ScreenCaptureKit, audio only, into two 16 kHz mono WAV files.
@interface MeetingRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property (strong) SCStream *stream;
@property (strong) AVAudioRecorder *mic;
@property (strong) AVAudioFile *sysFile;
@property (strong) NSURL *dir, *micURL, *sysURL;
@property (strong) NSDate *started;
@property (strong) dispatch_queue_t queue;
@property CMTime firstPTS;
@property AVAudioFramePosition sysFrames, firstFrame;
@property float sysLevel;
@property (copy) void (^onStreamError)(NSString *message);
@end

@implementation MeetingRecorder

- (void)start:(void (^)(NSError *error))done {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HHmmss";
    self.dir = [RecordingsDir() URLByAppendingPathComponent:[f stringFromDate:NSDate.date]];
    [NSFileManager.defaultManager createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:nil];
    self.micURL = [self.dir URLByAppendingPathComponent:@"me.wav"];
    self.sysURL = [self.dir URLByAppendingPathComponent:@"them.wav"];
    self.queue = dispatch_queue_create("ramble.meeting.audio", DISPATCH_QUEUE_SERIAL);

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !content.displays.count) { done(error ?: Err(@"No display available for audio capture")); return; }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject
                                                         excludingApplications:@[] exceptingWindows:@[]];
            SCStreamConfiguration *cfg = [SCStreamConfiguration new];
            cfg.capturesAudio = YES;
            cfg.excludesCurrentProcessAudio = YES;
            cfg.sampleRate = 16000;
            cfg.channelCount = 1;
            cfg.width = 2;   // video is required by the API but unused: keep it tiny and slow
            cfg.height = 2;
            cfg.minimumFrameInterval = CMTimeMake(1, 1);
            cfg.showsCursor = NO;
            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:self];
            NSError *e = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.queue error:&e] ||
                ![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.queue error:&e]) {
                done(e);
                return;
            }
            NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @16000.0,
                                       AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16,
                                       AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
            AVAudioRecorder *mic = [[AVAudioRecorder alloc] initWithURL:self.micURL settings:settings error:&e];
            mic.meteringEnabled = YES;
            if (!mic || ![mic record]) { done(e ?: Err(@"Could not start the microphone")); return; }
            self.started = [NSDate date];
            self.mic = mic;
            self.stream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError *se) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (se) { [mic stop]; self.mic = nil; self.stream = nil; done(se); return; }
                    done(nil);
                });
            }];
        });
    }];
}

- (void)writeSilence:(AVAudioFramePosition)frames format:(AVAudioFormat *)fmt {
    AVAudioFrameCount chunk = (AVAudioFrameCount)fmt.sampleRate;
    AVAudioPCMBuffer *z = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:chunk];
    z.frameLength = chunk;
    AudioBufferList *abl = z.mutableAudioBufferList;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) memset(abl->mBuffers[i].mData, 0, abl->mBuffers[i].mDataByteSize);
    while (frames > 0) {
        z.frameLength = (AVAudioFrameCount)MIN((AVAudioFramePosition)chunk, frames);
        if (![self.sysFile writeFromBuffer:z error:nil]) return;
        self.sysFrames += z.frameLength;
        frames -= z.frameLength;
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeAudio || !CMSampleBufferIsValid(sb) || !CMSampleBufferDataIsReady(sb)) return;
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sb));
    if (!asbd) return;
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
    AVAudioFrameCount frames = (AVAudioFrameCount)CMSampleBufferGetNumSamples(sb);
    if (!fmt || !frames) return;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
    buf.frameLength = frames;
    if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, 0, (int32_t)frames, buf.mutableAudioBufferList) != noErr) return;

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    if (!self.sysFile) {
        NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(fmt.sampleRate),
                                   AVNumberOfChannelsKey: @(fmt.channelCount), AVLinearPCMBitDepthKey: @16,
                                   AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
        self.sysFile = [[AVAudioFile alloc] initForWriting:self.sysURL settings:settings commonFormat:fmt.commonFormat
                                               interleaved:fmt.isInterleaved error:nil];
        if (!self.sysFile) return;
        // Line the call track up with the mic track: pad the time between pressing record and
        // the first call audio arriving.
        self.firstPTS = pts;
        double lead = MAX(0, -[self.started timeIntervalSinceNow] - (double)frames / fmt.sampleRate);
        [self writeSilence:(AVAudioFramePosition)(lead * fmt.sampleRate) format:fmt];
        self.firstFrame = self.sysFrames;
    } else if (CMTIME_IS_VALID(pts) && CMTIME_IS_VALID(self.firstPTS)) {
        // macOS stops sending call audio while nothing is playing; fill those gaps with silence.
        double elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, self.firstPTS));
        AVAudioFramePosition expected = self.firstFrame + (AVAudioFramePosition)llround(elapsed * fmt.sampleRate);
        AVAudioFramePosition gap = expected - self.sysFrames;
        if (gap > fmt.sampleRate * 0.05 && gap < fmt.sampleRate * 6 * 3600) [self writeSilence:gap format:fmt];
    }
    if ([self.sysFile writeFromBuffer:buf error:nil]) self.sysFrames += frames;

    if (fmt.commonFormat == AVAudioPCMFormatFloat32 && buf.floatChannelData) {
        float sum = 0, *ch = buf.floatChannelData[0];
        for (AVAudioFrameCount i = 0; i < frames; i++) sum += ch[i] * ch[i];
        float db = 20 * log10f(sqrtf(sum / frames) + 1e-9f);
        self.sysLevel = powf(fmaxf(0, fminf(1, (db + 50) / 45)), 1.6f);
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onStreamError) self.onStreamError(error.localizedDescription ?: @"Call audio stopped");
    });
}

- (void)stop:(void (^)(void))done {
    [self.mic stop];
    SCStream *s = self.stream;
    self.stream = nil;
    void (^finish)(void) = ^{
        dispatch_async(self.queue, ^{
            self.sysFile = nil;  // closes the WAV file
            dispatch_async(dispatch_get_main_queue(), done);
        });
    };
    if (s) [s stopCaptureWithCompletionHandler:^(NSError *e) { finish(); }];
    else finish();
}

- (BOOL)hasCallAudio {
    NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:self.sysURL.path error:nil][NSFileSize];
    return size.longLongValue > 16000;  // more than half a second of audio
}
@end

// MARK: - Menu-bar icon: a speech bubble with the ramble loops knocked out

static void AddRambleLoops(NSBezierPath *path, NSPoint center, CGFloat a, CGFloat b, CGFloat from, CGFloat to) {
    CGFloat x0 = center.x - a * (from + to) / 2;
    BOOL first = YES;
    for (CGFloat t = from; t <= to; t += 0.05) {
        NSPoint p = NSMakePoint(x0 + a * t - b * sin(t), center.y + b * cos(t));
        if (first) { [path moveToPoint:p]; first = NO; } else [path lineToPoint:p];
    }
}

static NSImage *MenuBarIcon(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(20, 17) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.blackColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 4.5, 18, 11.5) xRadius:5 yRadius:5] fill];
        NSBezierPath *tail = [NSBezierPath bezierPath];
        [tail moveToPoint:NSMakePoint(4, 6)];
        [tail curveToPoint:NSMakePoint(2.2, 0.8) controlPoint1:NSMakePoint(4, 3.5) controlPoint2:NSMakePoint(3.4, 1.8)];
        [tail curveToPoint:NSMakePoint(8.5, 5.5) controlPoint1:NSMakePoint(5, 1.5) controlPoint2:NSMakePoint(7.5, 3)];
        [tail closePath];
        [tail fill];
        NSBezierPath *loops = [NSBezierPath bezierPath];
        AddRambleLoops(loops, NSMakePoint(10, 10.1), 0.78, 2.5, -0.5 * M_PI, 4.5 * M_PI);
        loops.lineWidth = 1.5;
        loops.lineCapStyle = NSLineCapStyleRound;
        loops.lineJoinStyle = NSLineJoinStyleRound;
        [NSGraphicsContext.currentContext setCompositingOperation:NSCompositingOperationClear];
        [loops stroke];
        return YES;
    }];
    img.template = YES;
    return img;
}

// MARK: - Floating pill (live waveform while recording)

@interface WaveView : NSView
@property (strong) NSMutableArray<NSNumber *> *levels;
@property BOOL busy;
@property CGFloat phase;
@end

@implementation WaveView
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _levels = [NSMutableArray new];
        for (int i = 0; i < 24; i++) [_levels addObject:@0];
    }
    return self;
}
- (void)push:(CGFloat)level {
    [self.levels removeObjectAtIndex:0];
    [self.levels addObject:@(level)];
    self.needsDisplay = YES;
}
- (void)reset { for (NSUInteger i = 0; i < self.levels.count; i++) self.levels[i] = @0; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    NSUInteger n = self.levels.count;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, step = w / n, barW = 3;
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat v = self.busy ? 0.22 + 0.18 * (1 + sin(self.phase - i * 0.5)) : self.levels[i].doubleValue;
        CGFloat bh = MAX(3, v * h);
        NSRect bar = NSMakeRect(i * step + (step - barW) / 2, (h - bh) / 2, barW, bh);
        [[Brand((CGFloat)i / (n - 1)) colorWithAlphaComponent:self.busy ? 0.75 : 1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:barW / 2 yRadius:barW / 2] fill];
    }
}
@end

@interface Pill : NSObject
@property (strong) NSPanel *panel;
@property (strong) WaveView *wave;
@property (strong) NSTextField *label;
@property (strong) NSView *dot;
@property (strong) NSTimer *busyTimer;
@property NSUInteger generation;
@end

@implementation Pill
- (instancetype)init {
    if (!(self = [super init])) return nil;
    NSRect frame = NSMakeRect(0, 0, 236, 44);
    NSPanel *p = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered defer:YES];
    p.level = NSStatusWindowLevel;
    p.opaque = NO;
    p.backgroundColor = NSColor.clearColor;
    p.hasShadow = YES;
    p.ignoresMouseEvents = YES;
    p.hidesOnDeactivate = NO;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                           NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:frame];
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 22;
    bg.layer.masksToBounds = YES;
    p.contentView = bg;

    _dot = [[NSView alloc] initWithFrame:NSMakeRect(17, 17, 10, 10)];
    _dot.wantsLayer = YES;
    _dot.layer.cornerRadius = 5;
    _dot.layer.backgroundColor = [NSColor colorWithSRGBRed:1 green:0.27 blue:0.35 alpha:1].CGColor;
    [bg addSubview:_dot];

    _wave = [[WaveView alloc] initWithFrame:NSMakeRect(36, 9, 104, 26)];
    [bg addSubview:_wave];

    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _label.textColor = NSColor.whiteColor;
    _label.frame = NSMakeRect(148, 13, 80, 18);
    [bg addSubview:_label];
    _panel = p;
    return self;
}

- (void)layoutCompact:(BOOL)compact {
    self.dot.hidden = !compact;
    self.wave.hidden = !compact;
    self.label.alignment = compact ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    self.label.frame = compact ? NSMakeRect(148, 13, 80, 18) : NSMakeRect(12, 13, 212, 18);
}

- (void)present {
    self.generation++;
    if (!self.panel.isVisible) {
        NSPoint m = NSEvent.mouseLocation;
        NSScreen *screen = NSScreen.mainScreen;
        for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(m, s.frame, NO)) screen = s;
        NSRect vf = screen.visibleFrame;
        [self.panel setFrameOrigin:NSMakePoint(round(NSMidX(vf) - 118), NSMinY(vf) + 28)];
        self.panel.alphaValue = 0;
        [self.panel orderFrontRegardless];
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.15;
        self.panel.animator.alphaValue = 1;
    }];
}

- (void)startPulse {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1; pulse.toValue = @0.3; pulse.duration = 0.7;
    pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
    [self.dot.layer addAnimation:pulse forKey:@"pulse"];
}

- (void)showRecording:(Mode)mode {
    [self.busyTimer invalidate];
    self.wave.busy = NO;
    [self.wave reset];
    [self layoutCompact:YES];
    self.label.stringValue = mode == ModeNote ? @"Note 0:00" : @"0:00";
    [self startPulse];
    [self present];
}

- (void)setLevel:(CGFloat)level elapsed:(NSTimeInterval)t mode:(Mode)mode {
    [self.wave push:level];
    NSString *clock = [NSString stringWithFormat:@"%d:%02d", (int)t / 60, (int)t % 60];
    self.label.stringValue = mode == ModeNote ? [@"Note " stringByAppendingString:clock] : clock;
}

- (void)showBusy {
    [self.dot.layer removeAllAnimations];
    self.wave.busy = YES;
    self.label.stringValue = @"Writing…";
    [self.busyTimer invalidate];
    __weak Pill *weakSelf = self;
    self.busyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
        weakSelf.wave.phase += 0.25;
        weakSelf.wave.needsDisplay = YES;
    }];
    [self present];
}

- (void)flash:(NSString *)message seconds:(NSTimeInterval)seconds {
    [self.busyTimer invalidate];
    [self.dot.layer removeAllAnimations];
    [self layoutCompact:NO];
    self.label.stringValue = message;
    [self present];
    NSUInteger gen = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self.generation) [self hide];
    });
}

- (void)hide {
    [self.busyTimer invalidate];
    NSUInteger gen = ++self.generation;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.25;
        self.panel.animator.alphaValue = 0;
    } completionHandler:^{
        if (gen == self.generation) [self.panel orderOut:nil];
    }];
}
@end

// MARK: - Meeting pill (top-right, draggable, with a button)

@interface MeetingPill : NSObject
@property (strong) NSPanel *panel;
@property (strong) WaveView *wave;
@property (strong) NSTextField *label;
@property (strong) NSView *dot;
@property (strong) NSButton *button;
@property (strong) NSTimer *busyTimer;
@property (copy) void (^onButton)(void);
@property NSUInteger generation;
@end

@implementation MeetingPill
- (instancetype)init {
    if (!(self = [super init])) return nil;
    NSRect frame = NSMakeRect(0, 0, 286, 44);
    NSPanel *p = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered defer:YES];
    p.level = NSStatusWindowLevel;
    p.opaque = NO;
    p.backgroundColor = NSColor.clearColor;
    p.hasShadow = YES;
    p.movableByWindowBackground = YES;
    p.hidesOnDeactivate = NO;
    p.becomesKeyOnlyIfNeeded = YES;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                           NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:frame];
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 22;
    bg.layer.masksToBounds = YES;
    p.contentView = bg;

    _dot = [[NSView alloc] initWithFrame:NSMakeRect(17, 17, 10, 10)];
    _dot.wantsLayer = YES;
    _dot.layer.cornerRadius = 5;
    _dot.layer.backgroundColor = [NSColor colorWithSRGBRed:1 green:0.27 blue:0.35 alpha:1].CGColor;
    [bg addSubview:_dot];
    _wave = [[WaveView alloc] initWithFrame:NSMakeRect(34, 11, 64, 22)];
    for (NSUInteger i = 0; i < 10; i++) [_wave.levels removeLastObject];
    [bg addSubview:_wave];
    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _label.textColor = NSColor.whiteColor;
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    [bg addSubview:_label];

    _button = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(pressed)];
    _button.bordered = NO;
    _button.wantsLayer = YES;
    _button.layer.cornerRadius = 13;
    _button.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.16].CGColor;
    _button.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    _button.contentTintColor = NSColor.whiteColor;
    _button.frame = NSMakeRect(212, 9, 62, 26);
    [bg addSubview:_button];
    _panel = p;
    return self;
}

- (void)pressed { if (self.onButton) self.onButton(); }

- (void)setButtonTitle:(NSString *)title {
    self.button.hidden = title == nil;
    if (!title) return;
    self.button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]}];
}

- (void)layoutWithWave:(BOOL)wave {
    self.dot.hidden = !wave;
    self.wave.hidden = !wave;
    CGFloat right = self.button.hidden ? 274 : 204;
    CGFloat left = wave ? 106 : 18;
    self.label.frame = NSMakeRect(left, 13, right - left, 18);
}

- (void)present {
    self.generation++;
    if (!self.panel.isVisible) {
        NSPoint m = NSEvent.mouseLocation;
        NSScreen *screen = NSScreen.mainScreen;
        for (NSScreen *s in NSScreen.screens) if (NSMouseInRect(m, s.frame, NO)) screen = s;
        NSRect vf = screen.visibleFrame;
        [self.panel setFrameOrigin:NSMakePoint(NSMaxX(vf) - 286 - 16, NSMaxY(vf) - 44 - 12)];
        self.panel.alphaValue = 0;
        [self.panel orderFrontRegardless];
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.15;
        self.panel.animator.alphaValue = 1;
    }];
}

- (void)showRecording {
    [self.busyTimer invalidate];
    self.wave.busy = NO;
    [self.wave reset];
    [self setButtonTitle:@"Stop"];
    [self layoutWithWave:YES];
    self.label.stringValue = @"Meeting 0:00";
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1; pulse.toValue = @0.3; pulse.duration = 0.9;
    pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
    [self.dot.layer addAnimation:pulse forKey:@"pulse"];
    [self present];
}

- (void)update:(NSTimeInterval)t level:(CGFloat)level {
    [self.wave push:level];
    self.label.stringValue = [@"Meeting " stringByAppendingString:Clock(t)];
}

- (void)showTranscribing:(double)progress {
    [self.dot.layer removeAllAnimations];
    self.dot.hidden = YES;
    if (!self.busyTimer.valid) {
        self.wave.busy = YES;
        __weak MeetingPill *weakSelf = self;
        self.busyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
            weakSelf.wave.phase += 0.25;
            weakSelf.wave.needsDisplay = YES;
        }];
    }
    [self setButtonTitle:nil];
    [self layoutWithWave:YES];
    self.dot.hidden = YES;
    self.label.stringValue = [NSString stringWithFormat:@"Transcribing… %d%%", (int)round(progress * 100)];
    if (!self.panel.isVisible || self.panel.alphaValue < 1) [self present];
}

- (void)showDone:(NSString *)message button:(NSString *)title seconds:(NSTimeInterval)seconds {
    [self.busyTimer invalidate];
    [self.dot.layer removeAllAnimations];
    [self setButtonTitle:title];
    [self layoutWithWave:NO];
    self.label.stringValue = message;
    [self present];
    NSUInteger gen = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self.generation) [self hide];
    });
}

- (void)hide {
    [self.busyTimer invalidate];
    NSUInteger gen = ++self.generation;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.25;
        self.panel.animator.alphaValue = 0;
    } completionHandler:^{
        if (gen == self.generation) [self.panel orderOut:nil];
    }];
}
@end

// MARK: - The Ramble window (Overview, History, Settings), drawn with HTML in a web view

@class App;
@interface MainWindow : NSObject <WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) WKWebView *web;
@property (weak) App *app;
@property BOOL loaded;
- (void)show;
- (void)refresh;
@end

// MARK: - App

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) AVAudioRecorder *recorder;
@property (strong) NSURL *clipURL;
@property (strong) NSDate *recordStart, *pressedAt;
@property (strong) NSTimer *meterTimer;
@property (strong) Pill *pill;
@property (strong) MainWindow *main;
@property (strong) MeetingRecorder *meeting;
@property (strong) MeetingPill *meetingPill;
@property (strong) NSTimer *meetingTimer;
@property BOOL meetingStarting, meetingBusy;
@property double meetingProgress;
@property Phase phase;
@property Mode mode;
@property BOOL keyHeld, pressStartedRecording, hotkeyProblem;
@property (copy) NSString *statusLine, *lastTranscript;
- (void)openAccessibilitySettings;
- (void)openMicrophoneSettings;
- (void)openScreenRecordingSettings;
- (void)toggleMeeting;
- (BOOL)loginEnabled;
- (void)setLoginEnabled:(BOOL)on;
@end

@implementation MainWindow

- (void)build {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 700)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Ramble";
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.minSize = NSMakeSize(780, 560);
    w.releasedWhenClosed = NO;
    w.delegate = self;
    [w center];
    [w setFrameAutosaveName:@"RambleMainWindow"];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    [cfg.userContentController addScriptMessageHandler:self name:@"ramble"];
    WKWebView *web = [[WKWebView alloc] initWithFrame:w.contentView.bounds configuration:cfg];
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    web.navigationDelegate = self;
    [web setValue:@NO forKey:@"drawsBackground"];
    [w.contentView addSubview:web];
    NSURL *html = [NSBundle.mainBundle URLForResource:@"app" withExtension:@"html"];
    [web loadFileURL:html allowingReadAccessToURL:html.URLByDeletingLastPathComponent];
    self.window = w;
    self.web = web;
}

- (void)show {
    if (!self.window) [self build];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self refresh];
}

- (void)windowWillClose:(NSNotification *)n { [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; }
- (void)windowDidBecomeKey:(NSNotification *)n { [self refresh]; }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { self.loaded = YES; [self refresh]; }

- (NSDictionary *)state {
    NSString *mic = @"unknown";
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized: mic = @"granted"; break;
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted: mic = @"denied"; break;
        default: break;
    }
    NSString *notes = [NotesDir().path stringByReplacingOccurrencesOfString:Home().path withString:@"~"];
    return @{
        @"history": LoadHistory(),
        @"settings": @{@"sounds": @([Defaults() boolForKey:@"sounds"]),
                       @"pill": @([Defaults() boolForKey:@"pill"]),
                       @"cleanup": @([Defaults() boolForKey:@"cleanup"]),
                       @"language": [Defaults() stringForKey:@"language"] ?: @"en",
                       @"login": @(self.app.loginEnabled)},
        @"perms": @{@"mic": mic, @"ax": @(AXIsProcessTrusted()), @"screen": @(CGPreflightScreenCaptureAccess())},
        @"hotkeys": @{@"dictate": kDictateLabel, @"note": kNoteLabel, @"meeting": kMeetingLabel},
        @"meeting": @{@"active": @(self.app.meeting != nil && !self.app.meetingStarting),
                      @"started": @(self.app.meeting.started.timeIntervalSince1970),
                      @"busy": @(self.app.meetingBusy),
                      @"progress": @(self.app.meetingProgress)},
        @"hotkeyProblem": @(self.app.hotkeyProblem),
        @"notesDir": notes,
        @"vocabulary": VocabularyText(),
        @"model": kModelFile,
        @"ollamaModel": kOllamaModel,
        @"version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0",
    };
}

- (void)refresh {
    if (!self.loaded || !self.window.isVisible) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:[self state] options:0 error:nil];
    if (!json) return;
    NSString *js = [NSString stringWithFormat:@"window.ramble && window.ramble.load(%@)",
                    [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    [self.web evaluateJavaScript:js completionHandler:nil];
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *m = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
    NSString *action = m[@"action"];
    if ([action isEqualToString:@"copy"] && [m[@"text"] isKindOfClass:NSString.class]) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:m[@"text"] forType:NSPasteboardTypeString];
    } else if ([action isEqualToString:@"set"]) {
        NSString *key = m[@"key"];
        id value = m[@"value"];
        if ([key isEqualToString:@"login"]) [self.app setLoginEnabled:[value boolValue]];
        else if ([@[@"sounds", @"pill", @"cleanup"] containsObject:key]) [Defaults() setBool:[value boolValue] forKey:key];
        else if ([key isEqualToString:@"language"] && [value isKindOfClass:NSString.class]) [Defaults() setObject:value forKey:key];
    } else if ([action isEqualToString:@"saveVocabulary"] && [m[@"text"] isKindOfClass:NSString.class]) {
        [m[@"text"] writeToURL:VocabularyFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else if ([action isEqualToString:@"openNotes"]) {
        [NSFileManager.defaultManager createDirectoryAtURL:NotesDir() withIntermediateDirectories:YES attributes:nil error:nil];
        [NSWorkspace.sharedWorkspace openURL:NotesDir()];
    } else if ([action isEqualToString:@"openAccessibility"]) {
        [self.app openAccessibilitySettings];
    } else if ([action isEqualToString:@"openMicrophone"]) {
        [self.app openMicrophoneSettings];
    } else if ([action isEqualToString:@"openScreenRecording"]) {
        [self.app openScreenRecordingSettings];
    } else if ([action isEqualToString:@"toggleMeeting"]) {
        [self.app toggleMeeting];
    } else if ([action isEqualToString:@"openFile"] && [m[@"path"] isKindOfClass:NSString.class]) {
        // Only open files inside the notes folder.
        NSString *path = [m[@"path"] stringByStandardizingPath];
        if ([path hasPrefix:[NotesDir().path stringByAppendingString:@"/"]] &&
            [NSFileManager.defaultManager fileExistsAtPath:path])
            [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
    } else if ([action isEqualToString:@"clearHistory"]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Clear your Ramble history?";
        alert.informativeText = @"This deletes the stats and transcript history shown here. Notes in your notes folder are not touched.";
        [alert addButtonWithTitle:@"Clear History"];
        [alert addButtonWithTitle:@"Cancel"];
        alert.buttons.firstObject.hasDestructiveAction = YES;
        if ([alert runModal] == NSAlertFirstButtonReturn)
            [NSFileManager.defaultManager removeItemAtURL:HistoryFile() error:nil];
    }
    [self refresh];
}
@end

@implementation App

- (BOOL)cleanupOn { return [Defaults() boolForKey:@"cleanup"]; }

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [Defaults() registerDefaults:@{@"sounds": @YES, @"pill": @YES, @"cleanup": @NO, @"language": @"en"}];
    [self buildMainMenu];
    self.statusLine = @"Ready";
    self.pill = [Pill new];
    self.meetingPill = [MeetingPill new];
    self.main = [MainWindow new];
    self.main.app = self;

    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    self.item.menu = menu;
    [self refreshIcon];

    InstallHotKeyHandler();
    __weak App *weakSelf = self;
    BOOL a = RegisterHotKey(1, kDictateKey, kDictateMods, ^(BOOL p) { [weakSelf hotkey:ModePaste pressed:p]; });
    BOOL b = RegisterHotKey(2, kNoteKey, kNoteMods, ^(BOOL p) { [weakSelf hotkey:ModeNote pressed:p]; });
    BOOL c = RegisterHotKey(3, kMeetingKey, kMeetingMods, ^(BOOL p) { if (p) [weakSelf toggleMeeting]; });
    self.hotkeyProblem = !(a && b && c);

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:SupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:VocabularyFile().path])
        [@"# One word or name per line. Helps Ramble spell names and jargon your way.\n"
            writeToURL:VocabularyFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {}];
    if (!AXIsProcessTrusted()) {
        [self promptForAccessibility];
        // macOS often ignores a newly granted Accessibility permission until the app restarts,
        // so watch for the grant and relaunch once it arrives.
        [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
            if (!AXIsProcessTrusted()) return;
            [t invalidate];
            [self relaunch];
        }];
    }

    if (!WhisperPath()) self.statusLine = @"Speech engine not found";
    else if (![fm fileExistsAtPath:ModelPath()]) self.statusLine = @"Speech model missing";

    if (![Defaults() boolForKey:@"welcomed"]) {
        [Defaults() setBool:YES forKey:@"welcomed"];
        [self.main show];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self.main show];
    return NO;
}

- (void)buildMainMenu {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"About Ramble" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"Hide Ramble" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Ramble" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    NSMenuItem *editItem = [NSMenuItem new];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    [bar addItem:editItem];

    NSMenuItem *winItem = [NSMenuItem new];
    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    [win addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    winItem.submenu = win;
    [bar addItem:winItem];
    NSApp.mainMenu = bar;
}

// MARK: Hotkey handling: tap to toggle, or hold for push-to-talk

- (void)hotkey:(Mode)mode pressed:(BOOL)pressed {
    if (pressed) {
        if (self.keyHeld) return;  // ignore key repeat
        self.keyHeld = YES;
        self.pressedAt = [NSDate date];
        switch (self.phase) {
            case PhaseIdle:         self.pressStartedRecording = YES; [self start:mode]; break;
            case PhaseRecording:    self.pressStartedRecording = NO;  [self finish];     break;
            case PhaseTranscribing: NSBeep(); break;
        }
    } else {
        self.keyHeld = NO;
        if (self.pressStartedRecording && self.phase == PhaseRecording &&
            -[self.pressedAt timeIntervalSinceNow] > kHoldThreshold) [self finish];
        self.pressStartedRecording = NO;
    }
}

- (BOOL)pillOn { return [Defaults() boolForKey:@"pill"]; }

- (void)start:(Mode)mode {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusDenied) {
        [self fail:@"Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."];
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"ramble-%@.wav", NSUUID.UUID.UUIDString]]];
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @16000.0,
                               AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16,
                               AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    NSError *error = nil;
    AVAudioRecorder *r = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
    r.meteringEnabled = YES;
    if (!r || ![r record]) { [self fail:error.localizedDescription ?: @"Could not start the microphone"]; return; }
    self.recorder = r;
    self.clipURL = url;
    self.recordStart = [NSDate date];
    self.mode = mode;
    self.phase = PhaseRecording;
    self.statusLine = mode == ModePaste ? @"Listening… (Esc cancels)" : @"Listening for a note… (Esc cancels)";
    [self refreshIcon];
    Play(@"Tink");
    if (self.pillOn) [self.pill showRecording:mode];
    __weak App *weakSelf = self;
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
        [weakSelf tickMeter];
    }];
    RegisterHotKey(9, kVK_Escape, 0, ^(BOOL p) { if (p) [weakSelf cancel]; });
}

- (void)tickMeter {
    if (self.phase != PhaseRecording || !self.pillOn) return;
    [self.recorder updateMeters];
    CGFloat db = [self.recorder averagePowerForChannel:0];
    CGFloat level = pow(MAX(0, MIN(1, (db + 50) / 45)), 1.6);
    [self.pill setLevel:level elapsed:-[self.recordStart timeIntervalSinceNow] mode:self.mode];
}

- (NSURL *)stopRecording:(NSTimeInterval *)duration {
    UnregisterHotKey(9);
    [self.meterTimer invalidate];
    [self.recorder stop];
    self.recorder = nil;
    if (duration) *duration = -[self.recordStart timeIntervalSinceNow];
    NSURL *url = self.clipURL;
    self.clipURL = nil;
    return url;
}

- (void)cancel {
    if (self.phase != PhaseRecording) return;
    NSURL *url = [self stopRecording:NULL];
    if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    self.phase = PhaseIdle;
    self.statusLine = @"Cancelled";
    [self refreshIcon];
    if (self.pillOn) [self.pill flash:@"Cancelled" seconds:0.8];
}

- (void)finish {
    if (self.phase != PhaseRecording) return;
    NSTimeInterval duration = 0;
    NSURL *url = [self stopRecording:&duration];
    Play(@"Pop");
    if (!url || duration < kMinimumClip) {
        if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        self.phase = PhaseIdle;
        self.statusLine = @"Too short, ignored";
        [self refreshIcon];
        [self.pill hide];
        return;
    }
    self.phase = PhaseTranscribing;
    self.statusLine = @"Transcribing…";
    [self refreshIcon];
    if (self.pillOn) [self.pill showBusy];
    Mode mode = self.mode;
    BOOL cleanup = self.cleanupOn;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *text = Transcribe(url, &error);
        if (text.length && cleanup) text = CleanWithOllama(text) ?: text;
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ [self deliver:text error:error mode:mode duration:duration]; });
    });
}

- (void)deliver:(NSString *)text error:(NSError *)error mode:(Mode)mode duration:(NSTimeInterval)duration {
    self.phase = PhaseIdle;
    [self refreshIcon];
    if (!text) { [self fail:error.localizedDescription ?: @"Transcription failed"]; return; }
    if (!text.length) {
        self.statusLine = @"Heard nothing";
        if (self.pillOn) [self.pill flash:@"Didn't catch that" seconds:1.2];
        return;
    }
    self.lastTranscript = text;
    NSUInteger words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].count;
    NSString *pillText = nil;
    if (mode == ModePaste) {
        if (PasteText(text)) {
            self.statusLine = [NSString stringWithFormat:@"Pasted %lu words", words];
            pillText = [NSString stringWithFormat:@"✓  %lu words", words];
        } else {
            self.statusLine = @"Copied to clipboard: turn on Ramble under Accessibility to auto-paste";
            pillText = @"Copied — allow Accessibility to paste";
            [self openAccessibilitySettings];
        }
    } else {
        NSError *e = nil;
        NSURL *file = AppendNote(text, &e);
        if (!file) { [self fail:[@"Could not save note: " stringByAppendingString:e.localizedDescription]]; return; }
        self.statusLine = [NSString stringWithFormat:@"Saved %lu-word note to %@", words, file.lastPathComponent];
        pillText = [NSString stringWithFormat:@"✓  Note saved · %lu words", words];
    }
    AppendHistory(@{@"ts": @(round(NSDate.date.timeIntervalSince1970)), @"mode": mode == ModeNote ? @"note" : @"paste",
                    @"words": @(words), @"secs": @(round(duration * 10) / 10), @"text": text});
    if (self.pillOn) [self.pill flash:pillText seconds:1.3];
    [self.main refresh];
}

// MARK: Meetings

- (void)toggleMeeting {
    if (self.meetingStarting) return;
    if (self.meeting) [self stopMeeting];
    else if (self.meetingBusy) NSBeep();
    else [self startMeeting];
}

- (void)startMeeting {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusDenied) {
        [self fail:@"Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."];
        return;
    }
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Let Ramble hear your calls";
        alert.informativeText = @"To transcribe the other people on a call, Ramble needs Screen & System Audio Recording "
                                @"access. It only records audio, never your screen, and everything stays on this Mac.\n\n"
                                @"Turn on Ramble in the list, choose Quit & Reopen if macOS asks, then start the meeting again.";
        [alert addButtonWithTitle:@"Open Settings"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [self openScreenRecordingSettings];
        return;
    }
    MeetingRecorder *m = [MeetingRecorder new];
    __weak App *weakSelf = self;
    m.onStreamError = ^(NSString *message) {
        App *s = weakSelf;
        if (s.meeting != m) return;
        s.statusLine = [@"⚠︎ Call audio stopped: " stringByAppendingString:message];
        [s stopMeeting];
    };
    self.meeting = m;
    self.meetingStarting = YES;
    [m start:^(NSError *error) {
        self.meetingStarting = NO;
        if (error) {
            self.meeting = nil;
            [self fail:[@"Couldn't start the meeting recording: " stringByAppendingString:error.localizedDescription]];
            [self.main refresh];
            return;
        }
        Play(@"Tink");
        self.statusLine = @"Recording a meeting";
        [self.meetingPill showRecording];
        self.meetingPill.onButton = ^{ [weakSelf toggleMeeting]; };
        self.meetingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 15 repeats:YES block:^(NSTimer *t) {
            [weakSelf tickMeeting];
        }];
        [self refreshIcon];
        [self.main refresh];
    }];
}

- (void)tickMeeting {
    MeetingRecorder *m = self.meeting;
    if (!m || self.meetingStarting) return;
    [m.mic updateMeters];
    CGFloat mic = pow(MAX(0, MIN(1, ([m.mic averagePowerForChannel:0] + 50) / 45)), 1.6);
    [self.meetingPill update:-[m.started timeIntervalSinceNow] level:MAX(mic, m.sysLevel)];
}

- (void)stopMeeting {
    MeetingRecorder *m = self.meeting;
    if (!m) return;
    self.meeting = nil;
    [self.meetingTimer invalidate];
    self.meetingBusy = YES;
    self.meetingProgress = 0;
    NSDate *started = m.started;
    NSTimeInterval duration = -[started timeIntervalSinceNow];
    Play(@"Pop");
    self.statusLine = @"Transcribing meeting…";
    [self.meetingPill showTranscribing:0];
    [self refreshIcon];
    [self.main refresh];
    [m stop:^{ [self transcribeMeeting:m started:started duration:duration]; }];
}

- (void)meetingProgressed:(double)p {
    if (p < self.meetingProgress) return;
    self.meetingProgress = p;
    self.statusLine = [NSString stringWithFormat:@"Transcribing meeting… %d%%", (int)round(p * 100)];
    [self.meetingPill showTranscribing:p];
    [self.main refresh];
}

- (void)transcribeMeeting:(MeetingRecorder *)m started:(NSDate *)started duration:(NSTimeInterval)duration {
    BOOL hasCall = m.hasCallAudio;
    __weak App *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray *me = TranscribeSegments(m.micURL, YES, ^(double p) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf meetingProgressed:hasCall ? p * 0.5 : p]; });
        }, &error);
        NSArray *them = @[];
        if (me && hasCall) them = TranscribeSegments(m.sysURL, NO, ^(double p) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf meetingProgressed:0.5 + p * 0.5]; });
        }, &error);

        NSURL *file = nil;
        NSUInteger meWords = 0, allWords = 0;
        NSString *preview = @"";
        if (me && them) {
            NSString *md = BuildTranscript(me, them, started, duration, hasCall, &meWords, &allWords, &preview);
            NSDateFormatter *f = [NSDateFormatter new];
            f.dateFormat = @"yyyy-MM-dd HHmm";
            [NSFileManager.defaultManager createDirectoryAtURL:MeetingsDir() withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *base = [f stringFromDate:started];
            file = [MeetingsDir() URLByAppendingPathComponent:[base stringByAppendingString:@" Meeting.md"]];
            for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:file.path]; i++)
                file = [MeetingsDir() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ Meeting %d.md", base, i]];
            if ([md writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error])
                [NSFileManager.defaultManager removeItemAtURL:m.dir error:nil];
            else file = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            App *s = weakSelf;
            s.meetingBusy = NO;
            s.meetingProgress = 0;
            if (!file) {
                s.statusLine = [@"⚠︎ Meeting transcription failed. The audio is kept in " stringByAppendingString:m.dir.path];
                Play(@"Basso");
                s.meetingPill.onButton = ^{ [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[m.dir]]; };
                [s.meetingPill showDone:@"⚠︎ Transcription failed" button:@"Show" seconds:15];
                [s.main refresh];
                return;
            }
            AppendHistory(@{@"ts": @(round(started.timeIntervalSince1970)), @"mode": @"meeting",
                            @"words": @(meWords), @"allWords": @(allWords), @"secs": @(round(duration)),
                            @"text": preview ?: @"", @"file": file.path});
            s.statusLine = [NSString stringWithFormat:@"Meeting saved: %@", file.lastPathComponent];
            Play(@"Glass");
            s.meetingPill.onButton = ^{ [NSWorkspace.sharedWorkspace openURL:file]; [weakSelf.meetingPill hide]; };
            [s.meetingPill showDone:[NSString stringWithFormat:@"✓ Meeting saved · %lu words", (unsigned long)allWords]
                             button:@"Open" seconds:15];
            [s.main refresh];
        });
    });
}

// MARK: UI

- (void)fail:(NSString *)message {
    self.statusLine = [@"⚠︎ " stringByAppendingString:message];
    Play(@"Basso");
    if (self.pillOn) [self.pill flash:@"⚠︎  Something went wrong — see menu" seconds:2.5];
    self.item.button.contentTintColor = NSColor.systemYellowColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self refreshIcon]; });
}

- (void)refreshIcon {
    static NSImage *icon;
    if (!icon) icon = MenuBarIcon();
    self.item.button.image = icon;
    self.item.button.contentTintColor = (self.phase == PhaseRecording || self.meeting) ? NSColor.systemRedColor
                                      : (self.phase == PhaseTranscribing || self.meetingBusy) ? NSColor.systemOrangeColor : nil;
}

- (NSMenuItem *)add:(NSMenu *)menu title:(NSString *)title action:(SEL)action key:(NSString *)key
               mods:(NSEventModifierFlags)mods {
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    mi.keyEquivalentModifierMask = mods;
    mi.target = self;
    [menu addItem:mi];
    return mi;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:self.statusLine action:nil keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];
    if (self.hotkeyProblem) {
        NSMenuItem *warn = [[NSMenuItem alloc] initWithTitle:@"⚠︎ ⌃⌥Space or ⌃⌥⇧Space is taken by another app"
                                                      action:nil keyEquivalent:@""];
        warn.enabled = NO;
        [menu addItem:warn];
    }
    [menu addItem:NSMenuItem.separatorItem];

    BOOL recording = self.phase == PhaseRecording;
    NSEventModifierFlags co = NSEventModifierFlagControl | NSEventModifierFlagOption;
    [self add:menu title:recording ? @"Stop" : @"Dictate at Cursor" action:@selector(menuDictate) key:@" " mods:co];
    if (!recording) [self add:menu title:@"Dictate a Note" action:@selector(menuNote) key:@" " mods:co | NSEventModifierFlagShift];
    [self add:menu title:@"Copy Last Transcript" action:@selector(copyLast) key:nil mods:0].enabled = self.lastTranscript != nil;
    [menu addItem:NSMenuItem.separatorItem];
    if (self.meeting && !self.meetingStarting) {
        NSString *t = [NSString stringWithFormat:@"Stop Meeting Recording (%@)", Clock(-[self.meeting.started timeIntervalSinceNow])];
        [self add:menu title:t action:@selector(toggleMeeting) key:@"m" mods:co];
    } else if (self.meetingBusy) {
        NSMenuItem *busy = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Transcribing meeting… %d%%",
                            (int)round(self.meetingProgress * 100)] action:nil keyEquivalent:@""];
        busy.enabled = NO;
        [menu addItem:busy];
    } else {
        [self add:menu title:@"Record a Meeting" action:@selector(toggleMeeting) key:@"m" mods:co];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self add:menu title:@"Open Ramble…" action:@selector(openMain) key:@"," mods:NSEventModifierFlagCommand];
    [self add:menu title:@"Open Notes Folder" action:@selector(openNotes) key:nil mods:0];
    if (!AXIsProcessTrusted())
        [self add:menu title:@"Allow Accessibility (for auto-paste)…" action:@selector(openAccessibilitySettings) key:nil mods:0];
    [menu addItem:NSMenuItem.separatorItem];
    [self add:menu title:@"Restart Ramble" action:@selector(relaunch) key:nil mods:0];
    [self add:menu title:@"Quit Ramble" action:@selector(quit) key:@"q" mods:NSEventModifierFlagCommand];
}

- (void)menuDictate {
    if (self.phase == PhaseRecording) [self finish];
    else if (self.phase == PhaseIdle) [self start:ModePaste];
}
- (void)menuNote { if (self.phase == PhaseIdle) [self start:ModeNote]; }
- (void)copyLast {
    if (!self.lastTranscript) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.lastTranscript forType:NSPasteboardTypeString];
}
- (void)openMain { [self.main show]; }
- (void)openNotes {
    [NSFileManager.defaultManager createDirectoryAtURL:NotesDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:NotesDir()];
}
- (BOOL)loginEnabled { return SMAppService.mainAppService.status == SMAppServiceStatusEnabled; }
- (void)setLoginEnabled:(BOOL)on {
    NSError *error = nil;
    SMAppService *svc = SMAppService.mainAppService;
    BOOL ok = on ? [svc registerAndReturnError:&error] : [svc unregisterAndReturnError:&error];
    if (!ok) [self fail:[@"Launch at Login: " stringByAppendingString:error.localizedDescription ?: @"failed"]];
}
- (void)promptForAccessibility {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
}
- (void)openAccessibilitySettings {
    [self promptForAccessibility];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)openScreenRecordingSettings {
    CGRequestScreenCaptureAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}
- (void)openMicrophoneSettings {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {}];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
}
- (void)relaunch {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", @"sleep 0.7; /usr/bin/open \"$0\"", NSBundle.mainBundle.bundlePath];
    [task launchAndReturnError:nil];
    [NSApp terminate:nil];
}
- (void)quit { [NSApp terminate:nil]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Developer aid: `Ramble --export-menubar-icon out.png` writes the menu-bar icon at 8x.
        if (argc == 3 && strcmp(argv[1], "--export-menubar-icon") == 0) {
            NSImage *icon = MenuBarIcon();
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:160 pixelsHigh:136
                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [icon drawInRect:NSMakeRect(0, 0, 160, 136)];
            [NSGraphicsContext restoreGraphicsState];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
            return 0;
        }
        // Developer aid: `Ramble --transcribe-meeting me.wav them.wav` prints the merged transcript.
        if (argc == 4 && strcmp(argv[1], "--transcribe-meeting") == 0) {
            [Defaults() registerDefaults:@{@"language": @"en"}];
            NSURL *meURL = [NSURL fileURLWithPath:@(argv[2])], *themURL = [NSURL fileURLWithPath:@(argv[3])];
            NSError *error = nil;
            NSArray *me = TranscribeSegments(meURL, YES, nil, &error);
            NSArray *them = me ? TranscribeSegments(themURL, NO, nil, &error) : nil;
            if (!me || !them) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
            AVAudioFile *f = [[AVAudioFile alloc] initForReading:meURL error:nil];
            NSUInteger meWords = 0, allWords = 0;
            NSString *preview = nil;
            NSString *md = BuildTranscript(me, them, [NSDate date], f.length / f.fileFormat.sampleRate, YES,
                                           &meWords, &allWords, &preview);
            printf("%s\n--\nme words: %lu, all words: %lu\npreview: %s\n", md.UTF8String,
                   (unsigned long)meWords, (unsigned long)allWords, preview.UTF8String);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        App *delegate = [App new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
