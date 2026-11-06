// strokefind: where did the ink land? Captures every display before and after
// a fake stroke (inject.py) and prints the bounding box of pixels that changed,
// in global points (the same space inject.py targets), per display.
//
//   strokefind snap <dir>            save one PNG per display into <dir>
//   strokefind diff <before> <after> print changed boxes between two snaps
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

static NSArray<NSNumber *> *displays(void) {
    uint32_t n = 0; CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &n);
    NSMutableArray *a = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) [a addObject:@(ids[i])];
    return a;
}

static CGImageRef load(NSString *path) {
    CGImageSourceRef s = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!s) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(s, 0, NULL);
    CFRelease(s);
    return img;
}

static uint8_t *rgba(CGImageRef img, size_t *w, size_t *h) {
    *w = CGImageGetWidth(img); *h = CGImageGetHeight(img);
    uint8_t *buf = calloc(*w * *h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, *w, *h, 8, *w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(c, CGRectMake(0, 0, *w, *h), img);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return buf;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc >= 3 && !strcmp(argv[1], "snap")) {
            // screencapture writes one file per display, in the active list's
            // order, so file i belongs to displays()[i].
            NSString *dir = @(argv[2]);
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableArray *args = [NSMutableArray arrayWithObject:@"-x"];
            NSArray *ds = displays();
            for (NSUInteger i = 0; i < ds.count; i++)
                [args addObject:[dir stringByAppendingFormat:@"/%u.png", [ds[i] unsignedIntValue]]];
            NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/usr/sbin/screencapture" arguments:args];
            [t waitUntilExit];
            return t.terminationStatus;
        }
        if (argc >= 4 && !strcmp(argv[1], "diff")) {
            int found = 0;
            for (NSNumber *d in displays()) {
                CGDirectDisplayID id = d.unsignedIntValue;
                CGImageRef a = load([@(argv[2]) stringByAppendingFormat:@"/%u.png", id]);
                CGImageRef b = load([@(argv[3]) stringByAppendingFormat:@"/%u.png", id]);
                if (!a || !b) continue;
                size_t w, h, w2, h2;
                uint8_t *pa = rgba(a, &w, &h), *pb = rgba(b, &w2, &h2);
                if (w != w2 || h != h2) { printf("display %u: size changed\n", id); continue; }
                CGRect bounds = CGDisplayBounds(id);
                double sx = bounds.size.width / w, sy = bounds.size.height / h;
                long x0 = LONG_MAX, y0 = LONG_MAX, x1 = -1, y1 = -1, count = 0;
                for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
                    uint8_t *ca = pa + (y * w + x) * 4, *cb = pb + (y * w + x) * 4;
                    int dd = abs(ca[0] - cb[0]) + abs(ca[1] - cb[1]) + abs(ca[2] - cb[2]);
                    if (dd > 60) {
                        count++;
                        if ((long)x < x0) x0 = x; if ((long)x > x1) x1 = x;
                        if ((long)y < y0) y0 = y; if ((long)y > y1) y1 = y;
                    }
                }
                if (count) {
                    found = 1;
                    double gx0 = bounds.origin.x + x0 * sx, gy0 = bounds.origin.y + y0 * sy;
                    double gx1 = bounds.origin.x + x1 * sx, gy1 = bounds.origin.y + y1 * sy;
                    printf("display %u: %ld px changed, box global (%.0f,%.0f)-(%.0f,%.0f), centre (%.0f,%.0f)\n",
                           id, count, gx0, gy0, gx1, gy1, (gx0 + gx1) / 2, (gy0 + gy1) / 2);
                }
                free(pa); free(pb); CGImageRelease(a); CGImageRelease(b);
            }
            if (!found) printf("no change on any display\n");
            return 0;
        }
        fprintf(stderr, "usage: strokefind snap <dir> | diff <before> <after>\n");
        return 2;
    }
}
