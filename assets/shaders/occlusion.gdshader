shader_type spatial;
render_mode unshaded, cull_disabled;

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
	ALPHA_SCISSOR_THRESHOLD = 0.5;

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
}
