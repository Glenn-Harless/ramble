// Draws the Ramble app icon: a warm gradient squircle with a white speech bubble
// holding a looping "ramble" line. Usage: make_icon <out.png> [size]
#import <Cocoa/Cocoa.h>

static CGColorRef RGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return CGColorCreateSRGB(r / 255.0, g / 255.0, b / 255.0, a);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: make_icon out.png [size]\n"); return 1; }
        const CGFloat S = argc > 2 ? atof(argv[2]) : 1024;
        const CGFloat k = S / 1024.0;
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef c = CGBitmapContextCreate(NULL, S, S, 8, 0, cs, kCGImageAlphaPremultipliedLast);
        CGContextScaleCTM(c, k, k);

        // Squircle tile (macOS icon grid: 824pt tile inside a 1024 canvas), with a soft shadow.
        CGRect tile = CGRectMake(100, 100, 824, 824);
        CGPathRef tilePath = CGPathCreateWithRoundedRect(tile, 185, 185, NULL);
        CGContextSaveGState(c);
        CGContextSetShadowWithColor(c, CGSizeMake(0, -10), 28, RGB(60, 10, 30, 0.35));
        CGContextAddPath(c, tilePath);
        CGContextSetFillColorWithColor(c, RGB(232, 54, 93, 1));
        CGContextFillPath(c);
        CGContextRestoreGState(c);

        // Gradient: tangerine (top-left) -> raspberry (bottom-right).
        CGContextSaveGState(c);
        CGContextAddPath(c, tilePath);
        CGContextClip(c);
        CGColorRef stops[3] = {RGB(255, 157, 72, 1), RGB(255, 94, 87, 1), RGB(214, 40, 104, 1)};
        CFArrayRef colors = CFArrayCreate(NULL, (const void **)stops, 3, &kCFTypeArrayCallBacks);
        CGFloat locs[3] = {0, 0.5, 1};
        CGGradientRef grad = CGGradientCreateWithColors(cs, colors, locs);
        CGContextDrawLinearGradient(c, grad, CGPointMake(160, 924), CGPointMake(864, 100), 0);
        // Soft highlight in the top-left for depth.
        CGColorRef hl[2] = {RGB(255, 255, 255, 0.22), RGB(255, 255, 255, 0)};
        CFArrayRef hlColors = CFArrayCreate(NULL, (const void **)hl, 2, &kCFTypeArrayCallBacks);
        CGGradientRef hlGrad = CGGradientCreateWithColors(cs, hlColors, NULL);
        CGContextDrawRadialGradient(c, hlGrad, CGPointMake(300, 820), 0, CGPointMake(300, 820), 520, 0);
        CGContextRestoreGState(c);

        // Speech bubble with a tail at the bottom-left.
        CGMutablePathRef bubble = CGPathCreateMutable();
        CGPathAddRoundedRect(bubble, NULL, CGRectMake(222, 330, 580, 400), 150, 150);
        CGPathMoveToPoint(bubble, NULL, 300, 360);
        CGPathAddCurveToPoint(bubble, NULL, 300, 300, 270, 250, 220, 225);
        CGPathAddCurveToPoint(bubble, NULL, 320, 228, 390, 270, 420, 340);
        CGPathCloseSubpath(bubble);
        CGContextSaveGState(c);
        CGContextSetShadowWithColor(c, CGSizeMake(0, -14), 30, RGB(120, 15, 50, 0.35));
        CGContextAddPath(c, bubble);
        CGContextSetFillColorWithColor(c, RGB(255, 255, 255, 1));
        CGContextFillPath(c);
        CGContextRestoreGState(c);

        // The ramble: a prolate cycloid, i.e. a line that keeps looping as it travels.
        CGMutablePathRef loop = CGPathCreateMutable();
        const CGFloat a = 21, b = 58, x0 = 512 - a * 3 * M_PI, y0 = 515;
        BOOL first = YES;
        for (CGFloat t = -0.55 * M_PI; t <= 6.55 * M_PI; t += 0.02) {
            CGFloat x = x0 + a * t - b * sin(t);
            CGFloat y = y0 + b * cos(t) * 1.05;
            if (first) { CGPathMoveToPoint(loop, NULL, x, y); first = NO; }
            else CGPathAddLineToPoint(loop, NULL, x, y);
        }
        CGContextSaveGState(c);
        CGContextAddPath(c, loop);
        CGContextSetLineWidth(c, 34);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        CGContextReplacePathWithStrokedPath(c);
        CGContextClip(c);
        CGContextDrawLinearGradient(c, grad, CGPointMake(260, 600), CGPointMake(760, 460), 0);
        CGContextRestoreGState(c);

        CGImageRef img = CGBitmapContextCreateImage(c);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
        return 0;
    }
}
