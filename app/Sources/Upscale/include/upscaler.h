/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * upscaler.h: a game's picture scaled up to the screen's pixels as each frame
 * is presented (upscaler.m), for every game whatever draws it: DXMT, and
 * KosmicKrisp under DXVK, vkd3d-proton and Zink. Off, Core Animation scales
 * the game's drawable to the view with plain filtering, as before.
 *
 * Swift's PacedMetalLayer (HostIO.swift) asks pp_upscale_next_drawable for the
 * game's drawable while pp_upscale_active(); GameSurfaceView puts
 * pp_upscale_output_layer() in its layer, below the guest's windows, and
 * tells pp_upscale_set_panel the pixels it covers.
 */
#ifndef PLAYPORT_UPSCALER_H
#define PLAYPORT_UPSCALER_H

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdbool.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

/* Modes for pp_upscale_configure. */
#define PP_UPSCALE_OFF 0
#define PP_UPSCALE_METALFX 1 /* Apple's MetalFX spatial scaler */
#define PP_UPSCALE_FSR1 2    /* AMD FidelityFX Super Resolution 1: EASU, then RCAS */

/* Before the runtime starts. rcas_stops is RCAS's sharpness after the scaling,
 * in stops (0 the most, each stop halves it), negative for none. Returns the
 * mode in effect: PP_UPSCALE_OFF when the hooks or the shaders could not be
 * set up, PP_UPSCALE_FSR1 for MetalFX on a GPU without it. note (NULL for
 * none) receives one line for the log. */
int pp_upscale_configure(int mode, float rcas_stops, char *_Nullable note, size_t note_size);

/* Whether frames go through the upscaler (a mode other than off is in effect). */
bool pp_upscale_active(void);

/* The layer the upscaled frames are shown on; nil before a mode is in effect. */
CAMetalLayer *_Nullable pp_upscale_output_layer(void);

/* The pixels the game's view covers (its bounds times its scale), the most
 * an upscaled frame has. Main thread. */
void pp_upscale_set_panel(double width, double height);

/* The drawable the game draws its frame into: a texture of the game layer's
 * drawableSize and pixelFormat, presented through the upscaler into a drawable
 * of the output layer. nil when none can be had (as nextDrawable's nil). */
id<CAMetalDrawable> _Nullable pp_upscale_next_drawable(CAMetalLayer *game);

/* The GPU's busy time, for Playport's performance HUD: from the first call on,
 * every Metal 3 command buffer's and Metal 4 commit's GPU start and end times
 * are counted (hooks on commit). Returns false when they cannot be. */
bool pp_gpu_stats_start(void);

/* The seconds the GPU was busy since the last call, and the seconds since it;
 * 0 and 0 before pp_gpu_stats_start. */
void pp_gpu_stats_take(double *busy, double *wall);

/* The CI smoke test's (tools/upscaler-smoke): src scaled into dst on cb as a
 * frame is, with the mode in effect. dst must be a render target. */
bool pp_upscale_encode_for_test(id<MTLTexture> src, id<MTLTexture> dst, id<MTLCommandBuffer> cb);

/* The shaders' Metal source, for the CI's offline compile. */
const char *pp_upscale_shader_source(void);

NS_ASSUME_NONNULL_END

#endif
