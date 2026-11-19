// Renders Resources/app.html (with its built-in demo data) to a PNG, for README screenshots.
// usage: snapshot page.html out.png <light|dark> <overview|history|settings> [width height]
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface Snap : NSObject <WKNavigationDelegate>
@property NSString *out, *tab;
@property WKWebView *web;
@end

@implementation Snap
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)nav {
    NSString *js = [NSString stringWithFormat:@"document.querySelector('[data-tab=%@]').click()", self.tab];
    [web evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        // Let the count-up and chart animations settle.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *img, NSError *err) {
                if (!img) { fprintf(stderr, "snapshot failed: %s\n", err.description.UTF8String); exit(1); }
                NSSize pt = web.bounds.size;
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL pixelsWide:pt.width * 2 pixelsHigh:pt.height * 2
                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                rep.size = pt;
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
                [img drawInRect:NSMakeRect(0, 0, pt.width, pt.height)];
                [NSGraphicsContext restoreGraphicsState];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:self.out atomically:YES];
                printf("wrote %s\n", self.out.UTF8String);
                exit(0);
            }];
        });
    }];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 5) { fprintf(stderr, "usage: snapshot page.html out.png light|dark tab [w h]\n"); return 2; }
        CGFloat w = argc > 6 ? atof(argv[5]) : 1080, h = argc > 6 ? atof(argv[6]) : 760;
        [NSApplication sharedApplication];
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(-20000, 0, w, h)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        win.appearance = [NSAppearance appearanceNamed:strcmp(argv[3], "dark") == 0 ? NSAppearanceNameDarkAqua
                                                                                   : NSAppearanceNameAqua];
        Snap *snap = [Snap new];
        snap.out = @(argv[2]);
        snap.tab = @(argv[4]);
        // The window is off-screen, where WebKit pauses CSS animations and requestAnimationFrame.
        // Turn animations off and drive rAF from a timer so the page reaches its final state.
        WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
        [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:
            @"window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16);"
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
        [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:
            @"const s = document.createElement('style');"
             "s.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; } ::-webkit-scrollbar { display: none; }';"
             "document.head.appendChild(s);"
            injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
        snap.web = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, w, h) configuration:cfg];
        snap.web.navigationDelegate = snap;
        win.contentView = snap.web;
        [win orderFront:nil];
        NSURL *page = [NSURL fileURLWithPath:@(argv[1])];
        [snap.web loadFileURL:page allowingReadAccessToURL:page.URLByDeletingLastPathComponent];
        [NSApp run];
    }
    return 0;
}
