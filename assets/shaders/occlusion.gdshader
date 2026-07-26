shader_type spatial;
// Outline erasing + keyhole reveal. See docs/outline_occlusion.md and docs/player_transparency.md.
render_mode unshaded, cull_disabled, depth_prepass_alpha;

// Sprite + its occlusion mask (same region, same UVs).
uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform sampler2D mask_tex : filter_nearest;

// Per tile type: silhouette edge (a.xy, b.xy) in UV, clockwise from top-left.
uniform vec4 edges[6];

// Per cell: touched directions, and the [t0,t1] contact span along each edge.
instance uniform int neighbors;
instance uniform vec4 range01;
instance uniform vec4 range23;
instance uniform vec4 range45;

// Per cell: cameraward corner (world), grid height, interior-zone bitmask.
instance uniform vec3 tile_near = vec3(0.0);
instance uniform float tile_layer = 0.0;
instance uniform int tile_zones = 0;

// Per cell: fade group, 1.0 for the group's camera-facing shell, 1.0 for a ramp.
instance uniform int tile_group = -1;
instance uniform float tile_shell = 1.0;
instance uniform float tile_ramp = 0.0;

// Keyhole globals, written every frame by Level (scripts/level.gd).
global uniform int keyhole_count;
global uniform sampler2D keyhole_data;
global uniform float keyhole_radius;
global uniform float keyhole_fade;
global uniform float keyhole_min_alpha;
global uniform float keyhole_above_reach;

// Per-group gate texture, plus the two blends that disable it and the shell cut.
global uniform sampler2D keyhole_groups;
global uniform float keyhole_gate_enable;
global uniform float keyhole_shell_cut;

// World units a tile must clear the entity's far corner by to occlude fully.
const float KEY_GATE_SOFT = 12.0;

// Rise below which a tile is a step the entity could walk onto, not an occluder.
const float KEY_MIN_RISE = 5.0;
const vec3 KEY_RISE = vec3(0.0, KEY_MIN_RISE, 0.0);

// Layers above the entity's floor at which a tile reads as overhead.
const float KEY_ABOVE_LAYERS = 2.0;

// How much of the shell's reveal is enough to clear a group's interior cells.
const float KEY_SHELL_SHARPEN = 0.25;

// Mask color -> direction index, or -1 for black/white (never erased).
int decode_dir(vec3 c) {
	int code = (c.r > 0.5 ? 4 : 0) + (c.g > 0.5 ? 2 : 0) + (c.b > 0.5 ? 1 : 0);
	if (code == 4) return 0; // red     NW
	if (code == 2) return 1; // green   NE
	if (code == 3) return 2; // cyan    E
	if (code == 1) return 3; // blue    SE
	if (code == 6) return 4; // yellow  SW
	if (code == 5) return 5; // magenta W
	return -1;
}

vec2 range_for(int d) {
	vec4 packed = d < 2 ? range01 : (d < 4 ? range23 : range45);
	return (d & 1) == 0 ? packed.xy : packed.zw;
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

	if (neighbors != 0) {
		int d = decode_dir(texture(mask_tex, UV).rgb);
		if (d >= 0 && (neighbors & (1 << d)) != 0) {
			vec2 a = edges[d].xy;
			vec2 ab = edges[d].zw - a;
			// Position along the edge, the same projection the CPU parametrised with.
			float t = clamp(dot(UV - a, ab) / dot(ab, ab), 0.0, 1.0);
			vec2 span = range_for(d);
			if (t >= span.x && t <= span.y)
				ALPHA = 0.0;
		}
	}

	float reveal = 0.0;
	bool cut = false;
	for (int i = 0; i < keyhole_count; i++) {
		vec4 e0 = texelFetch(keyhole_data, ivec2(i, 0), 0);
		vec4 e1 = texelFetch(keyhole_data, ivec2(i, 1), 0);
		bool above = tile_layer >= e0.z + KEY_ABOVE_LAYERS;

		// Overhead and sharing an interior zone with the entity: gone entirely.
		if (above && (tile_zones & int(e0.w)) != 0) { cut = true; break; }

		// A steppable ramp is a layer tall against a taller body: it never hides it.
		if (tile_ramp > 0.5 && tile_layer <= e0.z + 1.0) continue;

		// Occludes only where it clears the entity's far corner on +X, +Y and +Z at once.
		vec3 clear = smoothstep(KEY_RISE, KEY_RISE + vec3(KEY_GATE_SOFT), tile_near - e1.xyz);
		float axis = min(min(clear.x, clear.y), clear.z);
		if (axis <= 0.0) continue;

		// Snapped to whole pixels so the gradient does not shimmer as the entity moves.
		vec2 center = floor(e0.xy) + 0.5;
		float dist = length(FRAGCOORD.xy - center);
		float reach = keyhole_fade + (above ? keyhole_above_reach : 0.0);
		reveal = max(reveal, axis * (1.0 - smoothstep(keyhole_radius, keyhole_radius + reach, dist)));
	}

	// Occlusion gate: subtractive, so gate 1.0 leaves the reveal above untouched.
	float gate = tile_group < 0 ? 1.0 : texelFetch(keyhole_groups, ivec2(tile_group, 0), 0).r;
	gate = mix(1.0, gate, keyhole_gate_enable);

	// The shell keeps the soft gradient; cells it hides behind itself clear sooner.
	float shell = mix(1.0, tile_shell, keyhole_shell_cut);
	float shell_alpha = 1.0 - reveal * (1.0 - keyhole_min_alpha);
	float inner_alpha = 1.0 - smoothstep(0.0, KEY_SHELL_SHARPEN, reveal);
	ALPHA = cut ? 0.0 : ALPHA * mix(1.0, mix(inner_alpha, shell_alpha, shell), gate);
}
