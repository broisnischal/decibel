// Now Playing bridge. Since macOS 15.4, MediaRemote only answers Apple-signed clients, so Decibel loads this
// library into /usr/bin/perl (identifier com.apple.perl) and talks to it over stdin/stdout:
//   stdout: one JSON object per line whenever the now-playing state changes
//   stdin:  "play" | "pause" | "toggle" | "next" | "previous" | "seek <seconds>" | "refresh"
// The process exits when Decibel closes its end of stdin.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (^BSInfoBlock)(CFDictionaryRef);
typedef void (^BSBoolBlock)(Boolean);
typedef void (^BSPIDBlock)(int);

static void *mediaRemote;
static void (*MRGetInfo)(dispatch_queue_t, BSInfoBlock);
static void (*MRGetIsPlaying)(dispatch_queue_t, BSBoolBlock);
static void (*MRGetPID)(dispatch_queue_t, BSPIDBlock);
static Boolean (*MRSendCommand)(int, CFDictionaryRef);
static void (*MRSetElapsedTime)(double);
static void (*MRRegister)(dispatch_queue_t);

static NSData *lastArtwork;
static NSString *lastTrack;
static BOOL emitScheduled;
static NSMutableData *pendingInput;

static NSString *BSNotificationName(const char *symbol) {
    CFStringRef *name = dlsym(mediaRemote, symbol);
    return name ? (__bridge NSString *)*name : @(symbol);
}

static void BSWriteLine(NSDictionary *object) {
    if (![NSJSONSerialization isValidJSONObject:object]) return; // dataWithJSONObject throws on NaN/Inf instead.
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingWithoutEscapingSlashes error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void BSCopy(NSDictionary *info, NSString *key, NSMutableDictionary *out, NSString *name) {
    id value = info[key];
    if ([value isKindOfClass:NSNumber.class] && !isfinite([value doubleValue])) return; // Live streams report NaN/Inf.
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) out[name] = value;
}

/// MediaRemote can hand over full-resolution artwork (one track sent ~70 MB); the panel only shows a thumbnail.
static NSData *BSThumbnail(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @256,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return nil;
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
    BOOL written = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    return written ? png : nil;
}

static void BSEmitState(void) {
    emitScheduled = NO;
    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block int pid = 0;
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    MRGetInfo(queue, ^(CFDictionaryRef dict) {
        info = [(__bridge NSDictionary *)dict copy];
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    MRGetIsPlaying(queue, ^(Boolean isPlaying) {
        playing = isPlaying;
        dispatch_group_leave(group);
    });
    if (MRGetPID) {
        dispatch_group_enter(group);
        MRGetPID(queue, ^(int value) {
            pid = value;
            dispatch_group_leave(group);
        });
    }

    dispatch_group_notify(group, queue, ^{
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"playing"] = @(playing);
        out[@"pid"] = @(pid);
        BSCopy(info, @"kMRMediaRemoteNowPlayingInfoTitle", out, @"title");
        BSCopy(info, @"kMRMediaRemoteNowPlayingInfoArtist", out, @"artist");
        BSCopy(info, @"kMRMediaRemoteNowPlayingInfoAlbum", out, @"album");
        BSCopy(info, @"kMRMediaRemoteNowPlayingInfoDuration", out, @"duration");
        BSCopy(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime", out, @"elapsed");
        BSCopy(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate", out, @"rate");
        id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @([timestamp timeIntervalSince1970]);

        // Artwork is large, so it is only sent when it changes ("" clears it). MediaRemote often leaves it out of
        // follow-up updates for the same track, so a missing image only clears the artwork when the track changes.
        id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        NSData *data = [artwork isKindOfClass:NSData.class] && [artwork length] ? artwork : nil;
        NSString *track = [NSString stringWithFormat:@"%@\u241F%@\u241F%@", out[@"title"] ?: @"", out[@"artist"] ?: @"",
                                                     out[@"album"] ?: @""];
        BOOL sameTrack = [track isEqualToString:lastTrack];
        if (data && ![data isEqualToData:lastArtwork]) {
            NSData *thumbnail = BSThumbnail(data);
            out[@"artwork"] = thumbnail ? [thumbnail base64EncodedStringWithOptions:0] : @"";
            lastArtwork = data;
        } else if (!data && !sameTrack && lastArtwork) {
            out[@"artwork"] = @"";
            lastArtwork = nil;
        }
        lastTrack = track;
        BSWriteLine(out);
    });
}

static void BSScheduleEmit(void) {
    if (emitScheduled) return;
    emitScheduled = YES; // Coalesce bursts of notifications into one update.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ BSEmitState(); });
}

static void BSHandleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    // MRMediaRemoteCommand values.
    if ([command isEqualToString:@"play"]) MRSendCommand(0, NULL);
    else if ([command isEqualToString:@"pause"]) MRSendCommand(1, NULL);
    else if ([command isEqualToString:@"toggle"]) MRSendCommand(2, NULL);
    else if ([command isEqualToString:@"next"]) MRSendCommand(4, NULL);
    else if ([command isEqualToString:@"previous"]) MRSendCommand(5, NULL);
    else if ([command isEqualToString:@"seek"] && parts.count > 1 && MRSetElapsedTime) MRSetElapsedTime(parts[1].doubleValue);
    else if ([command isEqualToString:@"refresh"]) {
        lastArtwork = nil;
        lastTrack = nil;
    }
    BSScheduleEmit();
}

static void BSReadInput(void) {
    char buffer[512];
    ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
    if (count <= 0) exit(0); // Decibel went away.
    [pendingInput appendBytes:buffer length:(NSUInteger)count];
    for (;;) {
        NSRange newline = [pendingInput rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                              range:NSMakeRange(0, pendingInput.length)];
        if (newline.location == NSNotFound) break;
        NSData *lineData = [pendingInput subdataWithRange:NSMakeRange(0, newline.location)];
        [pendingInput replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line.length) BSHandleCommand(line);
    }
}

/// Perl XSUB entry point (PerlInterpreter *, CV *); the arguments are unused. Never returns.
void bs_now_playing_run(void *perl, void *cv) {
    (void)perl;
    (void)cv;
    mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    MRGetInfo = dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPID = dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRSendCommand = dlsym(mediaRemote, "MRMediaRemoteSendCommand");
    MRSetElapsedTime = dlsym(mediaRemote, "MRMediaRemoteSetElapsedTime");
    MRRegister = dlsym(mediaRemote, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!MRGetInfo || !MRGetIsPlaying || !MRSendCommand) {
        BSWriteLine(@{@"error": @"MediaRemote unavailable"});
        exit(1);
    }

    if (MRRegister) MRRegister(dispatch_get_main_queue());
    const char *notifications[] = {
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    };
    for (size_t i = 0; i < sizeof notifications / sizeof *notifications; i++) {
        [NSNotificationCenter.defaultCenter addObserverForName:BSNotificationName(notifications[i]) object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { BSScheduleEmit(); }];
    }

    pendingInput = [NSMutableData data];
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{ BSReadInput(); });
    dispatch_resume(input);

    BSEmitState();
    CFRunLoopRun();
    exit(0);
}
