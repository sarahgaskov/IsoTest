# Outline occlusion pipeline

Wherever two tiles touch, the dark outline baked into each sprite is made
transparent, so neighbouring tiles read as one continuous surface while the
outer silhouette of the whole shape keeps its outline.

This document is the living reference for that system. Its companion,
[`player_transparency.md`](player_transparency.md), covers the keyhole effect
that shares the same shader.

---

## 1. The idea in one paragraph

Each tile is drawn as a billboarded sprite. The artist paints a **mask** next to
the sprite that marks the six silhouette edges of the tile in six flat colours.
At build time the engine rasterises each tile's **3D mesh** through the fixed
isometric projection into a per-pixel depth span, then — for every placed cell —
walks the mask pixels of each edge and asks "does a neighbour's surface actually
*touch* me here?". The answer is a `[t0, t1]` range along that edge, handed to
the shader as an instance parameter. The shader re-derives each pixel's position
`t` along its edge and erases the pixel when `t` lands inside the range.

Contact is **mesh-driven and per-length**. The criterion is depth contact vs.
exposure: an outline pixel is erased where a neighbour's surface touches it in
3D — at any dihedral angle, so a wall base resting on a floor erases exactly like
a coplanar merge — and kept where its outward side is *exposed*: empty, or
holding a surface far enough behind that the edge reads as a real step. **The
mesh decides how far contact runs along an edge; the mask decides which pixels
are ever eligible** (artist veto + edge identity).

Earlier edge-vs-edge overlap attempts are recorded in
[`occlusion_mesh_plan.md`](occlusion_mesh_plan.md): two adjacent cubes each hide
a *different* diagonal corner of their shared face, so their silhouette edges
never coincide. The depth-contact approach avoids comparing edges entirely.

---

## 2. Cast of files

| File | Role |
|------|------|
| `assets/2d/occlusion/<sheet>_o.png` | Hand-painted mask, one per tilesheet. Six flat colours marking the six silhouette edges of every tile. |
| `assets/2d/occlusion/<sheet>_o.json` | Bake cache, keyed by the mask's MD5. Regenerated automatically when the mask changes. |
| `scripts/o_mask_baker.gd` (`OcclusionMaskBaker`) | Turns a painted mask into per-tile edge segments + outward normals. |
| `scripts/o_mesh_depth.gd` (`MeshDepth`) | CPU-rasterises a tile's mesh through the iso projection into a per-pixel `[front, back]` depth span. |
| `scripts/o_contact.gd` (`OcclusionContact`) | For a placed cell, decides where along each edge a neighbour's surface touches it. |
| `scripts/iso_grid.gd` (`IsoGrid`) | Builds tile types, spawns one billboard per placed cell, pushes contact results as instance parameters. |
| `assets/shaders/occlusion.gdshader` | Samples the mask, re-derives `t`, erases. |
| `scripts/iso.gd` (`Iso`) | The single source of truth for the projection constants everything else shares. |

---

## 3. The six directions

A tile's silhouette is a hexagon with six edges. Each is a colour on the mask and
an index in code, ordered clockwise from the top-left:

| Index | Name | Mask colour | RGB bits | Opposite (`+3 mod 6`) |
|------:|------|-------------|----------|-----------------------|
| 0 | NW | red      | `100` | 3 SE |
| 1 | NE | green    | `010` | 4 SW |
| 2 | E  | cyan     | `011` | 5 W  |
| 3 | SE | blue     | `001` | 0 NW |
| 4 | SW | yellow   | `110` | 1 NE |
| 5 | W  | magenta  | `101` | 2 E  |

Two touching tiles meet on opposite edges — a tile's NE edge lies against its
neighbour's SW edge — hence "opposite = index + 3". Black (`000`) and white
(`111`) decode to `-1`, which means "not part of any edge, never erase".

The order is fixed in three places that must agree: `DIR_COLORS` in
`o_mask_baker.gd`, `decode_dir()` in the shader, and the packing of the three
`range*` vec4s in `IsoGrid._apply_occlusion`.

---

## 4. Coordinate systems and units

Everything lives in one of four spaces. `Iso` (`scripts/iso.gd`) defines the
conversions.

- **Cell space** — the tile's `.obj` vertices, in world units, centred on the
  cell. `Iso.UNIT` (24.0) is the edge of a perfect block.
- **Grid space** — `Vector3i` cell coordinates. `GridMap.cell_size` is
  `Iso.cell()` = `(24, 19.5959…, 24)`. **The Y cell size is *shorter* than
  `UNIT`**, because a stacked layer is only `Iso.LAYER_PX` (24 px) tall on
  screen once the 30° pitch is applied. This mismatch is why `OcclusionContact`
  evaluates vertical neighbour offsets twice (see §8.3).
- **Region pixel space** — the sprite's own pixels, origin at
  `MeshDepth.origin(size, offset_px)` = the region centre shifted by the tile's
  authored `offset_px`, `+y` down. Both the mask analysis and the depth raster
  live here.
- **UV space** — region pixels ÷ region size. This is what the shader sees, so
  the baked `edges` are stored in UV.

The projection itself is `Iso.facing()`, a `Basis` = yaw 45° × pitch −30°. A
world/cell vector `v` maps to:

```
screen_px = (v · facing.x, −v · facing.y) / Iso.PIXEL_SCALE + origin
depth     = v · (−facing.z)               # larger = closer to the camera
```

`Iso.PIXEL_SCALE` is `sqrt(2)/2`, the ratio of 3D width to 2D width that keeps
one pixel of art equal to one pixel on screen.

---

## 5. `scripts/o_mask_baker.gd` — the baker

Runs in the editor (or on first load) to convert the painted mask into edge
endpoints. Everything is `static`; nothing is instanced.

### `DIR_COLORS`
The six direction colours in index order. Also serves as the direction count
(`DIR_COLORS.size()` == 6) throughout the file.

### `ensure(sheet_path, regions) -> Array`
The only entry point. Given a tilesheet path and the pixel regions of the tiles
on it, returns one baked record per region, or `[]` if the sheet has no mask.

1. Derives the mask path (`occlusion/<name>_o.png`) via `_sibling`. No file →
   `[]`, and the sheet renders with no occlusion at all.
2. Derives the cache path (`occlusion/<name>_o.json`) and computes the mask's
   MD5.
3. If a cache exists whose stored `hash` matches **and** whose tile count matches
   `regions.size()`, the mask is unchanged: decode and return without rebaking.
   *This is the "don't rebake unless necessary" step* — a full bake is O(band
   pixels²) per direction.
4. Otherwise bake fresh (`_bake`), write `{hash, tiles}` to the cache, return the
   decoded result.

Note the contract: `ensure` validates the *whole sheet* at once, so `IsoGrid`
hands it every region on that sheet even when only a few tiles are wanted.
Passing a subset would make the cached tile count mismatch and force a rebake
every time.

### `_bake(mask_path, regions) -> Array`
Loads the mask with `Image.load_from_file` — which bypasses Godot's importer, so
the colours are pixel-exact and untouched by compression. For each region it
groups the pixels by direction with `region_pixels`, and for any direction with
at least two pixels takes `_farthest_pair` as the edge segment. Produces
`{region: [w, h], edges: {"0": [ax, ay, bx, by], …}}` in region-local pixels.

### `raw_mask(sheet_path) -> Image`
The mask as painted on disk, again via `Image.load_from_file`. `IsoGrid` uses
this (not the imported texture) for the per-pixel analysis in `_make_type`,
because a lossy import would shift colours off the exact `DIR_COLORS` match.

### `region_pixels(img, region) -> Array`
One tile region's mask pixels grouped by direction: six arrays of region-local
`Vector2` positions. Crops the region, then walks it **once**, testing each pixel
against the six colours. Pixels whose channels sum below 0.5 are skipped
immediately — that is the unpainted background, which is the overwhelming
majority of any mask, and every real direction colour sums to at least 1.0.

This is the per-pixel eligibility set. `_bake` uses it to find edge endpoints;
`IsoGrid._make_type` uses it to build contact probes.

### `_farthest_pair(pts) -> Array`
Given all the pixels of one coloured band, returns the two farthest apart. For
the thin strips the mask paints along each edge, that pair is the two ends of the
edge. O(n²) in the band size, but bands are a few hundred pixels and the result
is cached on disk.

### `_decode(tile) -> Dictionary` / `_decode_all(tiles) -> Array`
Converts one cached record into the runtime form:

- `edges` — six `Vector4`s `(ax, ay, bx, by)` in **UV space** (pixels ÷ region
  size). Absent directions stay `Vector4.ZERO`.
- `out` — six `Vector2` outward screen normals, computed as
  `normalize(edge_midpoint − (0.5, 0.5))`. This is the direction "away from the
  tile centre" for that edge, used both to walk inward to the silhouette and to
  probe outward for a neighbour.
- `present` — a 6-bit mask of which directions actually exist on this tile. A
  slab has no meaningful NW/NE edge; those bits stay clear and every later stage
  skips them.

### `_sibling(sheet_path, suffix) -> String`
Path helper: `<dir>/occlusion/<basename><suffix>`, used for both `_o.png` and
`_o.json`.

---

## 6. `scripts/o_mesh_depth.gd` — the depth rasteriser

`MeshDepth` renders a tile's mesh on the CPU, once per type, into region pixel
space. Each pixel holds a `Vector2(front, back)` — the depth span of the solid
under it — or `EMPTY` = `(INF, −INF)` when uncovered.

Storing the **back** surface as well as the front is what makes a *front*
neighbour's touching face detectable: that face is hidden behind the neighbour's
own body, so comparing against its front depth alone would never match.

### `EMPTY` / `MAX_WALK`
`EMPTY` is the uncovered sentinel. `MAX_WALK` (24 px) is how far a search may
walk inward across the gap between the (deliberately wider) painted mask wedge
and the actual mesh silhouette.

### `origin(size, offset_px) -> Vector2`
The region's pixel-space origin: `size/2 + (−offset_px.x, +offset_px.y)`. The
sign flip on x matches how `_quad` applies `center_offset`, so a tile authored
off-centre rasterises where its art actually sits.

### `rasterize(faces, size, offset_px) -> PackedVector2Array`
Allocates a `size.x * size.y` buffer filled with `EMPTY`, then for every triangle
projects its three vertices through `Iso.facing()` into `(px.x, px.y, depth)` and
scan-converts it with `_scan`. Rasterising once per type keeps every later query
O(1); an earlier version walked triangles per query and froze the editor.

`IsoGrid` passes faces already scaled by `INFLATE` (1.02) — a hair of inflation
closes the sub-pixel hairlines that otherwise appear between two solids that
mathematically just touch.

### `_scan(tile, size, a, b, c)`
Standard barycentric scan conversion at pixel centres. `det` near zero means an
edge-on triangle with no footprint and is skipped. The bounding box is clamped to
the region, and each covered pixel's span is min/maxed with the interpolated
depth — so the buffer accumulates the union of all triangles.

### `at(tile, size, pos) -> Vector2`
Constant-time span lookup, returning `EMPTY` when out of bounds.

### `covered(tile, size, pos) -> bool`
`at(...).x != INF`.

### `first_covered(tile, size, from, dir, steps) -> Variant`
Walks from `from` along `dir` in 1 px steps up to `steps` times, returning the
first covered position or `null`. Used twice: by `IsoGrid._make_type` to walk a
mask pixel *inward* to this tile's own silhouette, and by
`OcclusionContact._span` to probe *outward* for a neighbour's surface.

---

## 7. `scripts/iso_grid.gd` — the grid and the sprite layer

`IsoGrid` is the `GridMap`. It keeps the cell data and the collision, but because
a `GridMap` batches its cells and exposes no per-cell shader inputs, **the
sprites are drawn by a separate layer of one billboard per cell** so each can
carry its own neighbour data.

### Constants
- `LIB_PATH` — where the generated `MeshLibrary` is saved.
- `OCC_SHADER` — the preloaded shader every tile material uses.
- `INFLATE` (1.02) — the occlusion-proxy scale applied to the mesh before
  rasterising, to close raster hairlines.
- `ROT` — the four cardinal yaws (`n/e/s/w`), so one `.obj` serves all four
  facings.
- `RAMP_DIR` — the horizontal ascent direction of a tile authored facing `n`,
  rotated the same way `_faces` rotates the mesh.

### State
- `_types` — `cell item id -> render type dictionary` (see `_make_type`). Built
  lazily and additively.
- `_int_zones` — the interior zones collected for the keyhole system, refreshed
  whenever the sprites are.
- `_occ_hash`, `_wire_hash`, `_zone_hash` — change detectors so the editor
  `_process` re-sprites only when the placed cells or a zone actually moved.
- `_blank_mask` — the cached 1×1 fallback texture.

### `_ready()` / `_setup()`
`_ready` sets `cell_size` from `Iso.cell()`, enables `_process` only in the
editor, then calls `_setup`, which clears `_types`, clears `OcclusionContact`'s
memo, mutes the mesh library, and refreshes the sprites. `_setup` never writes to
disk, so it is safe at runtime — this is what makes the effect appear on scene
load without pressing any button.

### `_mute_library()`
Strips the mesh off every `MeshLibrary` item **in memory** (leaving shapes and
palette previews) so the `GridMap` draws only collision and the sprite layer owns
the visuals; otherwise every tile would be drawn twice. The library is
reassigned (`null` then back) to force the `GridMap` to rebuild its batches. The
file on disk is untouched.

### `rebuild()` — the "Rebuild tiles" button
Rewrites and saves the `MeshLibrary` from `tiles.json`: collision shapes from
`_collision`, palette previews from `_slice`, and meshes only in 3D-debug mode.
Then clears `_types` and refreshes so the render types rebuild lazily. Writes to
disk, so editor-only.

### `rebake()` — the "Rebake occlusion" button
Deletes every `_o.json` cache so the next `OcclusionMaskBaker.ensure` is forced
to bake from scratch, then calls `rebuild()`.

### `_build_types(want)`
Builds a render type for each requested id, **additively** into `_types`. For
each tilesheet it filters the wanted ids belonging to that sheet, assembles the
*full* region list for `ensure` (see §5), then loads three images once per sheet:
the imported sheet, the imported mask (`_load_mask`, for shader sampling), and
the raw mask (`raw_mask`, for pixel-exact analysis). Rasterising a mesh and
walking its probes is the pipeline's one heavy step, so unplaced tiles never pay
for it.

### `_faces(tile) -> PackedVector3Array`
The tile's mesh triangles in cell space: loaded from the `.obj`, rotated by
`ROT[tile.rot]`, then scaled on Y by `Iso.cell().y / Iso.UNIT` so a mesh authored
as a perfect cube fills exactly one (shorter) grid layer. `_make_type`'s
rasteriser, `_collision`, and the 3D debug view all consume this, so rotation is
data rather than a duplicated model.

### `_make_type(tile, sheet, mask, raw, baked) -> Dictionary`
The heart of the build. Step by step:

1. `region` / `size` / `offset` — the tile's rectangle on the sheet and its
   authored pixel offset.
2. `occ_faces = _faces(tile)` — the rotated, Y-scaled triangles.
3. **`near_offset`** — the component-wise `max` over every vertex, i.e. the
   corner of the solid that reaches farthest toward the camera on each axis
   (`+X`, `+Y`, `+Z` all point cameraward in this fixed view). This is keyhole
   input, not outline input; see `player_transparency.md` §5.
4. The same loop scales each vertex by `INFLATE`. Order matters: `near_offset` is
   taken from the *un*-inflated geometry, so the keyhole test stays honest.
5. `depth = MeshDepth.rasterize(...)` — the per-pixel `[front, back]` buffer.
6. `edges`, `out`, `present` — straight from the bake (`_zeros` supplies neutral
   defaults for a sheet with no mask). `edges` is `duplicate()`d because it is
   handed to a `ShaderMaterial`, which would otherwise alias the cache.
7. `region_px` — the mask pixels grouped by direction, from the **raw** mask when
   available.
8. **`probes`** — the key precomputation. For each direction `d` that is
   `present` and has a non-degenerate edge:
   - `e0`, `ev` are the edge's start point and vector in UV.
   - `o = out[d]` is the outward screen normal.
   - Every mask pixel `p` of that direction is walked **inward** (`-o`) up to
     `MAX_WALK` steps until it hits this tile's own rasterised silhouette,
     giving a silhouette point `s`. Pixels that never reach the mesh are dropped.
   - `t` is the pixel's normalised position along the baked edge —
     `clamp(dot(uv − e0, ev) / |ev|², 0, 1)` — *the exact projection the shader
     redoes per fragment*. That symmetry is what lets a `[t0, t1]` range computed
     on the CPU select the right pixels on the GPU.
   - Pixels landing on the same silhouette pixel are collapsed into one entry,
     keeping the min and max `t` they contributed.
   - Each group is flattened into five floats:
     `[t_lo, t_hi, s.x, s.y, front_depth]`.

   The collapse is what keeps the later depth test **O(silhouette length)**
   rather than O(mask pixels), and the `t` range is what makes a fully contacted
   band erase across its whole painted length instead of a dotted subset.
9. `mat` — a `ShaderMaterial` on `OCC_SHADER` with the cropped sprite
   (`albedo_tex`), the cropped mask (`mask_tex`, or `_fallback_mask()`), and the
   UV `edges` array.
10. The returned dictionary is consumed by `OcclusionContact` (`present`, `out`,
    `probes`, `depth`, `region_size`, `origin`, `ramp_chain`) and by
    `_refresh_sprites` (`mesh`, `mat`, `near_offset`).

### `_ramp_chain(tile) -> Variant`
For a `stairs_*` or `slope_*` tile, the grid offset to the cell that continues the
same ramp: one cell along `RAMP_DIR[rot]` and one cell up, since a plain ramp
climbs a full cell height across its own footprint. Corner pieces have a
bidirectional apex and no single ascent direction, so they return `null` and are
excluded. `OcclusionContact` uses this to recognise a designed seamless join.

### `_load_mask` / `_crop` / `_fallback_mask` / `_zeros` / `_quad` / `_region` / `_slice`
- `_load_mask` goes through the resource system (`load(...).get_image()`), so it
  is tolerant of import settings and works in exported builds. `null` when the
  sheet has no mask.
- `_crop` cuts a tile's region into its own `ImageTexture`, so the quad's UV 0–1
  maps straight onto that tile.
- `_fallback_mask` is a cached 1×1 black texture: black decodes to `-1`, so a
  sheet with no mask simply never erases anything.
- `_zeros(v)` returns a six-element array filled with `v`.
- `_quad` builds the pixel-perfect billboard: sized `region.size * PIXEL_SCALE`
  and shifted by `offset_px * PIXEL_SCALE`. No material of its own — the type's
  material is applied as an override.
- `_region` reads `tile.region` as a `Rect2`; `_slice` wraps a region as an
  `AtlasTexture` for the editor palette preview.

### `_refresh_sprites()`
Rebuilds the sprite layer to match the placed cells:

1. Hidden entirely in 3D-debug mode (the `GridMap` draws real meshes then).
2. Frees the billboards of cells that are gone, reuses the rest (each is tagged
   with a `cell` meta), creates new ones for new cells with `owner = null` so
   they are never saved into the scene.
3. Collects the ids missing from `_types` and calls `_build_types` once for all
   of them.
4. Refreshes `_int_zones`, then for each cell assigns the mesh, the material
   override and the position, and calls `_apply_occlusion`.
5. Records `_occ_hash` and `_zone_hash` so the editor `_process` knows nothing
   changed.

### `_apply_occlusion(mi, cell, type)`
The only bridge between contact detection and the shader. Calls
`OcclusionContact.resolve`, then sets:

- `neighbors` — the 6-bit mask of touched edges.
- `range01`, `range23`, `range45` — the six `[t0, t1]` spans, packed two
  directions per `vec4` in index order.
- `tile_near`, `tile_layer`, `tile_zones`, `tile_group`, `tile_shell` — keyhole
  inputs, documented in `player_transparency.md`.

`_refresh_sprites` also calls `OccluderGroups.build(cells)` and caches the result
(`_cell_group`, `_cell_shell`, `_group_count`, `_cell_lo`, `_cell_hi`), which
`_apply_occlusion` and the `group_count` / `cell_group` / `cell_type` / `cell_span`
query API expose. That is keyhole machinery riding on the outline system's refresh
trigger; it has no effect on outline erasing.

### `_sprite_layer()`
Returns (creating once) the owner-less `SpriteLayer` child that holds every
billboard.

### Editor aids
`snap_editor_view`, `_refresh_floor`, `_refresh_wire`, `_debug_mesh`,
`_add_box`, `_wire_material` and `_debug_material` are all
`Engine.is_editor_hint()` conveniences with no effect on the shipped effect.

---

## 8. `scripts/o_contact.gd` — the contact detection

Pure geometry over the grid's cells and the baked tile types: no rendering, no
state beyond a per-pair memo. All `static`.

### 8.1 Constants

| Constant | Value | Meaning |
|----------|------:|---------|
| `SLOP_PX` | 6.0 | How far outward (px) to probe for the neighbour's surface. |
| `DEPTH_TOL` | 1.23 | World-unit slack for "these two surfaces touch". Kept deliberately tight: a neighbour whose surface *recedes* below this tile's — a slope dropping away behind a flat top — must **not** read as a continuing plane, so the outline survives as real silhouette. |
| `GAP` | 0.42 | Contact runs separated by less than this (in `t`) merge into one. Absorbs probe-density gaps where the mask is thin. |
| `MIN_SPAN` | 0.51 | A merged run must be longer than this to count. A mere corner *meeting* leaves a short halo of contacting probes around a shared vertex; anything that short is not surface contact and keeps its ink. |
| `CORNER_EPS` | 0.05 | Tolerance when snapping a run to an edge end (see §8.5). |
| `ID_BITS` | 10 | Bits reserved per tile id in the memo key — supports up to 1024 tiles per config. |

### 8.2 `resolve(grid, cell, types) -> Dictionary`
The entry point, called once per billboard per refresh. Returns
`{neighbors: int, spans: Array[Vector2]}`.

For each of the 26 surrounding cells (`_neighbor_offsets`, a 3×3×3 minus the
centre, built once into a static var) that is occupied by a known type, it
collects per-direction contact runs from `_contact` into `runs[d]`. Then each
direction's runs are combined by `_merge`; a non-null result sets that direction's
span and its bit in `neighbors`.

Several neighbours can each touch part of the same edge — a wall backed by a
floor below and a slab beside it — which is why the runs are pooled per direction
before merging.

### 8.3 `_contact(grid, a_id, b_id, a, b, off) -> Array`
Per-direction contact runs of one *type pair* at one *cell offset*. Because it
depends only on those three things, it is memoised in `_cache`, cleared by
`clear()` on every rebuild. The key is packed into a single int —
`a_id | b_id << ID_BITS | (off + 1) << {20, 22, 24}` — which avoids allocating an
array key for all 26 offsets of every cell.

Two placements are evaluated for vertical offsets:

```gdscript
var worlds = [Vector3(off) * grid.cell_size]
if off.y != 0:
    worlds.append(Vector3(off) * Vector3(cell_size.x, Iso.UNIT, cell_size.z))
```

Tiles are `Iso.UNIT` tall but cells are shorter (§4), so stacked layers overlap
by the difference. A surface continuing across a layer boundary sits exactly that
far off, and evaluating both the true placement and the overlap-corrected one is
what lets it register.

For each placement, the offset is projected into a screen displacement and a
depth `shift` using the same `Iso.facing()` formulas as `MeshDepth`, then `_span`
runs per direction.

**`ramp_bridge`** — a straight stairs/slope tile continuing into an *identical*
tile placed at its own baked `ramp_chain` offset (or its negation) is a designed
seamless join, not a coincidental depth match. Per-step tread/riser jaggedness is
not locally planar, so it would fail `DEPTH_TOL` almost everywhere along the edge
and leave the whole seam outlined. When `ramp_bridge` is set, coverage alone is
enough — the depth check is skipped.

### 8.4 `_span(a, b, d, screen, shift, off, ramp_bridge) -> Array`
The depth-contact test for one edge. Returns zero or more `[lo, hi]` runs.

Directions not `present` on `a` return immediately. Otherwise, for each probe of
edge `d` (recall: `[t_lo, t_hi, s.x, s.y, front_depth]`):

1. `from` = the probe's silhouette point, shifted into `b`'s pixel frame
   (`b.origin − a.origin − screen`) and stepped one pixel outward.
2. `first_covered(b.depth, …, out, SLOP_PX − 1)` searches outward for `b`'s
   surface. `null` → the outward side is **exposed**; the probe is a *keep*.
3. Otherwise the probe **contacts** iff `ramp_bridge`, or `a`'s front depth there
   is within `DEPTH_TOL` of `b`'s **front or back** surface (plus `shift`).
   Testing against a *surface* rather than "inside the solid" is what stops
   wrong-direction neighbours from over-matching. A covered probe at a mismatched
   depth is a real step — a shorter diagonal neighbour whose top sits below this
   probe — and is also a *keep*.

Contacting probes go into `hits` as `[t_lo, t_hi]`. Keeps fold into `keep_lo` /
`keep_hi`, the extreme `t` values at which real silhouette evidence was seen.
`hits` is then sorted by `t` and merged into runs, extending across a `GAP`.

### 8.5 Snapping runs to the edge ends
```gdscript
var lo = 0.0 if idx == 0 and keep_lo >= r.x - CORNER_EPS else r.x
var hi = 1.0 if idx == runs.size() - 1 and keep_hi <= r.y + CORNER_EPS else r.y
```

The first/last probe of an edge sits exactly at a silhouette **vertex** shared
with the adjacent edge, where the outward search can miss the neighbour's
coverage by a single rasterised pixel even when every other probe along the edge
matches perfectly. Two identical cubes in a straight row produce 25 of 26 probes
reading as tight contact and one bottom-corner pixel reading as exposed — enough
to block the bridge to 1.0 and leave a ~1%-of-edge sliver of outline at every
junction.

That is corner-pixel jitter, not real silhouette, so the bridge tolerates a keep
probe within `CORNER_EPS` of the run's own end instead of demanding an exact
match. `CORNER_EPS` is kept far below any genuine exposure region seen in this
pipeline (all comfortably wider than 0.15).

When there are no keeps at all, `keep_lo` is `INF` and `keep_hi` is `−INF`, so
both conditions hold and a fully backed edge snaps to `[0, 1]`.

Runs shorter than `MIN_SPAN` are dropped entirely.

### 8.6 `_merge(runs) -> Variant`
Unions overlapping or near-touching runs (within `GAP`) along one edge and keeps
the **longest**; `null` when even that is shorter than `MIN_SPAN`. A plain
bounding-interval union would be wrong: two point touches at opposite corners
would bridge into a full-edge erase.

Note the asymmetry — the shader gets one span per direction, so when several
neighbours contribute disjoint runs to the same edge, only the longest survives.

### 8.7 Known quirks

**Runs bridge across keep probes.** In `_span`, keep probes only contribute to
`keep_lo`/`keep_hi`; they do **not** break a contact run. An earlier version broke
runs at observed non-contact, which is the theoretically correct behaviour for
cases like a staircase against a smoothly-sloped neighbour, where each tread's
depth coincidentally crosses the slope's depth once per step. Bounding all
contact probes by a single min/max fuses those pinpoint coincidences into one
giant erased span, swallowing the real `DEPTH_TOL`-failing evidence between them.
The breaking version was disabled because it left the right-hand side of certain
partial occlusions visible. The `TODO` in `_span` marks the spot; restoring it
means re-splitting `hits` at keeps and re-checking the partial-occlusion cases.

**The W-edge nudge.** At the end of `_span`:

```gdscript
if d == 5 and off.x == 0 and off.z == 1 and lo > 0.0:
    lo = minf(lo + 0.04, hi)
```

The W edge (5) meeting a SW neighbour during a partial occlusion needs one extra
pixel of outline to read correctly. It is an empirical fix, scoped as narrowly as
possible.

---

## 9. `assets/shaders/occlusion.gdshader` — the outline half

A spatial shader with `render_mode unshaded, cull_disabled, depth_prepass_alpha`.
The `depth_prepass_alpha` mode lets opaque interiors write depth in a pre-pass —
keeping tile-vs-tile and tile-vs-player sorting correct — while semi-transparent
fringes still blend. (That matters mostly for the keyhole; see the companion
doc.)

### Inputs
Per **tile type** (`uniform`): `albedo_tex`, `mask_tex`, `edges[6]`.
Per **cell** (`instance uniform`): `neighbors`, `range01`, `range23`, `range45`.
The remaining five instance parameters (`tile_near`, `tile_layer`, `tile_zones`,
`tile_group`, `tile_shell`) belong to the keyhole half and never affect the
outline block.

### `vertex()`
Billboards the quad to face the camera while keeping the mesh's own scale, so the
sprite stays pixel-perfect regardless of position. It rebuilds `MODELVIEW_MATRIX`
from the inverse view basis plus the model's translation, then re-applies the
model's per-axis scale as a diagonal matrix.

### `decode_dir(c) -> int`
Packs the thresholded RGB into a 3-bit code and maps it to a direction index.
Codes 0 (black) and 7 (white) return `-1`. This is what guarantees the shader
**never erases pixels outside the painted mask** — an undecoded pixel is simply
drawn.

### `range_for(d) -> vec2`
Unpacks direction `d`'s `[t0, t1]` from the three `range*` vec4s: `d < 2` picks
`range01`, `d < 4` picks `range23`, else `range45`; the low bit picks `.xy` vs
`.zw`.

### `fragment()` — the outline block
```glsl
if (neighbors != 0) {
    int d = decode_dir(texture(mask_tex, UV).rgb);
    if (d >= 0 && (neighbors & (1 << d)) != 0) {
        vec2 a = edges[d].xy;
        vec2 ab = edges[d].zw - a;
        float t = clamp(dot(UV - a, ab) / dot(ab, ab), 0.0, 1.0);
        vec2 span = range_for(d);
        if (t >= span.x && t <= span.y)
            ALPHA = 0.0;
    }
}
```

The `neighbors != 0` guard skips the mask sample entirely for cells that touch
nothing. The `t` computation is the same projection `IsoGrid._make_type` used to
build the probes — that correspondence is the contract the whole pipeline rests
on.

The spans carry real sub-ranges: a slab, column or staircase neighbour erases
only the stretch of edge it actually presses against, while a fully backed edge
arrives as `[0, 1]` and disappears whole.

---

## 10. Data flow, end to end

```
paint mask ─▶ OcclusionMaskBaker.ensure ─▶ <sheet>_o.json (cached by md5)
                                              │  decoded: edges (UV), out, present
tile .obj ─▶ _faces ─▶ ×INFLATE ─▶ MeshDepth.rasterize ─▶ [front, back] per px
                                              ▼
tiles.json ─▶ _build_types ─▶ _types[id] = {mesh, mat, edges, out, present,
                                        │    depth, region_px, origin, probes,
                                        │    ramp_chain, near_offset}
placed cells ─▶ _refresh_sprites ─▶ one billboard per cell
                                        │
                     _apply_occlusion ─▶ OcclusionContact.resolve
                                        │   └ _contact (memoised per type pair
                                        │       + offset) ─▶ _span ─▶ runs
                                        │   └ _merge ─▶ one [t0,t1] per direction
                                        ▼  (instance params)
                          occlusion.gdshader ─▶ ALPHA = 0 where t ∈ [t0, t1]
```

---

## 11. Verifying changes

All of these run headless:
`godot --headless --path <project> --script res://tools/<name>.gd`

| Tool | What it checks |
|------|----------------|
| `tools/occ_diag.gd` | Rebuilds the original all-cube terrace, checks rasterised extents, prints every per-offset span table, simulates the shader per pixel for every cell, and composites the scene to PNGs — diffing both against the all-or-nothing baseline. |
| `tools/repro4.gd` | Isolates a tall slab against a short slab at each of the four diagonal offsets and prints per-probe contact/exposed/depth-fail classification for the E/W edges. Regression guard for the depth-mismatched-but-covered-probe bridging bug (§8.7). |
| `tools/ramp_diag.gd`, `tools/stair_slope_diag.gd` | Ramp-chain joins and stairs-against-slope seams. |
| `tools/repro.gd`, `tools/repro2.gd` | Mixed ramps, pyramids and plates, rendered for eyeballing. |
| `tools/tile_fit.gd` | Every tile's mesh↔art fit, plus a composited demo layout. |

`occ_diag` currently reports `RESULT: FAIL (1)` with a 32 px per-pixel diff over
30 cells and a **0 px composite diff**. That is pre-existing drift of the stored
all-or-nothing baseline, not a live regression — the useful signal is whether
those numbers *change*. When refactoring, run every tool before and after and
diff the output text; it should be byte-identical.
