shader_type spatial;
// depth_prepass_alpha: opaque interiors write depth in a pre-pass (so tile-vs-tile
// and tile-vs-player sorting stays correct), while the semi-transparent keyhole
// fringe blends smoothly over whatever is behind it. This is what lets the
// occluder fade out with distance instead of hard-cutting or dithering.
render_mode unshaded, cull_disabled, depth_prepass_alpha;

// Sprite + its occlusion mask (same region, same UVs).
uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform sampler2D mask_tex : filter_nearest;

// Per tile type: silhouette edge as (a.xy, b.xy) in UV, one per direction.
// Direction order, clockwise from top-left: NW NE E SE SW W. Opposite = +3.
uniform vec4 edges[6];

// Per cell: which directions have a touching neighbor, and the [t0,t1] span
// of that contact along each edge (packed two directions per vec4).
instance uniform int neighbors;
instance uniform vec4 range01;
instance uniform vec4 range23;
instance uniform vec4 range45;

// Iso depth of this cell's center (world · camera_z_axis); greater = closer to
// camera. And the tile's highest world-space Y (its solid top). Both set by
// iso_grid._apply_occlusion, and together decide keyhole eligibility.
instance uniform float tile_depth = 0.0;
instance uniform float tile_top = 0.0;

// Keyhole globals — written every frame by Level (scripts/level.gd).
// keyhole_data is an 8x1 RGBAF texture: texel i = (screen_x_px, screen_y_px,
// entity_iso_depth, entity_feet_world_y). Screen coords share FRAGCOORD's origin.
global uniform int keyhole_count;
global uniform sampler2D keyhole_data;
global uniform float keyhole_radius;    // fully-revealed inner radius, px
global uniform float keyhole_fade;      // gradient width past the radius, px
global uniform float keyhole_min_alpha; // opacity an occluder keeps at the center

// A tile must rise at least this far above the entity's feet to count as an
// occluder — keeps ground tiles the entity walks among (same level, in front)
// from being erased; only things that actually stand over it fade.
const float KEY_TOP_MARGIN = 1.0;

int decode_dir(vec3 c) {
	bool r = c.r > 0.5, g = c.g > 0.5, b = c.b > 0.5;
	if (r && !g && !b) return 0; // red     NW
	if (!r && g && !b) return 1; // green   NE
	if (!r && g && b)  return 2; // cyan    E
	if (!r && !g && b) return 3; // blue    SE
	if (r && g && !b)  return 4; // yellow  SW
	if (r && !g && b)  return 5; // magenta W
	return -1;
}

vec2 range_for(int d) {
	if (d == 0) return range01.xy;
	if (d == 1) return range01.zw;
	if (d == 2) return range23.xy;
	if (d == 3) return range23.zw;
	if (d == 4) return range45.xy;
	return range45.zw;
}

void vertex() {
	// Full billboard, keeping the mesh's own scale (pixel-perfect).
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;

	int d = decode_dir(texture(mask_tex, UV).rgb);
	if (d >= 0 && (neighbors & (1 << d)) != 0) {
		vec2 a = edges[d].xy;
		vec2 ab = edges[d].zw - a;
		// Project this pixel onto the edge; t is its position along it.
		float t = clamp(dot(UV - a, ab) / dot(ab, ab), 0.0, 1.0);
		vec2 span = range_for(d);
		if (t >= span.x && t <= span.y)
			ALPHA = 0.0; // outline pixel is backed by the neighbor: erase it
	}

	// Keyhole reveal. A tile is eligible only when it stands between the camera
	// and an entity: closer than the entity in iso depth AND tall enough to rise
	// over the entity's feet. Eligible tiles fade toward keyhole_min_alpha within
	// keyhole_radius of the entity's screen position, easing out over keyhole_fade.
	if (keyhole_count > 0) {
		float reveal = 0.0;
		for (int i = 0; i < keyhole_count; i++) {
			// texel: (screen_x_px, screen_y_px, entity_iso_depth, entity_feet_y)
			vec4 kd = texelFetch(keyhole_data, ivec2(i, 0), 0);
			if (tile_depth <= kd.z) continue;               // behind the entity
			if (tile_top <= kd.w + KEY_TOP_MARGIN) continue; // too low to occlude it
			// Snap the disc center to the art-pixel grid (FRAGCOORD is 1 unit per
			// render pixel here) so the gradient locks to whole pixels and steps
			// in whole pixels as the entity moves, instead of crawling sub-pixel.
			vec2 center = floor(kd.xy) + 0.5;
			float dist = length(FRAGCOORD.xy - center);
			// Smooth per-pixel falloff: one continuous alpha value per art pixel.
			reveal = max(reveal, 1.0 - smoothstep(keyhole_radius, keyhole_radius + keyhole_fade, dist));
		}
		ALPHA *= 1.0 - reveal * (1.0 - keyhole_min_alpha);
	}
}
