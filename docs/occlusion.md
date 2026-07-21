# Outline occlusion pipeline

Wherever two tiles touch, the dark outline baked into each sprite is made
transparent, so neighbouring tiles read as one continuous surface while the
outer silhouette of the whole shape keeps its outline.

The effect is produced by four cooperating pieces:

1. **Occlusion masks** (`assets/2d/occlusion/<sheet>_o.png`) — hand-painted, one
   per tilesheet. Each marks the six silhouette edges of a tile with a flat
   colour.
2. **`OcclusionMaskBaker`** (`scripts/o_mask_baker.gd`) — turns a mask into a
   small JSON description of where each edge starts and ends, cached on disk.
3. **`OcclusionContact`** (`scripts/o_contact.gd`) — for a placed cell, detects
   which edges its neighbours press against.
4. **`IsoGrid` + `occlusion.gdshader`** (`scripts/iso_grid.gd`) — draws one
   billboard per placed cell and the shader erases the outline along the touched
   edges.

Contact is currently **all-or-nothing**: a touched edge is erased along its
full length. Per-length partial contact (for a slab, a column, or a future
staircase that only covers part of an edge) was attempted twice — projecting
mask edges against each other, then projecting real `.obj`-derived edges
against each other — and both mis-measured a shared edge as two parallel,
non-overlapping lines, because two adjacent cubes each hide a *different*
diagonal corner of their shared face and so contribute genuinely different 3D
edges to their own silhouettes; edge-vs-edge overlap was the wrong test. A
correct version would clip self's edge against the *entire* shape of the
neighbour's silhouette (not one edge of it) — parked for later.

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

### `_sibling(sheet_path, suffix) -> String`
Path helper: `<dir>/occlusion/<basename><suffix>` — used for both the `_o.png`
mask and the `_o.json` cache.

---

## `scripts/iso_grid.gd` — the grid (occlusion parts)

`IsoGrid` is the `GridMap`. It keeps the cell data and collision, but because a
`GridMap` batches its cells and exposes no per-cell shader inputs, **the sprites
are drawn by a separate layer of one billboard per cell** so each can carry its
own neighbour data.

### `_setup()`
Called from `_ready` (runtime-safe: never writes to disk). Reads the config,
builds the render types, mutes the `GridMap`'s own meshes, and refreshes the
sprite layer. This is what makes the effect appear on scene load without pressing
a button.

### `rebuild()`
The editor "Rebuild tiles" button. Rewrites and saves the `MeshLibrary`
(collision shapes + palette previews; placed meshes only in 3D-debug mode), then
does the same type/sprite setup as `_setup`. Writes to disk, so editor-only.

### `rebake()`
The "Rebake occlusion" button. Deletes the cache JSONs so the next bake is
forced from scratch, then calls `rebuild()`.

### `_mute_library()`
Strips the meshes off every `MeshLibrary` item in memory (leaving shapes and
previews) so the `GridMap` draws only collision and the sprite layer owns the
visuals — otherwise the tile would be drawn twice. Does not save, so the file on
disk is untouched.

### `_build_types(data, paths, sheets)`
For each tilesheet, gathers the tiles that use it, calls
`OcclusionMaskBaker.ensure` once for the whole sheet, and builds a render type
per tile via `_make_type`. `_types` is keyed by cell item id.

### `_make_type(tile, sheet, mask, baked) -> Dictionary`
Builds everything one tile type needs:
- `mesh` — its billboard quad (`_quad`).
- `mat` — a `ShaderMaterial` on `occlusion.gdshader`, given the cropped sprite
  (`albedo_tex`), the cropped mask (`mask_tex`, or a 1×1 black fallback), and the
  six baked `edges`.
- `edges`, `out`, `present` — the baked data, kept for the CPU-side neighbour
  resolution.

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
geometry over the grid's cells and baked tile types, with no rendering or state.
All `static`.

### `resolve(grid, cell, types) -> Dictionary`
The entry point. For the given cell it returns
`{neighbors: int, spans: Array[Vector2]}` — which of the six edges are pressed
against, each with the full-length span `FULL_SPAN = (0,1)` when touched.

For every one of the 26 surrounding cells that is occupied:
1. Projects the offset to that neighbour into **screen space** using the fixed
   iso camera basis (`Iso.facing()`), giving its on-screen direction.
2. Tests **every** present edge whose outward normal aligns with that direction
   past `ALIGN` (`dot > 0.6`, ~53°) — not just the single best match. A
   full-size neighbour genuinely spans two hexagon edges at once (the pair
   bounding the shared cube face); picking only the single best-aligned
   direction per neighbour silently drops the other and leaves it unoccluded.
3. The neighbour must also have the matching **opposite** edge present
   (`ntype.present` has bit `(d+3) mod 6`) — a cheap sanity check that the
   neighbour actually has geometry on that side.
4. Any direction that clears both checks is marked touched with the full span.

### `_zero_spans() -> Array`
Six `Vector2.ZERO`s — the default "no contact" spans.

### `_neighbor_offsets() -> Array`
Builds the 26 `Vector3i` offsets around a cell (3×3×3 minus the centre),
memoised in a static var.

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

Every touched direction currently carries the full `[0,1]` span, so this erases
the whole edge. The `t`-projection machinery already supports a sub-range for
partial contact — nothing here needs to change when that lands.

---

## Data flow, end to end

```
paint mask ─▶ OcclusionMaskBaker.ensure ─▶ <sheet>_o.json (cached by md5)
                                              │  decoded: edges (UV), out, present
                                              ▼
config (tiles.json) ─▶ _build_types ─▶ _types[id] = {mesh, mat, edges, out, present}
                                              │
placed cells ─▶ _refresh_sprites ─▶ one billboard per cell
                                              │
                     _apply_occlusion ─▶ OcclusionContact.resolve
                                              │  neighbors bitmask + [t0,t1] spans
                                              ▼  (instance params)
                          occlusion.gdshader ─▶ erase outline where tiles touch
```
