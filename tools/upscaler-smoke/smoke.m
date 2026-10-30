// SPDX-License-Identifier: GPL-3.0-or-later
// The upscaler's smoke test (app/Sources/Upscale), run by the CI's precheck on
// its macOS runner before the long build: the shaders compile on this Metal and
// the hooks install; a flat frame comes out flat and a ramp stays a ramp
// through FSR 1 (EASU, then RCAS) and MetalFX; and one of the game layer's
// drawables, drawn and presented by a game's Metal 3 command buffer (as DXMT
// does) or waited for, signalled and presented on a Metal 4 queue (as
// KosmicKrisp's WSI does), goes through the upscaler without Metal ever seeing
// it. What this runner's GPU cannot do is skipped with a warning.
//
//   smoke             the checks; exit status 1 on a failure
//   smoke --shaders   the shaders' Metal source, for an offline compile
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "upscaler.h"

static int failures;
#define CHECK(c, ...)                                                                                                  \
    do {                                                                                                               \
        if (!(c)) {                                                                                                    \
            failures++;                                                                                                \
            printf("::error::upscaler: ");                                                                             \
            printf(__VA_ARGS__);                                                                                       \
            printf("\n");                                                                                              \
        }                                                                                                              \
    } while (0)

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;

static id<MTLTexture> texture(NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

static void clear(id<MTLCommandBuffer> cb, id<MTLTexture> t, MTLClearColor c) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = c;
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
}

// A horizontal ramp, 0 at the left to 255 at the right, uploaded into t.
static void ramp(id<MTLCommandBuffer> cb, id<MTLTexture> t) {
    NSUInteger w = t.width, h = t.height, row = w * 4;
    id<MTLBuffer> b = [device newBufferWithLength:row * h options:MTLResourceStorageModeShared];
    uint8_t *px = b.contents;
    for (NSUInteger y = 0; y < h; y++)
        for (NSUInteger x = 0; x < w; x++) {
            uint8_t v = (uint8_t)lround(x * 255.0 / (w - 1));
            uint8_t *q = px + y * row + x * 4;
            q[0] = q[1] = q[2] = v;
            q[3] = 255;
        }
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * h
           sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:0 destinationLevel:0
    destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e endEncoding];
}

// t's pixels, RGBA8.
static NSData *pixels(id<MTLTexture> t) {
    NSUInteger row = t.width * 4;
    id<MTLBuffer> b = [device newBufferWithLength:row * t.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row * t.height];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return [NSData dataWithBytes:b.contents length:b.length];
}

static void run(id<MTLCommandBuffer> cb, const char *what) {
    [cb commit];
    [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "%s: command buffer %ld %s", what, (long)cb.status,
          cb.error.localizedDescription.UTF8String ?: "");
}

// A flat frame upscaled 64x36 -> 160x90 comes out the same colour everywhere.
static void flat(const char *mode) {
    MTLClearColor colours[] = {{0.25, 0.5, 0.75, 1}, {0, 0, 0, 1}, {1, 1, 1, 1}, {0.9, 0.1, 0.4, 1}};
    for (unsigned i = 0; i < sizeof colours / sizeof colours[0]; i++) {
        MTLClearColor c = colours[i];
        id<MTLTexture> src = texture(64, 36), dst = texture(160, 90);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        clear(cb, src, c);
        CHECK(pp_upscale_encode_for_test(src, dst, cb), "%s: flat frame %u not encoded", mode, i);
        run(cb, mode);
        const uint8_t *p = pixels(dst).bytes;
        int want[3] = {(int)lround(c.red * 255), (int)lround(c.green * 255), (int)lround(c.blue * 255)};
        int worst = 0;
        for (NSUInteger k = 0; k < 160 * 90; k++)
            for (int ch = 0; ch < 3; ch++) worst = MAX(worst, abs((int)p[k * 4 + ch] - want[ch]));
        printf("%s: flat %u worst %d\n", mode, i, worst);
        CHECK(worst <= 3, "%s: a flat frame (%d,%d,%d) came out up to %d off", mode, want[0], want[1], want[2], worst);
    }
}

// A ramp upscaled 64x36 -> 160x90 still rises from left to right, with no
// value outside the ramp's.
static void rising(const char *mode, int slack) {
    id<MTLTexture> src = texture(64, 36), dst = texture(160, 90);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    ramp(cb, src);
    CHECK(pp_upscale_encode_for_test(src, dst, cb), "%s: ramp not encoded", mode);
    run(cb, mode);
    const uint8_t *s = pixels(src).bytes, *p = pixels(dst).bytes;
    int lo = 255, hi = 0, drops = 0;
    for (NSUInteger x = 0; x < 64; x++) { lo = MIN(lo, s[x * 4]); hi = MAX(hi, s[x * 4]); }
    for (NSUInteger y = 0; y < 90; y++)
        for (NSUInteger x = 0; x < 160; x++) {
            int v = p[(y * 160 + x) * 4];
            CHECK(v >= lo - slack && v <= hi + slack, "%s: ramp pixel %lu,%lu is %d, outside %d..%d", mode, (unsigned long)x,
                  (unsigned long)y, v, lo, hi);
            if (x && v + slack < p[(y * 160 + x - 1) * 4]) drops++;
        }
    printf("%s: ramp %d..%d, %d drops\n", mode, p[0], p[159 * 4], drops);
    CHECK(drops == 0, "%s: the ramp falls %d times", mode, drops);
    CHECK(p[159 * 4] > p[0] + 200, "%s: the ramp runs %d to %d", mode, p[0], p[159 * 4]);
}

// A drawable of the game layer through a game's presents.
static void presents(void) {
    CAMetalLayer *game = [CAMetalLayer layer];
    game.device = device;
    game.pixelFormat = MTLPixelFormatBGRA8Unorm;
    game.drawableSize = CGSizeMake(64, 36);
    pp_upscale_set_panel(160, 90);
    id<CAMetalDrawable> d = pp_upscale_next_drawable(game);
    if (!d) {
        printf("::warning::upscaler: no drawable from an offscreen layer on this runner; presents not checked\n");
        return;
    }
    CHECK(d.texture.width == 64 && d.texture.height == 36, "the game's drawable is %lux%lu",
          (unsigned long)d.texture.width, (unsigned long)d.texture.height);
    CHECK(d.layer == game, "the game's drawable names another layer");
    CAMetalLayer *out = pp_upscale_output_layer();
    CHECK(out && out.drawableSize.width == 160 && out.drawableSize.height == 90, "the output layer is %.0fx%.0f",
          out.drawableSize.width, out.drawableSize.height);
    // Metal 3, as DXMT presents: drawn, then presented on the same command buffer.
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    clear(cb, d.texture, (MTLClearColor){0.2, 0.4, 0.6, 1});
    [cb presentDrawable:d];
    run(cb, "Metal 3 present");
    id<CAMetalDrawable> d2 = pp_upscale_next_drawable(game);
    if (!d2) {
        printf("::warning::upscaler: one drawable only from an offscreen layer on this runner; the rest not checked\n");
        return;
    }
    cb = [queue commandBuffer];
    clear(cb, d2.texture, (MTLClearColor){0.2, 0.4, 0.6, 1});
    [cb presentDrawable:d2 afterMinimumDuration:1.0 / 60];
    run(cb, "Metal 3 present after a minimum duration");
    // Metal 4, as KosmicKrisp's WSI presents.
    id<MTL4CommandQueue> q4 = [device newMTL4CommandQueue];
    if (!q4) {
        printf("::warning::upscaler: no Metal 4 on this runner; KosmicKrisp's present not checked\n");
        return;
    }
    for (int i = 0; i < 6; i++) {
        id<CAMetalDrawable> d4 = pp_upscale_next_drawable(game);
        if (!d4) {
            // An offscreen layer may keep its presented drawables.
            printf("::warning::upscaler: no drawable for Metal 4 frame %d on this runner; the rest not checked\n", i);
            return;
        }
        [q4 waitForDrawable:d4];
        [q4 signalDrawable:d4];
        [d4 present];
    }
    // A drawable whose texture an earlier frame used: the queue waits for that
    // frame's upscale before it draws, so an event it signals after that wait
    // comes only once the upscale is done.
    id<CAMetalDrawable> again = pp_upscale_next_drawable(game);
    if (!again) {
        printf("::warning::upscaler: no drawable after the Metal 4 frames on this runner; their upscales not checked\n");
        return;
    }
    [q4 waitForDrawable:again];
    id<MTLSharedEvent> done = [device newSharedEvent];
    [q4 signalEvent:done value:1];
    CHECK([done waitUntilSignaledValue:1 timeoutMS:3000], "the Metal 4 frames' upscales did not finish");
}

// The performance HUD's GPU time: counted from the commits after it starts.
static void gpuTime(void) {
    CHECK(pp_gpu_stats_start(), "GPU time could not be counted");
    double busy = 0, wall = 0;
    pp_gpu_stats_take(&busy, &wall);
    for (int i = 0; i < 4; i++) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        clear(cb, texture(1024, 1024), (MTLClearColor){0.1, 0.2, 0.3, 1});
        run(cb, "GPU time");
    }
    usleep(100 * 1000);   // completed handlers may run just after the wait
    pp_gpu_stats_take(&busy, &wall);
    printf("GPU time: %.3f ms busy in %.3f ms\n", busy * 1000, wall * 1000);
    CHECK(busy > 0 && busy <= wall + 0.001, "GPU time %.6f s busy in %.6f s", busy, wall);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--shaders")) {
            fputs(pp_upscale_shader_source(), stdout);
            return 0;
        }
        device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("::warning::upscaler: no Metal device on this runner; its GPU checks did not run\n");
            return 0;
        }
        printf("device: %s\n", device.name.UTF8String);
        queue = [device newCommandQueue];
        char note[256];
        int got = pp_upscale_configure(PP_UPSCALE_FSR1, -1, note, sizeof note);
        printf("FSR 1, no RCAS: %d (%s)\n", got, note);
        CHECK(got == PP_UPSCALE_FSR1, "FSR 1 did not configure: %s", note);
        if (got != PP_UPSCALE_FSR1) return 1;
        flat("EASU");
        rising("EASU", 1);
        got = pp_upscale_configure(PP_UPSCALE_FSR1, 0.5f, note, sizeof note);
        printf("FSR 1: %d (%s)\n", got, note);
        flat("EASU+RCAS");
        presents();
        gpuTime();
        got = pp_upscale_configure(PP_UPSCALE_METALFX, -1, note, sizeof note);
        printf("MetalFX: %d (%s)\n", got, note);
        if (got == PP_UPSCALE_METALFX) {
            flat("MetalFX");
            rising("MetalFX", 2);
        } else {
            printf("::warning::upscaler: no MetalFX on this runner (%s)\n", note);
        }
        printf("%d failure%s\n", failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
