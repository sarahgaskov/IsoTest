# Outline occlusion pipeline

Wherever two tiles touch, the dark outline baked into each sprite is made
transparent, so neighbouring tiles read as one continuous surface while the
outer silhouette of the whole shape keeps its outline.

The effect is produced by five cooperating pieces:

1. **Occlusion masks** (`assets/2d/occlusion/<sheet>_o.png`) — hand-painted, one
   per tilesheet. Each marks the six silhouette edges of a tile with a flat
   colour.
2. **`OcclusionMaskBaker`** (`scripts/o_mask_baker.gd`) — turns a mask into a
   small JSON description of where each edge starts and ends, cached on disk.
3. **`MeshDepth`** (`scripts/o_mesh_depth.gd`) — rasterizes each tile's mesh
   through the fixed iso projection into a per-pixel [front, back] depth span,
   the ground truth for what the tile's surface occupies in 3D.
4. **`OcclusionContact`** (`scripts/o_contact.gd`) — for a placed cell, detects
   where along each edge a neighbour's surface actually touches it.
5. **`IsoGrid` + `occlusion.gdshader`** (`scripts/iso_grid.gd`) — draws one
   billboard per placed cell and the shader erases the outline along the touched
   spans.

Contact is **mesh-driven and per-length**: the criterion is depth contact vs.
exposure. An outline pixel is erased where a neighbour's surface *touches* it
in 3D — at any dihedral angle, so a wall base resting on a floor erases exactly
like a coplanar merge — and kept where its outward side is *exposed*: empty, or
holding a surface far enough behind that the edge reads as a real step. The
mesh decides how far contact runs along an edge; the mask decides which pixels
are ever eligible (artist veto + edge identity). Earlier edge-vs-edge overlap
attempts are documented in `docs/occlusion_mesh_plan.md` — two adjacent cubes
each hide a *different* diagonal corner of their shared face, so their
silhouette edges never coincide; the depth-contact approach avoids comparing
edges entirely.

## The six directions

A tile's silhouette is a hexagon with six edges. Each is a colour on the mask
and an index in code, ordered clockwise from the top-left:

| Index | Name | Mask colour | Opposite (`+3 mod 6`) |
|------:|------|-------------|-----------------------|
| 0 | NW | red      | 3 SE |
| 1 | NE | green    | 4 SW |
| 2 | E  | cyan     | 5 W  |
| 3 | SE | blue     | 0 NW |
| 4 | SW | yellow   | 1 NE |
| 5 | W  | magenta  | 2 E  |

Two touching tiles meet on opposite edges: a tile's NE edge lies against its
neighbour's SW edge, etc. — hence "opposite = index + 3".

---

## `scripts/o_mask_baker.gd` — the baker

Runs in the editor (or first run) to convert the painted mask into edge
endpoints. Everything is `static`; nothing is instanced.

### `ensure(sheet_path, regions) -> Array`
The only entry point. Given a tilesheet path and the pixel regions of the tiles
on it, returns one baked record per region (or `[]` if the sheet has no mask).

- Derives the mask path (`occlusion/<name>_o.png`) and the cache path
  (`occlusion/<name>_o.json`).
- Computes the mask file's MD5. If a cache exists whose stored hash matches and
  whose tile count matches, the mask is unchanged → it decodes and returns the
  cache without rebaking. **This is the "don't rebake unless necessary" step.**
- Otherwise it bakes fresh, writes the cache (`hash` + per-tile `edges`), and
  returns the decoded result.

### `_bake(mask_path, regions) -> Array`
Loads the mask as a raw image (`Image.load_from_file`, which bypasses Godot's
import so the colours are pixel-exact) and, for each region, crops it and finds
each direction's edge. Produces `{region: [w,h], edges: {"0": [ax,ay,bx,by], …}}`
in region-local pixels.

### `_pixels(img, col) -> Array`
Returns every pixel position in a cropped region whose colour matches `col`
(within a small tolerance). This is the set of pixels belonging to one direction.

### `_farthest_pair(pts) -> Array`
Given all the pixels of one coloured band, returns the two that are farthest
apart. For the thin strips the mask paints along each edge, that pair is the two
ends of the edge — the segment endpoints we bake. O(n²), but the bands are only
a few hundred pixels, so it runs once and is cheap.

### `_decode(tile) -> Dictionary`
Converts one cached tile record into the runtime form the grid/shader want:
- `edges` — six `Vector4`s `(ax, ay, bx, by)` in **UV space** (pixels ÷ size);
  absent directions stay zero.
- `out` — six `Vector2` outward screen normals, computed as
  `normalize(edge_midpoint − centre)`. Used to decide which edge a neighbour
  presses against.
- `present` — a 6-bit mask of which directions actually exist on this tile.

### `_decode_all(tiles) -> Array`
Maps `_decode` over every tile in a cache/bake result.

### `raw_mask(sheet_path) -> Image`
The mask as painted on disk (`Image.load_from_file`, bypassing import), for
pixel-exact colour analysis at rebuild time.

### `region_pixels(img, region) -> Array`
One tile region's mask pixels grouped by direction (six arrays of region-local
positions) — the per-pixel eligibility sets `OcclusionContact` walks.

### `_sibling(sheet_path, suffix) -> String`
Path helper: `<dir>/occlusion/<basename><suffix>` — used for both the `_o.png`
mask and the `_o.json` cache.

---

## `scripts/o_mesh_depth.gd` — the depth rasterizer

`MeshDepth` renders a tile's mesh on the CPU, once per type, into the sprite
region's pixel space (origin at the region centre, `+y` down): each pixel holds
a `Vector2(front, back)` — the depth span of the solid under it, or
`(INF, -INF)` when uncovered. Storing the *back* surface too is what makes a
front neighbour's touching face detectable: that face is hidden behind the
neighbour's own body, so its front depth alone never matches. All `static`.

### `rasterize(mesh, size, offset_px) -> PackedVector2Array`
Projects every triangle through `Iso.facing()`
(`screen = (v·right, −v·up) / PIXEL_SCALE + origin`, `depth = v·(−facing.z)`)
and scan-converts it (`_scan`, barycentric at pixel centres), min/maxing each
covered pixel's span. Rasterizing once keeps every later query O(1) — earlier
per-query triangle walks froze the editor.

### `at(tile, size, pos) -> Vector2` / `covered(tile, size, pos) -> bool`
Constant-time span lookup / coverage test at a pixel position.

### `first_covered(tile, size, from, dir, steps) -> Variant`
Walks from a position in 1 px steps until it finds a covered pixel; `null` when
none within `steps`. Used to cross the border between the (wider) mask wedge
and the mesh silhouette, and by `IsoGrid` to build each edge's contact probes.

---

## `scripts/iso_grid.gd` — the grid (occlusion parts)

`IsoGrid` is the `GridMap`. It keeps the cell data and collision, but because a
`GridMap` batches its cells and exposes no per-cell shader inputs, **the sprites
are drawn by a separate layer of one billboard per cell** so each can carry its
own neighbour data.

### `_setup()`
Called from `_ready` (runtime-safe: never writes to disk). Clears the type
cache, mutes the `GridMap`'s own meshes, and refreshes the sprite layer — which
builds the render types **lazily**, only for the tiles actually placed. This is
what makes the effect appear on scene load without pressing a button, and keeps
start-up proportional to the tiles in the scene rather than the whole config.

### `rebuild()`
The editor "Rebuild tiles" button. Rewrites and saves the `MeshLibrary`
(collision shapes + palette previews; placed meshes only in 3D-debug mode), then
clears the types and refreshes so they rebuild lazily. Writes to disk, so
editor-only.

### `rebake()`
The "Rebake occlusion" button. Deletes the cache JSONs so the next bake is
forced from scratch, then calls `rebuild()`.

### `_mute_library()`
Strips the meshes off every `MeshLibrary` item in memory (leaving shapes and
previews) so the `GridMap` draws only collision and the sprite layer owns the
visuals — otherwise the tile would be drawn twice. Does not save, so the file on
disk is untouched.

### `_build_types(want)`
Builds a render type via `_make_type` for each requested tile id, **additively**
into `_types` (a rebuild only pays for the tiles placed). Calls
`OcclusionMaskBaker.ensure` once per sheet with all its regions (so the md5
cache stays valid) but only builds the wanted ids. Rasterizing a mesh and
walking its contact probes is the pipeline's one heavy step, so unused tiles
never do it. `_refresh_sprites` calls this with the ids missing for the cells on
the map.

### `_faces(tile) -> PackedVector3Array`
The tile's mesh triangles rotated to its cardinal `"rot"` (`n/e/s/w`, default
`n`) — one shared `.obj` serves all four facings. `_make_type`'s rasteriser,
`_collision`, and the 3D debug view all consume this, so rotation is data, not a
duplicated model.

### `_make_type(tile, sheet, mask, raw, baked) -> Dictionary`
Builds everything one tile type needs:
- `mesh` — its billboard quad (`_quad`).
- `depth`, `region_size`, `origin` — the type's rasterized `MeshDepth` tile and
  its pixel-space frame (`_faces` supplies the rotated triangles).
- `region_px` — mask pixels grouped by direction (from the raw mask, so colours
  are exact).
- `edges` — the baked mask edge per direction, used to parametrise `t` (a fully
  painted band therefore spans `t` 0→1).
- `probes` — per edge, one `[t_lo, t_hi, s.x, s.y, depth]` per distinct
  silhouette point: every mask pixel is walked inward to the mesh, then pixels
  sharing a silhouette point collapse into one probe carrying their `t` range.
  This is what `OcclusionContact._span` consumes.
- `mat` — a `ShaderMaterial` on `occlusion.gdshader`, given the cropped sprite
  (`albedo_tex`), the cropped mask (`mask_tex`, or a 1×1 black fallback), and
  `edges`.
- `out`, `present` — baked data for the CPU-side neighbour resolution.

### `_load_mask(sheet_path) -> Image`
Loads the mask through the resource system (`load(...).get_image()`) for shader
sampling — tolerant of import compression and works in exported builds (unlike
the baker's raw-file load). Returns `null` if the sheet has no mask.

### `_crop(img, region) -> ImageTexture`
Cuts a tile's region out of a full sheet/mask image into its own texture, so the
quad's `UV` 0–1 maps straight onto that tile.

### `_fallback_mask() -> ImageTexture`
A cached 1×1 black texture used when a sheet has no mask. Black decodes to "no
direction", so the shader never erases anything — the sprite renders normally.

### `_zeros(v) -> Array`
Small helper returning a six-element array filled with `v` (zero edges / normals
for absent bake data).

### `_quad(tile) -> QuadMesh`
The pixel-perfect billboard quad: sized to the tile's region and offset by its
`offset_px`. No material of its own — the type's shader material is applied as an
override.

### `_refresh_sprites()`
Rebuilds the sprite layer to match the currently placed cells:
- Hidden entirely in 3D-debug mode (the `GridMap` draws real meshes then).
- Frees billboards for cells that are gone, reuses the rest, and creates new ones
  for new cells (each tagged with its cell coord, owner-less so it isn't saved).
- Assigns each its type's mesh + material, positions it, and calls
  `_apply_occlusion`.
- Runs whenever the used-cell set changes (checked each `_process` in-editor).

### `_apply_occlusion(mi, cell)`
Asks `OcclusionContact.resolve` where this cell touches its neighbours, then
pushes the result onto the billboard as instance parameters: the `neighbors`
bitmask and the three `range*` vec4s (the six `[t0,t1]` spans, packed two per
vec4). This is the only bridge between the contact detection and the shader.

### `_sprite_layer() -> Node3D`
Returns (creating once) the owner-less `SpriteLayer` child that holds every
billboard.

---

## `scripts/o_contact.gd` — the contact detection

`OcclusionContact` is the tile-touch detector, split out of the grid: pure
geometry over the grid's cells and baked tile types, with no rendering and no
state beyond a per-pair memo. All `static`.

Its knobs are physical: `SLOP_PX` (how far outward to probe for the neighbour's
surface), `DEPTH_TOL` (world-unit slack for raster jitter where two surfaces
meet — kept tight, so a neighbour whose surface *recedes* below the current
tile's, like a slope dropping away behind a flat top, does **not** count as
continuing the plane and the outline survives as a silhouette), `GAP` (runs
closer than this merge) and `MIN_SPAN` (a merged run must be longer than the
halo a mere corner touch leaves around a vertex — anything shorter is a corner
*meeting*, not surface contact, and keeps its ink).

The unit of work is a **probe**: one silhouette point of an edge, carrying the
`[t_lo, t_hi]` range of mask pixels that walk to it and the tile's front depth
there (precomputed once per type in `IsoGrid._make_type`, packed as
`[t_lo, t_hi, s.x, s.y, depth]`). A probe that contacts erases its whole `t`
range, so a fully-backed edge erases across its entire painted length.

### `resolve(grid, cell, types) -> Dictionary`
The entry point. For the given cell it returns
`{neighbors: int, spans: Array[Vector2]}` — which of the six edges are touched
and the `[t0,t1]` contact span along each. Every one of the 26 surrounding
occupied cells contributes per-direction runs (`_contact`), which are then
combined per edge by `_merge`.

### `_merge(runs) -> Variant`
Unions overlapping / near-touching runs (within `GAP`) along one edge and keeps
the longest; `null` when even that is shorter than `MIN_SPAN`. A plain
bounding-interval union is wrong here: two point-touches at opposite corners
would bridge into a full-edge erase.

### `_contact(grid, a_id, b_id, a, b, off) -> Array`
Per-direction contact runs of one type pair at one cell offset. Projects the
offset into screen pixels and a depth shift, then runs `_span` per direction.
Because tiles are `UNIT` tall while cells are shorter, stacked layers overlap;
for vertical offsets the pair is evaluated at both the true placement and the
overlap-corrected height, so a surface continuing across a layer boundary still
registers. Depends only on the two types and the offset, so memoised in
`_cache` (cleared by `clear()` on every rebuild).

### `_span(a, b, d, screen, shift) -> Variant`
The depth-contact test for one edge. For each probe of edge `d`:
1. Sample the neighbour's depth tile just **outward** of the probe's silhouette
   point (shifted into the neighbour's frame, up to `SLOP_PX` out). No coverage
   means the outward side is **exposed** — the probe's `t` range is folded into
   `keep_lo/keep_hi` and the ink is kept there.
2. **Contact** iff the tile's surface depth is within `DEPTH_TOL` of the
   neighbour's front **or back** surface — near a *surface*, not merely inside
   the solid, which would over-match wrong-direction neighbours. A probe that
   *is* covered but at a mismatched depth is a real step (e.g. a shorter
   diagonal neighbour whose top surface sits below this probe) — it also folds
   into `keep_lo/keep_hi`, same as an exposed probe.
A contacting probe contributes its `[t_lo, t_hi]`; the min/max over all
contacting probes is the run. That run then **reaches the edge end** across
probes it fell short of — corner rounding, or a neighbour that covers but
mis-reads by a pixel of jitter — *unless* a kept probe sits in the gap. A kept
gap is real silhouette (a neighbour too short, absent, or too far behind to
back the ink, e.g. a tall tile rising above a shorter diagonal neighbour), so
the outline is kept there. This is what distinguishes "the whole edge is
backed, snap it closed" from "the top of this edge stands above its
neighbour, keep it" — folding depth-mismatched-but-covered probes into the
same kept set as exposed ones matters most for diagonal neighbours, where the
contact run can be genuinely short (e.g. a half-height neighbour covering
only the bottom fraction of the edge): without it, that short run used to
bridge all the way to the edge's far end and erase silhouette that should
have stayed visible.

### `_zero_spans() -> Array`
Six `Vector2.ZERO`s — the default "no contact" spans.

### `_neighbor_offsets() -> Array`
Builds the 26 `Vector3i` offsets around a cell (3×3×3 minus the centre),
memoised in a static var.

### Verifying changes
`tools/occ_diag.gd` (run headless:
`godot --headless --path <project> --script res://tools/occ_diag.gd`) rebuilds
the original all-cube terrace, checks the rasterized extents, prints every
per-offset span table, simulates the shader per pixel for every cell, and
composites the scene to PNGs — diffing both against the all-or-nothing baseline
(pixel-identical). `tools/tile_fit.gd` checks every tile's mesh↔art fit and
composites a demo layout; `tools/repro.gd` renders mixed ramps / pyramids /
plates for eyeballing. `tools/repro4.gd` isolates a tall slab against a short
slab at each of the four diagonal cell offsets, prints per-probe
contact/exposed/depthfail classification for the E/W edges, and renders each
case at 8x — the regression guard for the depth-mismatched-but-covered-probe
bridging bug (see `_span` above).

---

## `assets/shaders/occlusion.gdshader` — the shader

A spatial shader, run per billboard. Uniforms per **tile type**: `albedo_tex`,
`mask_tex`, `edges[6]`. Instance parameters per **cell**: `neighbors` and the
three `range*` vec4s (two directions each).

### `vertex()`
Billboards the quad to face the camera while keeping its own scale, so the sprite
stays pixel-perfect regardless of the tile's position (the same result the old
`StandardMaterial3D` billboard produced).

### `decode_dir(colour) -> int`
Maps a mask pixel's colour to a direction index 0–5, or −1 for black / outside
the painted bands. This is what guarantees the shader **never erases pixels
outside the mask area** — an undecoded pixel is simply drawn.

### `range_for(d) -> vec2`
Unpacks the `[t0,t1]` span for direction `d` from the three `range*` vec4s.

### `fragment()`
1. Samples the sprite; sets colour, alpha, and the 0.5 alpha-scissor threshold
   (hard-edged transparency, matching the original look).
2. Decodes this pixel's direction from the mask. If that direction has a
   neighbour (`neighbors` bit set):
   - projects the pixel onto the edge segment via the dot product to get its
     position `t` along the edge,
   - and if `t` falls inside that direction's span, sets alpha to 0 so the
     outline pixel is scissored away.

The spans carry real sub-ranges now — a slab, column or staircase neighbour
erases only the stretch of the edge it actually presses against; a fully
backed edge arrives as `[0,1]` and disappears whole.

---

## Data flow, end to end

```
paint mask ─▶ OcclusionMaskBaker.ensure ─▶ <sheet>_o.json (cached by md5)
                                              │  decoded: edges (UV), out, present
tile .obj ─▶ MeshDepth.rasterize ─▶ per-pixel [front, back] depth tile
                                              ▼
config (tiles.json) ─▶ _build_types ─▶ _types[id] = {mesh, mat, edges, out,
                                              │      present, depth, region_px, …}
placed cells ─▶ _refresh_sprites ─▶ one billboard per cell
                                              │
                     _apply_occlusion ─▶ OcclusionContact.resolve
                                              │  neighbors bitmask + [t0,t1] spans
                                              ▼  (instance params)
                          occlusion.gdshader ─▶ erase outline where tiles touch
```
