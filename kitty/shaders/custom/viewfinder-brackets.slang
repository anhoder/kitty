#language slang 2026
// Copyright (C) 2026 Kovid Goyal <kovid at kovidgoyal.net>
// Distributed under terms of the GPLv3 license.
//
// Viewfinder brackets
// Draws an L shaped bracket in each corner of the active window, with an
// optional magnifying glass icon in the top right. It knows nothing about why
// it is drawn, use the active_layout directive in a pipeline file to decide
// when. For example, to mark the window while the tab uses the stack layout,
// save this as shaders/stack-marker.pipeline in the kitty config directory
// and set custom_shaders stack-marker:
//
//   startgroup
//       active_layout stack
//       animation_step 0
//       shaders viewfinder-brackets
//   endgroup
//
// The effect is static: animation_step 0 means it is drawn once when the
// layout starts matching and stays until it stops, costing no redraws in
// between. All sizes are in physical pixels.

import kitty_custom_shader_types;

// Color of the brackets, in linear RGB. Note that linear RGB is not the same
// as the hex colors in kitty.conf: 0.216 is mid grey, not 0.5.
static const float3 COLOR = float3(0.8, 0.3, 0.0);
// How much of COLOR replaces the original color, 1.0 = fully opaque.
static const float OPACITY = 0.95;
// Thickness of the brackets.
static const float THICKNESS = 4.0;
// Length of each arm of a bracket, measured from the corner.
static const float ARM_LENGTH = 40.0;
// Distance between the brackets and the edges of the window.
static const float INSET = 10.0;
// Include the active window's title bar, margin, border and padding in the framed area.
static const bool INCLUDE_WINDOW_PADDING = true;

// An optional magnifying glass in the top right corner, off by default.
static const bool SHOW_ICON = false;
static const float ICON_RADIUS = 9.0;
static const float ICON_STROKE = 3.0;
static const float ICON_HANDLE_LENGTH = 8.0;
// Distance from the top right bracket corner to the center of the lens, on both axes.
static const float ICON_OFFSET = 30.0;

// Coverage of a pixel at distance dist from an edge, for the area closer than limit, with a one pixel soft edge.
float
edge_coverage(float dist, float limit) {
    return clamp(limit - dist + 0.5, 0.0, 1.0);
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float4 g = d.active_window_geometry;
    // Pass through unchanged if no active window geometry is known.
    if (g.z <= 0.0 || g.w <= 0.0) return color;
    if (INCLUDE_WINDOW_PADDING) {
        g.xy -= d.active_window_padding.xy;
        g.zw += d.active_window_padding.xy + d.active_window_padding.zw;
    }

    float2 viewport = float2(d.viewport_size_pixels);
    float2 p = t.pos * viewport;
    float2 lo = g.xy * viewport;
    float2 hi = (g.xy + g.zw) * viewport;
    if (any(p < lo) || any(p > hi)) return color;

    // e.x and e.y are the distances to the nearest vertical and horizontal
    // edge of the inset window, so a pixel is in a bracket if it is close to
    // one edge and not too far from the other, which is true near each corner.
    float2 inner_lo = lo + INSET;
    float2 inner_hi = hi - INSET;
    float2 e = min(p - inner_lo, inner_hi - p);
    float inside = clamp(min(e.x, e.y) + 0.5, 0.0, 1.0);
    float horizontal_arm = min(edge_coverage(e.y, THICKNESS), edge_coverage(e.x, ARM_LENGTH));
    float vertical_arm = min(edge_coverage(e.x, THICKNESS), edge_coverage(e.y, ARM_LENGTH));
    float amount = max(horizontal_arm, vertical_arm) * inside;

    if (SHOW_ICON) {
        float2 center = inner_hi - ICON_OFFSET;
        float lens = abs(length(p - center) - ICON_RADIUS) - ICON_STROKE * 0.5;
        // The handle is a segment going down and to the right from the lens
        float2 direction = float2(0.70710678, -0.70710678);
        float2 start = center + direction * ICON_RADIUS;
        float2 along = direction * ICON_HANDLE_LENGTH;
        float s = clamp(dot(p - start, along) / dot(along, along), 0.0, 1.0);
        float handle = length(p - start - along * s) - ICON_STROKE * 0.5;
        amount = max(amount, clamp(0.5 - min(lens, handle), 0.0, 1.0));
    }

    amount *= OPACITY;
    return float4(lerp(color.rgb, COLOR, amount), color.a);
}
