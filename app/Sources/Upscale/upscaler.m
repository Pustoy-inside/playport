// SPDX-License-Identifier: GPL-3.0-or-later
// The upscaler (upscaler.h): a game's frame, drawn at the resolution Settings
// chose, scaled up to the screen's pixels by MetalFX's spatial scaler or by
// AMD's FSR 1 as the frame is presented, whatever drew it.
//
// Every route draws into Playport's game layer (PacedMetalLayer): DXMT takes a
// drawable there and presents it with -[MTLCommandBuffer presentDrawable:] (or
// its afterMinimumDuration: form); KosmicKrisp's Metal WSI (DXVK,
// vkd3d-proton, OpenGL through Zink) takes one at acquire, blits its swapchain
// image into it, and presents it the Metal 4 way: -[MTL4CommandQueue
// waitForDrawable:], a commit, -signalDrawable:, then -[drawable present].
//
// While a mode is on, the game layer hands out a PPUpscaleDrawable instead: a
// texture of the game's size (the layer's drawableSize and pixelFormat, which
// the game set) standing in for the drawable, holding a real drawable of the
// output layer, which is the size the game's picture fills on the screen. The
// game draws its frame into the texture as it would into a drawable. Then:
//
// - Metal 3 (DXMT): the hooked presentDrawable: encodes the upscale into the
//   game's own command buffer, after its frame, and presents the real drawable
//   in its place.
// - Metal 4 (KosmicKrisp): the hooked signalDrawable: signals an event once the
//   game's commands are done; -present then upscales on Playport's own queue
//   after that event and presents the real drawable. The hooked
//   waitForDrawable: waits for the upscale that last read the texture, and
//   makes the textures resident on the game's queue.
//
// A drawable that is not a PPUpscaleDrawable goes to Metal as before. The game
// layer itself never presents while a mode is on: the output layer, its
// sublayer (GameSurfaceView), shows the frames, aspect-fitted.

#import "upscaler.h"
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include "upscaler_shaders.h"

// Textures the game draws into, in turn: more than the output layer's three
// drawables, so one is never drawn into while its last upscale may still read it.
enum { kPoolSize = 4 };

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[upscale] %s\n", line);
    fflush(stderr);
}

// What PacedMetalLayer reads a framebuffer-only drawable's picture from for a
// screenshot (KosmicKrisp's patches/mesa 0035 key): the game's own frame.
static const void *readable_source_key(void) { return (const void *)@selector(playportReadableSource); }

static bool is_float_format(MTLPixelFormat f) {
    return f == MTLPixelFormatRGBA16Float || f == MTLPixelFormatRGBA32Float || f == MTLPixelFormatRG11B10Float
        || f == MTLPixelFormatRGB9E5Float || f == MTLPixelFormatBGRA10_XR || f == MTLPixelFormatBGRA10_XR_sRGB
        || f == MTLPixelFormatBGR10_XR || f == MTLPixelFormatBGR10_XR_sRGB;
}

static bool is_srgb_format(MTLPixelFormat f) {
    return f == MTLPixelFormatBGRA8Unorm_sRGB || f == MTLPixelFormatRGBA8Unorm_sRGB
        || f == MTLPixelFormatBGRA10_XR_sRGB || f == MTLPixelFormatBGR10_XR_sRGB;
}

@class PPUpscaleDrawable;

@interface PPUpscaler : NSObject
+ (instancetype)shared;
- (int)configure:(int)mode stops:(float)stops note:(NSString **)note;
- (id<CAMetalDrawable>)nextFor:(CAMetalLayer *)game;
- (BOOL)encodeFrom:(id<MTLTexture>)src to:(id<MTLTexture>)dst on:(id<MTLCommandBuffer>)cb;
- (BOOL)encode:(PPUpscaleDrawable *)p on:(id<MTLCommandBuffer>)cb;
- (void)presentOwn:(PPUpscaleDrawable *)p kind:(int)kind time:(CFTimeInterval)t;
- (void)queue:(id<MTL4CommandQueue>)q waitsFor:(PPUpscaleDrawable *)p;
- (void)queue:(id<MTL4CommandQueue>)q signals:(PPUpscaleDrawable *)p;
@property (atomic, readonly) int mode;
@property (atomic, readonly, strong) CAMetalLayer *output;
- (void)setPanelWidth:(double)w height:(double)h;
@end

// The game's drawable while a mode is on.
@interface PPUpscaleDrawable : NSObject <CAMetalDrawable>
- (instancetype)initWithReal:(id<CAMetalDrawable>)real texture:(id<MTLTexture>)texture slot:(NSUInteger)slot
                        game:(CAMetalLayer *)game;
@property (nonatomic, readonly, strong) id<CAMetalDrawable> real;
@property (nonatomic, readonly) NSUInteger slot;
// What the game's Metal 4 queue signals once the frame is drawn; 0 before.
@property (atomic) uint64_t renderedValue;
// Upscaled and handed to Metal (once).
@property (atomic) BOOL done;
@end

static Class drawable_class;

@implementation PPUpscaleDrawable {
    id<MTLTexture> _texture;
    __weak CAMetalLayer *_game;
}

- (instancetype)initWithReal:(id<CAMetalDrawable>)real texture:(id<MTLTexture>)texture slot:(NSUInteger)slot
                        game:(CAMetalLayer *)game {
    if ((self = [super init])) {
        _real = real;
        _texture = texture;
        _slot = slot;
        _game = game;
    }
    return self;
}

- (id<MTLTexture>)texture { return _texture; }
- (CAMetalLayer *)layer { return _game; }
- (CFTimeInterval)presentedTime { return _real.presentedTime; }
- (NSUInteger)drawableID { return _real.drawableID; }
// The handler sees the real drawable, whose texture carries the frame's
// (readable_source_key) once it is upscaled.
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block { [_real addPresentedHandler:block]; }
- (void)present { [PPUpscaler.shared presentOwn:self kind:0 time:0]; }
- (void)presentAtTime:(CFTimeInterval)t { [PPUpscaler.shared presentOwn:self kind:1 time:t]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { [PPUpscaler.shared presentOwn:self kind:2 time:d]; }
@end

// MARK: Hooks

typedef void (*present_fn)(id, SEL, id);
typedef void (*present_time_fn)(id, SEL, id, CFTimeInterval);
static present_fn orig_present, orig_wait, orig_signal;
static present_time_fn orig_present_at, orig_present_after;

static PPUpscaleDrawable *ours(id d) {
    return d && object_getClass(d) == drawable_class ? (PPUpscaleDrawable *)d : nil;
}

// The game's command buffer presents one of ours: the upscale goes in after
// its frame, and the real drawable is presented instead.
static id upscale_in(id cb, id d) {
    PPUpscaleDrawable *p = ours(d);
    if (!p) return d;
    if (!p.done) {
        p.done = YES;
        [PPUpscaler.shared encode:p on:(id<MTLCommandBuffer>)cb];
    }
    return p.real;
}

static void hook_present(id self, SEL sel, id d) { orig_present(self, sel, upscale_in(self, d)); }
static void hook_present_at(id self, SEL sel, id d, CFTimeInterval t) { orig_present_at(self, sel, upscale_in(self, d), t); }
static void hook_present_after(id self, SEL sel, id d, CFTimeInterval t) {
    orig_present_after(self, sel, upscale_in(self, d), t);
}

static void hook_wait(id self, SEL sel, id d) {
    PPUpscaleDrawable *p = ours(d);
    if (p) [PPUpscaler.shared queue:(id<MTL4CommandQueue>)self waitsFor:p];
    else orig_wait(self, sel, d);
}

static void hook_signal(id self, SEL sel, id d) {
    PPUpscaleDrawable *p = ours(d);
    if (p) [PPUpscaler.shared queue:(id<MTL4CommandQueue>)self signals:p];
    else orig_signal(self, sel, d);
}

// sel's implementation on cls (or the class it inherits it from) becomes imp.
static BOOL hook(Class cls, SEL sel, IMP imp, IMP *orig) {
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) return NO;
    IMP was = method_getImplementation(m);
    if (was == imp) return YES;
    *orig = was;
    method_setImplementation(m, imp);
    return YES;
}

// MARK: The upscaler

@implementation PPUpscaler {
    os_unfair_lock _lock;
    int _mode;
    float _stops;
    BOOL _hooked;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLLibrary> _library;
    NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_pipelines;
    CAMetalLayer *_output;
    double _panelW, _panelH;
    // Metal 4: the game's queue signals rendered; Playport's queue signals consumed.
    id<MTLSharedEvent> _rendered, _consumed;
    _Atomic uint64_t _renderedN, _consumedN;
    id<MTLResidencySet> _residency;
    NSHashTable *_residentOn;
    // The textures the game draws into.
    id<MTLTexture> _pool[kPoolSize];
    uint64_t _poolConsumed[kPoolSize];
    NSUInteger _next, _poolW, _poolH;
    MTLPixelFormat _poolFormat;
    NSMutableArray<id<MTLTexture>> *_retired;
    CFTimeInterval _retiredAt;
    // The scaled frame before RCAS or the copy into the drawable.
    id<MTLTexture> _mid;
    id<MTLFXSpatialScaler> _scaler;
    NSString *_scalerKey, *_scalerFailed;
    unsigned _logged;
}

+ (instancetype)shared {
    static PPUpscaler *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [PPUpscaler new]; });
    return one;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _stops = -1;
        _pipelines = [NSMutableDictionary new];
        _retired = [NSMutableArray new];
        _residentOn = [NSHashTable weakObjectsHashTable];
        drawable_class = [PPUpscaleDrawable class];
    }
    return self;
}

- (int)mode { return _mode; }
- (CAMetalLayer *)output { return _output; }

- (void)setPanelWidth:(double)w height:(double)h {
    os_unfair_lock_lock(&_lock);
    _panelW = w;
    _panelH = h;
    os_unfair_lock_unlock(&_lock);
}

// The command buffer class DXMT's are, and the Metal 4 queue class
// KosmicKrisp's is: the probes are made on the same device.
- (BOOL)installHooks:(NSString **)note {
    if (_hooked) return YES;
    id<MTLCommandBuffer> cb = [[_device newCommandQueue] commandBuffer];
    Class c3 = cb ? object_getClass(cb) : Nil;
    if (!hook(c3, @selector(presentDrawable:), (IMP)hook_present, (IMP *)&orig_present)
        || !hook(c3, @selector(presentDrawable:atTime:), (IMP)hook_present_at, (IMP *)&orig_present_at)
        || !hook(c3, @selector(presentDrawable:afterMinimumDuration:), (IMP)hook_present_after,
                 (IMP *)&orig_present_after)) {
        *note = [NSString stringWithFormat:@"no presentDrawable: on %s", c3 ? class_getName(c3) : "(no command buffer)"];
        return NO;
    }
    id<MTL4CommandQueue> q4 = [_device newMTL4CommandQueue];
    Class c4 = q4 ? object_getClass(q4) : Nil;
    if (q4 && (!hook(c4, @selector(waitForDrawable:), (IMP)hook_wait, (IMP *)&orig_wait)
               || !hook(c4, @selector(signalDrawable:), (IMP)hook_signal, (IMP *)&orig_signal))) {
        // KosmicKrisp would hand Metal 4 a drawable that is not one.
        *note = [NSString stringWithFormat:@"no waitForDrawable:/signalDrawable: on %s", class_getName(c4)];
        return NO;
    }
    _hooked = YES;
    say("hooked %s%s%s", class_getName(c3), c4 ? " and " : " (no Metal 4)", c4 ? class_getName(c4) : "");
    return YES;
}

- (int)configure:(int)mode stops:(float)stops note:(NSString **)note {
    os_unfair_lock_lock(&_lock);
    _stops = stops;
    if (mode != PP_UPSCALE_METALFX && mode != PP_UPSCALE_FSR1) {
        _mode = PP_UPSCALE_OFF;
        os_unfair_lock_unlock(&_lock);
        *note = @"off";
        return PP_UPSCALE_OFF;
    }
    NSString *why = nil;
    if (!_device) _device = MTLCreateSystemDefaultDevice();
    if (!_device) why = @"no Metal device";
    if (!why && !_library) {
        NSError *error = nil;
        _library = [_device newLibraryWithSource:@(pp_upscaler_shaders) options:[MTLCompileOptions new] error:&error];
        if (!_library) why = [NSString stringWithFormat:@"shaders: %@", error.localizedDescription];
    }
    if (!why) [self installHooks:&why];
    if (why) {
        _mode = PP_UPSCALE_OFF;
        os_unfair_lock_unlock(&_lock);
        *note = [@"off: " stringByAppendingString:why];
        say("%s", (*note).UTF8String);
        return PP_UPSCALE_OFF;
    }
    if (!_queue) {
        _queue = [_device newCommandQueue];
        _queue.label = @"Playport upscaler";
        _rendered = [_device newSharedEvent];
        _consumed = [_device newSharedEvent];
        MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
        rd.label = @"Playport upscaler";
        _residency = [_device newResidencySetWithDescriptor:rd error:nil];
    }
    if (!_output) {
        _output = [CAMetalLayer layer];
        _output.device = _device;
        _output.framebufferOnly = YES;
        _output.opaque = YES;
        _output.contentsGravity = kCAGravityResizeAspect;
        _output.presentsWithTransaction = NO;
        _output.name = @"Playport upscaled frames";
    }
    NSString *extra = @"";
    if (mode == PP_UPSCALE_METALFX && ![MTLFXSpatialScalerDescriptor supportsDevice:_device]) {
        mode = PP_UPSCALE_FSR1;
        extra = @" (MetalFX is not on this GPU)";
    }
    _mode = mode;
    os_unfair_lock_unlock(&_lock);
    *note = [NSString stringWithFormat:@"%@%@%@", mode == PP_UPSCALE_METALFX ? @"MetalFX spatial" : @"FSR 1",
             stops >= 0 ? [NSString stringWithFormat:@", RCAS %.2f stops", stops] : @"", extra];
    say("%s", (*note).UTF8String);
    return mode;
}

// MARK: Frames

- (void)poolFor:(NSUInteger)w height:(NSUInteger)h format:(MTLPixelFormat)format {
    if (_pool[0] && _poolW == w && _poolH == h && _poolFormat == format) return;
    for (int i = 0; i < kPoolSize; i++) {
        if (_pool[i]) [_retired addObject:_pool[i]];
    }
    _retiredAt = CACurrentMediaTime();
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h
                                                                             mipmapped:NO];
    // KosmicKrisp's WSI makes views of a drawable's texture for its blit.
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    d.storageMode = MTLStorageModePrivate;
    for (int i = 0; i < kPoolSize; i++) {
        _pool[i] = [_device newTextureWithDescriptor:d];
        _pool[i].label = [NSString stringWithFormat:@"Playport game frame %d", i];
        _poolConsumed[i] = 0;
        if (_pool[i]) [_residency addAllocation:_pool[i]];
    }
    [_residency commit];
    _poolW = w;
    _poolH = h;
    _poolFormat = format;
    say("frames %lux%lu format %lu", (unsigned long)w, (unsigned long)h, (unsigned long)format);
}

// Old textures stay resident until no frame can still be using them.
- (void)dropRetired {
    if (!_retired.count || CACurrentMediaTime() - _retiredAt < 2.0) return;
    for (id<MTLTexture> t in _retired) [_residency removeAllocation:t];
    [_residency commit];
    [_retired removeAllObjects];
}

- (id<CAMetalDrawable>)nextFor:(CAMetalLayer *)game {
    CGSize size = game.drawableSize;
    NSUInteger w = (NSUInteger)size.width, h = (NSUInteger)size.height;
    MTLPixelFormat format = game.pixelFormat;
    if (!w || !h || format == MTLPixelFormatInvalid) return nil;
    os_unfair_lock_lock(&_lock);
    double pw = _panelW, ph = _panelH;
    os_unfair_lock_unlock(&_lock);
    // The game's picture, aspect-fitted to the screen's pixels.
    double s = (pw >= 1 && ph >= 1) ? fmin(pw / (double)w, ph / (double)h) : 1.0;
    CGSize outSize = CGSizeMake(fmax(1.0, round(w * s)), fmax(1.0, round(h * s)));
    CAMetalLayer *out = _output;
    if (out.pixelFormat != format) out.pixelFormat = format;
    if (!CGSizeEqualToSize(out.drawableSize, outSize)) out.drawableSize = outSize;
    if (out.colorspace != game.colorspace) out.colorspace = game.colorspace;
    if (out.wantsExtendedDynamicRangeContent != game.wantsExtendedDynamicRangeContent)
        out.wantsExtendedDynamicRangeContent = game.wantsExtendedDynamicRangeContent;
    if (out.EDRMetadata != game.EDRMetadata) out.EDRMetadata = game.EDRMetadata;
    id<CAMetalDrawable> real = [out nextDrawable];
    if (!real) return nil;
    os_unfair_lock_lock(&_lock);
    [self poolFor:w height:h format:format];
    [self dropRetired];
    NSUInteger slot = _next++ % kPoolSize;
    id<MTLTexture> texture = _pool[slot];
    BOOL first = _logged < 1;
    if (first) _logged = 1;
    os_unfair_lock_unlock(&_lock);
    if (!texture) return nil;
    if (first)
        say("first frame: %lux%lu to %.0fx%.0f (panel %.0fx%.0f)", (unsigned long)w, (unsigned long)h, outSize.width,
            outSize.height, pw, ph);
    return [[PPUpscaleDrawable alloc] initWithReal:real texture:texture slot:slot game:game];
}

- (id<MTLRenderPipelineState>)pipeline:(NSString *)fragment format:(MTLPixelFormat)format {
    NSString *key = [NSString stringWithFormat:@"%@/%lu", fragment, (unsigned long)format];
    id<MTLRenderPipelineState> ps = _pipelines[key];
    if (ps) return ps;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.label = key;
    d.vertexFunction = [_library newFunctionWithName:@"pp_fullscreen"];
    d.fragmentFunction = [_library newFunctionWithName:fragment];
    d.colorAttachments[0].pixelFormat = format;
    NSError *error = nil;
    ps = [_device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!ps) say("pipeline %s: %s", key.UTF8String, error.localizedDescription.UTF8String);
    else _pipelines[key] = ps;
    return ps;
}

// One full-screen pass of fragment from src into dst.
- (BOOL)pass:(NSString *)fragment from:(id<MTLTexture>)src to:(id<MTLTexture>)dst bytes:(const void *)bytes
      length:(NSUInteger)length on:(id<MTLCommandBuffer>)cb {
    id<MTLRenderPipelineState> ps = [self pipeline:fragment format:dst.pixelFormat];
    if (!ps) return NO;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    if (!e) return NO;
    e.label = fragment;
    [e setRenderPipelineState:ps];
    [e setFragmentTexture:src atIndex:0];
    if (bytes) [e setFragmentBytes:bytes length:length atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    return YES;
}

- (id<MTLTexture>)midWidth:(NSUInteger)w height:(NSUInteger)h format:(MTLPixelFormat)format
                     usage:(MTLTextureUsage)usage {
    usage |= MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (_mid && _mid.width == w && _mid.height == h && _mid.pixelFormat == format && (_mid.usage & usage) == usage)
        return _mid;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h
                                                                             mipmapped:NO];
    d.usage = usage;
    d.storageMode = MTLStorageModePrivate;
    _mid = [_device newTextureWithDescriptor:d];
    _mid.label = @"Playport upscaled frame";
    return _mid;
}

// MetalFX's spatial scaler from src into a texture of dst's size; nil when it
// cannot (FSR 1 then).
- (id<MTLTexture>)metalFXFrom:(id<MTLTexture>)src width:(NSUInteger)w height:(NSUInteger)h
                           on:(id<MTLCommandBuffer>)cb {
    MTLPixelFormat format = src.pixelFormat;
    NSString *key = [NSString stringWithFormat:@"%lux%lu>%lux%lu/%lu", (unsigned long)src.width,
                     (unsigned long)src.height, (unsigned long)w, (unsigned long)h, (unsigned long)format];
    if ([_scalerFailed isEqualToString:key]) return nil;
    if (![_scalerKey isEqualToString:key]) {
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.inputWidth = src.width;
        d.inputHeight = src.height;
        d.outputWidth = w;
        d.outputHeight = h;
        d.colorTextureFormat = format;
        d.outputTextureFormat = format;
        d.colorProcessingMode = is_float_format(format) ? MTLFXSpatialScalerColorProcessingModeHDR
            : is_srgb_format(format) ? MTLFXSpatialScalerColorProcessingModeLinear
                                     : MTLFXSpatialScalerColorProcessingModePerceptual;
        _scaler = [d newSpatialScalerWithDevice:_device];
        _scalerKey = _scaler ? key : nil;
        if (!_scaler) {
            _scalerFailed = key;
            say("MetalFX has no scaler for %s; FSR 1 instead", key.UTF8String);
            return nil;
        }
        say("MetalFX scaler %s", key.UTF8String);
    }
    id<MTLTexture> mid = [self midWidth:w height:h format:format usage:_scaler.outputTextureUsage];
    if (!mid) {
        _scalerFailed = key;
        _scalerKey = nil;
        _scaler = nil;
        say("no texture for MetalFX's output %s; FSR 1 instead", key.UTF8String);
        return nil;
    }
    _scaler.colorTexture = src;
    _scaler.outputTexture = mid;
    _scaler.inputContentWidth = src.width;
    _scaler.inputContentHeight = src.height;
    [_scaler encodeToCommandBuffer:cb];
    return mid;
}

- (BOOL)encodeLockedFrom:(id<MTLTexture>)src to:(id<MTLTexture>)dst on:(id<MTLCommandBuffer>)cb {
    NSUInteger w = src.width, h = src.height, W = dst.width, H = dst.height;
    if (W <= w && H <= h) {
        // Nothing to scale up: the frame as it is, or filtered down.
        float inverse[2] = {1.0f / (float)W, 1.0f / (float)H};
        return [self pass:(W == w && H == h) ? @"pp_copy" : @"pp_bilinear" from:src to:dst bytes:inverse
                   length:sizeof inverse on:cb];
    }
    id<MTLTexture> mid = _mode == PP_UPSCALE_METALFX ? [self metalFXFrom:src width:W height:H on:cb] : nil;
    if (!mid) {
        // FsrEasuCon with the viewport the whole source.
        float con[16] = {
            (float)w / W, (float)h / H, 0.5f * w / W - 0.5f, 0.5f * h / H - 0.5f,
            1.0f / w, 1.0f / h, 1.0f / w, -1.0f / h,
            -1.0f / w, 2.0f / h, 1.0f / w, 2.0f / h,
            0.0f, 4.0f / h, 0.0f, 0.0f,
        };
        mid = [self midWidth:W height:H format:src.pixelFormat usage:0];
        if (!mid || ![self pass:@"pp_easu" from:src to:mid bytes:con length:sizeof con on:cb]) return NO;
    }
    // FsrRcasCon: sharpness from stops. Not on HDR values, which RCAS's limits
    // (the 0 to 1 range) do not fit.
    if (_stops >= 0 && !is_float_format(dst.pixelFormat)) {
        float sharpness = exp2f(-_stops);
        return [self pass:@"pp_rcas" from:mid to:dst bytes:&sharpness length:sizeof sharpness on:cb];
    }
    return [self pass:@"pp_copy" from:mid to:dst bytes:NULL length:0 on:cb];
}

- (BOOL)encodeFrom:(id<MTLTexture>)src to:(id<MTLTexture>)dst on:(id<MTLCommandBuffer>)cb {
    os_unfair_lock_lock(&_lock);
    BOOL ok = [self encodeLockedFrom:src to:dst on:cb];
    os_unfair_lock_unlock(&_lock);
    return ok;
}

- (BOOL)encode:(PPUpscaleDrawable *)p on:(id<MTLCommandBuffer>)cb {
    id<MTLTexture> src = p.texture, dst = p.real.texture;
    objc_setAssociatedObject(dst, readable_source_key(), src, OBJC_ASSOCIATION_RETAIN);
    BOOL ok = [self encodeFrom:src to:dst on:cb];
    if (!ok) say("could not encode a frame %lux%lu to %lux%lu", (unsigned long)src.width,
                 (unsigned long)src.height, (unsigned long)dst.width, (unsigned long)dst.height);
    return ok;
}

// -present on one of ours: Metal 4's way, or a caller that presents a drawable
// itself. The upscale runs on Playport's queue once the game's queue says the
// frame is drawn (signalDrawable:), and the real drawable is presented there.
- (void)presentOwn:(PPUpscaleDrawable *)p kind:(int)kind time:(CFTimeInterval)t {
    if (p.done) return;
    p.done = YES;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    uint64_t drawn = p.renderedValue;
    if (drawn) [cb encodeWaitForEvent:_rendered value:drawn];
    [self encode:p on:cb];
    uint64_t read = atomic_fetch_add(&_consumedN, 1) + 1;
    [cb encodeSignalEvent:_consumed value:read];
    os_unfair_lock_lock(&_lock);
    if (_pool[p.slot] == p.texture) _poolConsumed[p.slot] = read;
    os_unfair_lock_unlock(&_lock);
    switch (kind) {
    case 1: [cb presentDrawable:p.real atTime:t]; break;
    case 2: [cb presentDrawable:p.real afterMinimumDuration:t]; break;
    default: [cb presentDrawable:p.real]; break;
    }
    [cb commit];
}

- (void)residentOn:(id<MTL4CommandQueue>)q {
    os_unfair_lock_lock(&_lock);
    BOOL add = _residency && ![_residentOn containsObject:q];
    if (add) [_residentOn addObject:q];
    os_unfair_lock_unlock(&_lock);
    if (add) {
        [q addResidencySet:_residency];
        say("frames resident on a Metal 4 queue");
    }
}

// waitForDrawable: on one of ours: the game's queue draws into the texture
// only after the upscale that last read it.
- (void)queue:(id<MTL4CommandQueue>)q waitsFor:(PPUpscaleDrawable *)p {
    [self residentOn:q];
    os_unfair_lock_lock(&_lock);
    uint64_t read = _pool[p.slot] == p.texture ? _poolConsumed[p.slot] : atomic_load(&_consumedN);
    os_unfair_lock_unlock(&_lock);
    if (read) [q waitForEvent:_consumed value:read];
}

// signalDrawable: on one of ours: the event the upscale waits for.
- (void)queue:(id<MTL4CommandQueue>)q signals:(PPUpscaleDrawable *)p {
    [self residentOn:q];
    uint64_t drawn = atomic_fetch_add(&_renderedN, 1) + 1;
    [q signalEvent:_rendered value:drawn];
    p.renderedValue = drawn;
}

@end

// MARK: C entry points

int pp_upscale_configure(int mode, float rcas_stops, char *note, size_t note_size) {
    NSString *line = nil;
    int got = [PPUpscaler.shared configure:mode stops:rcas_stops note:&line];
    if (note && note_size) snprintf(note, note_size, "%s", line.UTF8String ?: "");
    return got;
}

bool pp_upscale_active(void) { return PPUpscaler.shared.mode != PP_UPSCALE_OFF; }

CAMetalLayer *pp_upscale_output_layer(void) {
    PPUpscaler *u = PPUpscaler.shared;
    return u.mode != PP_UPSCALE_OFF ? u.output : nil;
}

void pp_upscale_set_panel(double width, double height) { [PPUpscaler.shared setPanelWidth:width height:height]; }

id<CAMetalDrawable> pp_upscale_next_drawable(CAMetalLayer *game) { return [PPUpscaler.shared nextFor:game]; }

bool pp_upscale_encode_for_test(id<MTLTexture> src, id<MTLTexture> dst, id<MTLCommandBuffer> cb) {
    return [PPUpscaler.shared encodeFrom:src to:dst on:cb];
}

const char *pp_upscale_shader_source(void) { return pp_upscaler_shaders; }
