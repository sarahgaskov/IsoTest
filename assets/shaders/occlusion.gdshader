shader_type spatial;
render_mode unshaded, cull_disabled;

// Sprite + its occlusion mask (same region, same UVs).
uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform sampler2D mask_tex : filter_nearest;

// Per cell: which of the six silhouette directions have a touching neighbor
// (each erased in full — all-or-nothing). Direction order, clockwise from
// top-left: NW NE E SE SW W. Opposite = +3.
instance uniform int neighbors;

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
	if (d >= 0 && (neighbors & (1 << d)) != 0)
		ALPHA = 0.0; // outline pixel is backed by the neighbor: erase it
}
