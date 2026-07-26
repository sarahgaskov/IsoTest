# Mesh-driven outline occlusion — implementation plan

> **HISTORICAL.** This is the original design document, kept for the reasoning
> behind the approach and the alternatives that were rejected. Its identifiers
> are plan-stage names (`GAP_PX`, `MIN_SPAN_PX`, `silhouette_edge`, …) and do
> **not** all match the shipped code. For what the code actually does today, read
> [`outline_occlusion.md`](outline_occlusion.md) and
> [`player_transparency.md`](player_transparency.md).

> **STATUS: IMPLEMENTED** (see `docs/outline_occlusion.md` for the living reference).
> Verified by `tools/occ_diag.gd`: span table matches §5's sanity values and
> the per-pixel + composited output of `scenes/level.tscn` is identical to the
> all-or-nothing baseline (0 px diff). Two deviations from this plan:
> - §4's "union (bounding interval is fine — contacts along one edge are
>   contiguous)" proved **wrong**: point-touching neighbours leave short
>   depth-tolerance halos at edge *corners*, and two disjoint halos at opposite
>   ends would bridge into a full-edge erase. `resolve` instead merges
>   overlapping runs (`GAP_PX`) and drops any final run shorter than a corner
>   halo (`MIN_SPAN_PX`).
> - §7's isometric view button is solved: since 4.4 the editor *adopts* an
>   externally moved editor camera into its orbit cursor
>   (`Node3DEditorViewport::_camera_moved_externally`), so `IsoGrid.
>   snap_editor_view` switches the viewport to Orthogonal through its own view
>   menu, then sets the camera transform; placing the camera at
>   `basis.z * (far - near) / 2` makes the adopted pivot exactly the origin.

Handoff document. The codebase previously sat at the **working all-or-nothing
baseline** (`o_contact.gd` erases a full edge when an aligned neighbour has the
opposite edge). This plan describes the mesh-driven partial-contact system that
was prototyped, debugged headless, and verified at the span level — plus every
root cause found on the way, so none of them are rediscovered.

## 1. Correctness principle: contact vs. exposure

> Erase an outline pixel where another tile's surface **touches** it in 3D.
> Keep it where the outward side is **exposed** — empty, or holding a surface
> far enough behind that this tile genuinely occludes it (a real step).

- The criterion is **depth contact vs. depth gap**. Surface orientation is
  irrelevant: a wall base resting on a floor top erases exactly like a coplanar
  merge; a continuing stair/slope erases; an inside room corner erases. There
  is **no** concave-crease exception (explicit design decision).
- Coplanar / continuing / overlapping / touching-at-an-angle are **not separate
  cases** — all are "depth-continuous across the edge". Only a gap keeps ink.
- Division of labour: the **mesh** decides *how far* contact runs along an edge
  (`[t0,t1]`); the **mask** decides *which pixels* are ever eligible (per-edge
  wedge = artist veto + edge identity).
- Target look: outlines only on the outer silhouette of merged shapes and at
  genuine height steps (see the staircase/channel reference render).

## 2. Existing foundation (keep, works)

- `Iso` (`scripts/iso.gd`): fixed iso camera basis `Iso.facing()` (yaw 45,
  pitch 30), `PIXEL_SCALE = √2/2`, `UNIT = 24`, cell size via `Iso.cell()`.
- Mask pipeline: `occlusion/<sheet>_o.png`, 6 coloured wedges
  (NW=red, NE=green, E=cyan, SE=blue, SW=yellow, W=magenta; index order
  NW,NE,E,SE,SW,W; opposite = `(d+3)%6`). `OcclusionMaskBaker` caches
  edges/out-normals/present bits to `_o.json` keyed by md5.
- `IsoGrid` draws one billboard `MeshInstance3D` per used cell (GridMap can't
  carry per-cell shader data); per-cell instance params `neighbors` +
  `range01/23/45` feed `occlusion.gdshader`, which decodes the pixel's wedge,
  projects onto `edges[d]` for `t`, and erases when `t ∈ [t0,t1]`.
  **The shader needs no changes for partial contact** — it already consumes spans.

## 3. Key geometric facts (measured, do not re-derive)

- The 24³ cube's mesh projects to a **48px** silhouette inside the **64px**
  region; the sprite's painted art is ~52px; the mask hexagon fills ~64px.
  All share the region **centre**. Mask wedges intentionally cover the
  ~8px overlap border, so **wedge pixels usually lie OUTSIDE the mesh**.
- Two adjacent cubes each hide a *different* diagonal corner of their shared
  face → their silhouette edges are parallel lines ~24 units apart, **never
  coincident**. Any edge-vs-edge overlap test (mask edges or mesh edges) is
  wrong and produced broken/partial outlines twice. Don't retry it.
- A **front** neighbour's touching face is occluded by its own body — its
  front-depth at the contact point is its *near* surface, not the shared face.
  Front-depth-only contact testing fails asymmetrically (behind-neighbours
  work, front-neighbours don't).

## 4. Architecture to build

### `MeshDepth` (new script, `scripts/o_mesh_depth.gd`)
- `rasterize(mesh, size: Vector2i, offset_px) -> PackedVector2Array` —
  scan-convert every triangle through `Iso.facing()` into the tile's pixel
  space (origin = region centre, `screen = (v·right, −v·up)/PIXEL_SCALE + origin`,
  depth = `v·(−facing.z)`), storing per pixel a **Vector2(front, back)** depth
  span of the solid. Uncovered = `(INF, −INF)`. Storing BACK depth is what makes
  front-neighbour contact detectable.
- `at(tile, size, pos) -> Vector2`, `covered(...) -> bool` — O(1) lookups.
  (Rasterize once per type; earlier per-query triangle walks froze the editor.
  Rasterized, the whole diagnostic runs in ~150 ms.)
- `silhouette_edge(tile, size, wedge_pixels, outward) -> Vector4` — walk each
  wedge pixel inward until `covered`, collect hits, return the farthest-apart
  pair. This parametrises each edge by the **real mesh silhouette**, not the
  wider mask wedge (using mask-wedge endpoints leaves `t` gaps like `[0.07,1]`
  at full contact).

### `OcclusionContact` (rewrite `scripts/o_contact.gd`)
`resolve(grid, cell, types)` → `{neighbors: int, spans: Array[Vector2]}`.

Per occupied neighbour (26 offsets), compute once and **memoize per
`(a_id, b_id, offset)`** (`clear()` on rebuild):
- `world = grid.basis * (off * cell_size)`;
  `screen = (world·facing.x, −world·facing.y)/PIXEL_SCALE`;
  `depth_shift = world·(−facing.z)`.

`_span(a, b, d, screen, depth_shift)` per direction:
1. **Outward gate:** `screen.normalized().dot(a.out[d]) > 0` else null.
   (An edge can only be hidden by a neighbour on its outward side; without this,
   corner pixels bleed contact from neighbours across adjacent edges.)
2. For each mask wedge pixel `p` of direction `d`:
   - walk **inward** (−out, 1px steps, up to `MAX_WALK=24`) to this tile's own
     silhouette point `s`; skip if none. `wa = at(a.depth, s).front`.
   - walk from `s − screen` **outward** up to `SLOP_PX=4` to find the
     neighbour's coverage `sb`; if none → exposed → keep (skip).
   - **contact test:** erase-eligible iff `wa` is within `DEPTH_TOL=2.5` of the
     neighbour's **front OR back** surface (`span.x`/`span.y` + `depth_shift`).
     Near a *surface*, not merely inside the span — "inside the solid" alone
     over-matches wrong-direction neighbours.
   - accumulate `t = clamp(((p/size) − e0)·ev / |ev|², 0, 1)` into lo/hi,
     where `e0/ev` come from the **mesh-silhouette** edge for `d`.
3. Return `Vector2(lo, hi)` or null.

**CRITICAL — union in `resolve`:** several neighbours touch the same edge, each
contributing a partial span (`[0.8,1]`, `[0.1,1]`, `[0,0.1]`…). They must be
**unioned** (bounding interval is fine — contacts along one edge are contiguous):
```gdscript
if (neighbors & (1 << d)) != 0:
    spans[d] = Vector2(min(spans[d].x, s.x), max(spans[d].y, s.y))
else:
    spans[d] = s; neighbors |= 1 << d
```
The prototype's final in-scene bug was `spans[d] = cover[d]` (**last neighbour
wins**) — the headless diagnostic unioned and looked perfect while the real
scene kept most outlines and erased random slivers. This fix was written but
not yet visually verified before the revert.

### `IsoGrid._make_type` additions
Store per type: `region_size: Vector2i`, `depth` (rasterized tile),
`region_px` (mask pixels grouped by direction — compare colours with
`is_equal_approx` against `OcclusionMaskBaker.DIR_COLORS`), and `edges` derived
from `MeshDepth.silhouette_edge` (÷ region width → UV), falling back to the
baker's mask edges when a wedge has no mesh under it. Call
`OcclusionContact.clear()` in `_build_types`. Shader/`_apply_occlusion`
unchanged.

### Tuning knobs (only three, all physical)
| Knob | Value | Meaning |
|---|---|---|
| `MAX_WALK` | 24 px | inward walk across the mask/mesh border to own silhouette |
| `SLOP_PX` | 4 px | leeway for the ~2px gap between mesh silhouette and painted art |
| `DEPTH_TOL` | 2.5 wu | slack for "surfaces touch" |

## 5. Headless verification workflow (essential — do not code blind)

Godot 4.6.1 console binary:
`C:\Users\sevag\Documents\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe`
It opens the project over the WSL UNC path.

- Diagnostic script (`tools/occ_diag.gd`, `extends SceneTree`, work in
  `_initialize()`, end with `quit()`):
  `... --headless --path "\\wsl.localhost\Ubuntu\home\sarahg\Projects\IsoTest" --script res://tools/occ_diag.gd`
- Print per-offset spans for the 8 ground + up/down neighbours; sanity values
  from the verified prototype (same cube, e.g.): `+X → E=[0,~1], SE+NE partial`,
  `−X → NW=[~0.07,1], W=[0,~1]`, `up → NW+NE partial tops`, `down → SE+SW`.
  Wrong-side directions must be null.
- Render a CPU PNG "shader simulation": union all neighbour spans for an
  interior tile, colour each sprite **outline** pixel green (erased) / red
  (kept), upscale ×6, `save_png("res://tools/diag.png")`, then view it.
  Verified end state: interior tile's entire outer silhouette green, no stubs.
- Error check: `--headless --path ... --quit-after 20` and grep for
  `error|SCRIPT|Cannot`.
- Headless has no GPU: the diagnostic proves the *span math*; final shaded
  verification is a user screenshot. When the two disagree, trust the screenshot
  and diff what `resolve` sends vs. what the diagnostic computed (that's how the
  union bug was found).

## 6. Edge cases the design already covers

Slab/column partial contact (spans fall out per-pixel); stacked cubes (up
neighbour touches both top edges); staircase continuing a slope (coplanar =
contact); step down (gap → keep); T-junctions (union); diagonal E/W touches;
tiles not filling the cell. Non-convex tiles: front/back span is a single
interval per pixel — fine for anything cube/slab/stair-like; a tile with a
see-through tunnel would need multi-interval depth, out of scope.

## 7. Open items

- **Isometric view button** (`Editor aids`): setting the editor camera's
  transform directly (`EditorInterface.get_editor_viewport_3d(0).get_camera_3d()`)
  desyncs the editor's internal orbit pivot — after use, orbiting rotates about
  a strange point. Requirement: snap to the iso angle but keep normal orbiting.
  The public API has no orbit-pivot setter; investigate simulating viewport
  input or writing the camera transform in a way the editor re-adopts
  (unverified). De-prioritised vs. occlusion.
- After the union fix lands, re-verify in-editor: floor seams gone, risers and
  outer silhouette intact; then tune `DEPTH_TOL` only if a real scene shows
  over/under-erase.

## 8. Build order

1. `MeshDepth` rasterizer + `covered/at` (+ quick diagnostic print of projected
   extent: cube must be x[8..56] in a 64px region, ~48px wide).
2. `silhouette_edge` per wedge; feed into `_make_type` edges.
3. `OcclusionContact._span` with the four steps above; diagnostic spans until
   they match §5's sanity values.
4. **Union in `resolve`** (the bug!), then in-editor screenshot check.
5. Only then consider polish (vertex stubs, tolerances, staircase tiles).
