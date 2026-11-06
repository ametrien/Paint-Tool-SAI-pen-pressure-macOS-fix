// vdisplay: create a fake extended display so multi-monitor bugs can be
// reproduced without a second monitor. Lives until killed (Ctrl+C / kill).
// usage: vdisplay <left|right|above|below> [width height]
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property(readonly, nonatomic) unsigned int displayID;
@end

static void dump(void) {
    uint32_t n = 0; CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        printf("  display %u%s: origin(%d,%d) size %dx%d\n", ids[i],
               CGDisplayIsMain(ids[i]) ? " (main)" : "",
               (int)b.origin.x, (int)b.origin.y, (int)b.size.width, (int)b.size.height);
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *where = argc > 1 ? argv[1] : "left";
        unsigned w = argc > 3 ? atoi(argv[2]) : 1920, h = argc > 3 ? atoi(argv[3]) : 1080;
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.queue = dispatch_get_main_queue();
        d.name = @"SAI test display";
        d.maxPixelsWide = w; d.maxPixelsHigh = h;
        d.sizeInMillimeters = CGSizeMake(530, 300);
        d.serialNum = 0x5A1; d.productID = 0x5A1; d.vendorID = 0x5A1;
        d.terminationHandler = ^(id a, id b) { printf("virtual display terminated\n"); exit(1); };
        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        if (!vd) { fprintf(stderr, "could not create virtual display\n"); return 1; }
        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 0;
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        if (![vd applySettings:s]) { fprintf(stderr, "applySettings failed\n"); return 1; }
        CGDirectDisplayID vid = vd.displayID;
        // let it come online, then place it relative to the main display
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CGRect m = CGDisplayBounds(CGMainDisplayID());
            CGRect v = CGDisplayBounds(vid);
            int x = 0, y = 0;
            if (!strcmp(where, "left"))  { x = -(int)v.size.width; y = 0; }
            if (!strcmp(where, "right")) { x = (int)m.size.width;  y = 0; }
            if (!strcmp(where, "above")) { x = 0; y = -(int)v.size.height; }
            if (!strcmp(where, "below")) { x = 0; y = (int)m.size.height; }
            CGDisplayConfigRef cfg;
            CGBeginDisplayConfiguration(&cfg);
            CGConfigureDisplayOrigin(cfg, vid, x, y);
            CGError e = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
            printf("virtual display %u placed %s (err %d)\n", vid, where, e);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ dump(); });
        });
        dispatch_main();
    }
}
