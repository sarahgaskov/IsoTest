# Player transparency ("keyhole") pipeline

Any tile that stands between the camera and a tracked entity fades away inside a
soft circular window centred on that entity, so the player is never lost behind a
wall. Roofs and ceilings of the building the player is currently inside are cut
away entirely.

A wall only fades **while it really covers the entity on screen** — that is the
*occlusion gate* of §10–§13. The gate works per **fade group** (one wall, its
corners fused in), ramps smoothly instead of popping, and clears a group's hidden
interior cells ahead of its visible shell so the keyhole shows *through* a wall
rather than *into* it.

This document is the living reference for that system. Its companion,
[`outline_occlusion.md`](outline_occlusion.md), covers the tile-outline erasing
that shares the same shader and the same billboard layer.

---

## 1. The idea in one paragraph

Every frame, `Level` (`scripts/level.gd`) walks the entities in the `keyhole`
group, projects each one to screen space, and writes its screen position plus a
few geometric facts into a tiny **8×2 RGBAF data texture**. That texture and four
tuning floats are published as **global shader parameters**, so every tile
material sees them without any per-material bookkeeping. Each tile billboard
already carries three **instance parameters** describing itself — the cameraward
corner of its solid, its grid layer, and which interior zones it sits in. In the
fragment shader, each tile compares itself against each entity and computes a
`reveal` factor; the tile's alpha is multiplied down by it.

The whole effect is therefore **stateless on the GPU side and O(tiles × entities)
per frame**, with a hard cap of 8 entities.

On top of that, `Level` also walks the view ray out of the entity each frame to
find which walls genuinely cover it, and publishes a second small texture holding
one smoothed 0–1 **gate** per fade group. The shader multiplies its `reveal` by
that gate, so the gate can only ever make a tile *more* opaque than the rules
above would leave it.

---

## 2. Cast of files

| File | Role |
|------|------|
| `scripts/level.gd` (`Level`) | The director. Collects entities, packs the data texture, runs the occlusion query, smooths the gates, publishes the globals. |
| `scripts/o_groups.gd` (`OccluderGroups`) | Bakes placed cells into fade groups and marks each cell's shell flag. |
| `scripts/interior_zones.gd` (`InteriorZones`) | Collects designer-drawn box volumes from a node group; resolves point → interior-zone bitmask. Shared by both marker kinds. |
| `scripts/iso_grid.gd` (`IsoGrid`) | Bakes `tile_near`, `tile_layer`, `tile_zones`, `tile_group` and `tile_shell` onto each billboard, and exposes the query API `Level` needs. |
| `assets/shaders/occlusion.gdshader` | Does the per-pixel reveal and applies the gate. |
| `project.godot` `[shader_globals]` | Declares the nine global uniforms and their editor defaults. |
| `scenes/level.tscn` | Holds the `Level` node, the `GridMap`, and the `Player` (in the `keyhole` group). |
| `scenes/interior_zone.tscn` | A ready-made `Area3D` + `BoxShape3D` in the `interior` group (roof removal). |
| `scenes/occluder_zone.tscn` | The same marker in the `occluder` group — forces everything inside it into one fade group. |
| `tools/keyhole_diag.gd` | Headless verifier: invariants, grouping, synthetic layouts, the occluder override, a brute-force oracle sweep, and the fade ramp. |

---

## 3. Why isometric depth alone is not enough

The naive test — "fade any tile in front of the player" — fails in this
projection. The camera is fixed at yaw 45° / pitch −30°, which means **+X, +Y and
+Z all point toward the viewer**. A tile is genuinely in front of an entity only
when its solid reaches past the entity on *all three* of those axes at once.

Consider a long wall running north–south and a player standing just east of it.
The stretch of wall ahead of the player has a *greater* iso depth than the player
does, so a depth-only test would fade it — but the player is in plain sight on the
wall's east side, and the wall must stay solid. The same happens with a slab the
player is standing *on top of*: it is nearer the camera in Y, but it hides
nothing.

So the test is a three-axis comparison between:

- **`tile_near`** — the cameraward corner of the tile's solid (its max x, y, z),
  computed once per tile type in `IsoGrid._make_type` as `near_offset` and
  translated to world space per cell.
- **the entity's far corner** — `(far_x, feet_y, far_z)`: the corner of the
  entity's body volume turned *away* from the camera on each axis.

A tile occludes when `tile_near > entity_far` on all three axes. The comparison is
softened by `KEY_GATE_SOFT` so a tile that only just clears the entity ghosts
rather than pops.

---

## 4. `scripts/level.gd` — the director

### Exported tuning

| Property | Default | Unit | Meaning |
|----------|--------:|------|---------|
| `keyhole_radius` | 46.0 | screen px | Radius of the fully-revealed inner disc. |
| `keyhole_fade` | 24.0 | screen px | Width of the fade-out gradient past the radius. |
| `keyhole_min_alpha` | 0.0 | 0–1 | Alpha an occluder keeps at the very centre. `0` = fully see-through; `0.3` leaves a faint ghost of the wall. |
| `keyhole_above_reach` | 40.0 | screen px | Extra fade reach granted to tiles above the entity's head, so overhead geometry clears sooner than a wall at the entity's own level. |
| `keyhole_body_radius` | 4.0 | world units | Half-width of the volume the entity counts as filling. Roughly the body radius; **keep it under the collision radius** so a wall the entity is pressed against from the visible side stays solid. |
| `keyhole_body_layers` | 1.8 | grid layers | Body height. The disc centres half this far above the feet. |

The first four have setters that call `_push_tuning()`, so dragging them in the
inspector updates the running game immediately. The last two are read fresh each
frame and need no setter.

The `Occlusion gate` inspector group adds:

| Property | Default | Unit | Meaning |
|----------|--------:|------|---------|
| `keyhole_require_occlusion` | `true` | bool | Master switch for the gate. **Off reproduces the ungated behaviour exactly** (§13). |
| `keyhole_shell_cut` | 1.0 | 0–1 | How completely a group's interior cells clear ahead of its shell. 0 disables the cut. |
| `keyhole_fade_in_rate` | 6.0 | 1/s | Gate rise rate — `1/rate` seconds to open (≈0.17 s). |
| `keyhole_fade_out_rate` | 3.0 | 1/s | Gate fall rate (≈0.33 s). Deliberately slower than the rise. |
| `keyhole_cover_on` | 0.15 | 0–1 | Screen-coverage fraction that latches a group **on**. |
| `keyhole_cover_off` | 0.05 | 0–1 | Fraction it must fall below before the group may latch **off** — the hysteresis band. |
| `keyhole_hold` | 0.15 | s | Minimum dwell after coverage stops, so brushing a corner cannot strobe. |

`keyhole_require_occlusion` and `keyhole_shell_cut` have setters (they are
published as globals); the rest are read per frame by `_advance_gates`.

### State
- `_entities` — the tracked `Node3D`s, from the `keyhole` group.
- `_zones` — the interior zones, collected once (see `refresh()`).
- `_data_image` / `_data_texture` — the 8×2 `FORMAT_RGBAF` image and the
  `ImageTexture` wrapping it.
- `_gate_image` / `_gate_texture` — the `MAX_GROUPS`×1 `FORMAT_RF` image and its
  texture, one smoothed gate per fade group.
- `_gate` — `PackedFloat32Array`, the current smoothed 0–1 gate per group.
- `_on` — `PackedByteArray`, the latched 0/1 target per group.
- `_hold` — `PackedFloat32Array`, remaining hold seconds per group.
- `_live` — the set of group ids still needing per-frame work. Groups that are
  fully closed and not being hit drop out, so the smoothing loop costs
  O(groups actually involved), not O(all groups).
- `_grid` — the sibling `GridMap`, used to resolve an entity's floor layer.
- `_iso` — the same node typed as `IsoGrid`, for the group/type query API.
  `null` when the child is a plain `GridMap`, which disables the gate.

### `MAX_KEYHOLES`
8. This is simultaneously the data texture's width and the shader's loop budget.
Raising it means widening the image; the shader loops to `keyhole_count` and needs
no change, but the per-fragment cost scales linearly.

### `_ready()`
Creates the 8×2 RGBAF image and its `ImageTexture`, publishes the texture as the
`keyhole_data` global **once**, creates and publishes the gate texture the same
way, checks the `(1,1,1)` invariant (§10) and disables the gate with a warning if
it no longer holds, pushes the tuning floats, and calls `refresh()`. Because
`ImageTexture.update()` mutates the same GPU resource in place, neither global has
to be re-set after this.

`IsoGrid` is a **child** of `Level`, and Godot readies children before parents, so
the fade groups are already baked by the time `Level._ready` asks for the count.

### `refresh()`
Re-scans the `keyhole` group into `_entities`, re-collects `_zones`, and resizes
and clears the gate state to the grid's current group count. Call it after
spawning or despawning a tracked entity, after moving an interior zone at runtime,
or after the grid's cells change. Entities register themselves simply by joining
the group — the player, and later party members or NPCs, need no other wiring.

Zones are cached rather than recollected per frame because at runtime they are
static level geometry, and `InteriorZones.collect` allocates a dictionary and an
`affine_inverse` per zone. (In the editor `IsoGrid` watches
`InteriorZones.hash_of` instead and re-sprites when a designer drags a zone;
`Level` is not a `@tool` script, so its `_process` never runs there.)

### `_process(_delta)`
The per-frame packing loop.

```gdscript
var mid := Vector3(0.0, keyhole_body_layers * Iso.cell().y * 0.5, 0.0)
```

`Iso.cell().y` is the world height of one grid layer (19.5959…), so `mid` is half
the body height. Then for each entity, up to `MAX_KEYHOLES`:

- `foot` = `e.global_position`. **The entity's origin sits at its feet**, which is
  the convention `CharacterBody3D` gives us and what the floor-layer lookup wants.
- `screen` = `camera.unproject_position(foot + mid)` — the **body midpoint**
  projected to screen. This is what centres the disc on the middle of the player
  rather than on the ground under them. `unproject_position` and the shader's
  `FRAGCOORD` share a top-left origin, so the projected point maps straight
  through with no Y flip.
- `far` = `foot - (body_radius, 0, body_radius)` — the west/north/feet corner,
  the corner turned away from the camera on each axis. Note the Y component stays
  at the feet: the "is the tile above the entity's feet" half of the test is what
  spares a slab the entity is standing on.
- Row 0 of column `count` is written as
  `Color(screen.x, screen.y, floor_layer, zone_mask)`.
- Row 1 is written as `Color(far.x, far.y, far.z, 0)`.

- When the gate is live, `_gather_occluders` (§11) runs for this entity and
  accumulates per-group coverage into a shared `hits` dictionary.

After the loop, the texture is uploaded only when at least one entity was packed
(with `keyhole_count == 0` the shader ignores the texture entirely),
`keyhole_count` is published, and `_advance_gates` (§13) folds `hits` into the
smoothed gate state.

`gated` is the guard for all of this: it requires `keyhole_require_occlusion`, an
`IsoGrid` child, and a non-empty gate array. Any of those failing leaves the gate
texture untouched — and with `keyhole_gate_enable` published as 0 the shader
ignores it anyway.

Invalid instances are skipped but not pruned; `refresh()` is the pruning step.

### `_floor_layer(foot) -> float`
`_grid.local_to_map(_grid.to_local(foot - (0, 0.5, 0))).y`. Sampling half a unit
*below* the feet lands inside the floor cell whether that cell is a full block or
a shallow slab. Returns 0 when there is no `GridMap`.

### `_push_tuning()`
Publishes `keyhole_radius`, `keyhole_fade`, `keyhole_min_alpha`,
`keyhole_above_reach`, `keyhole_shell_cut` and `keyhole_gate_enable` (1.0 or 0.0
from `keyhole_require_occlusion`) as global shader parameters.

---

## 5. The `keyhole_data` texture layout

An 8×2 `Image.FORMAT_RGBAF` (32-bit float per channel — required, because the
values are world coordinates and screen pixels, not colours). Column `i` is entity
`i`; the shader reads it with `texelFetch(keyhole_data, ivec2(i, row), 0)`.

| Row | R | G | B | A |
|----:|---|---|---|---|
| 0 | `screen_x` (px) | `screen_y` (px) | `floor_layer` (grid Y of the cell under the feet) | `zone_mask` (bitmask, exact as a float) |
| 1 | `far_x` (world) | `feet_y` (world) | `far_z` (world) | unused |

The project declares the global in `project.godot`:

```ini
keyhole_data={ "filter": "nearest", "repeat": "disable",
               "type": "sampler2D", "value": "res://icon.svg" }
```

`filter: nearest` matters — any filtering would blend neighbouring entities'
records together. The `icon.svg` value is only a placeholder for the editor;
`Level._ready` replaces it at runtime.

---

## 6. Per-tile instance parameters

Set by `IsoGrid._apply_occlusion` on every billboard:

| Parameter | Source | Meaning |
|-----------|--------|---------|
| `tile_near` (`vec3`) | `to_global(map_to_local(cell)) + type.near_offset` | World position of the solid's cameraward corner. `near_offset` is the component-wise max over the tile mesh's vertices, computed in `_make_type` **before** the `INFLATE` scaling so the test is not biased outward. |
| `tile_layer` (`float`) | `float(cell.y)` | The cell's grid height, compared against the entity's `floor_layer`. |
| `tile_zones` (`int`) | `InteriorZones.mask_at(_int_zones, center)` | Bitmask of the interior zones this cell sits inside. |
| `tile_group` (`int`) | `_cell_group.get(cell, -1)` | Index of this cell's fade group, or `-1` for ungrouped (which reads as gate 1.0 — the ungated behaviour). |
| `tile_shell` (`float`) | `1.0` unless `_cell_shell[cell]` is false | 1.0 when the cell is its group's camera-facing shell, 0.0 when the group hides it behind itself. |

Because these are instance parameters rather than uniforms, all cells of the same
tile type still share one `ShaderMaterial` — which is the reason the sprite layer
exists at all (a `GridMap` batches cells and offers no per-cell inputs).

`tile_shell` is a `float` rather than a `bool` because Godot's instance-uniform
set does not include booleans.

---

## 7. `scripts/interior_zones.gd` — designer-drawn boxes

A designer marks the inside of a building by dropping `scenes/interior_zone.tscn`
(an `Area3D` with a `BoxShape3D`, in the `interior` group) and dragging its box
over the building. Any node in the `interior` group carrying a `BoxShape3D` works;
`_box` accepts the shape on the node itself or on a direct child.

Despite the class name this file is the generic box-volume collector for **both**
marker groups: `boxes(tree, group, limit)` is the primitive, `collect(tree)` is
the `interior` specialisation used for roof removal, and
`OccluderGroups.collect_zones` calls `boxes` with `occluder` for the fade-group
override (§12).

Zones are collected in **scene-tree order** and each gets a bit by its index. That
stable order is the whole point: the tile's zone membership (baked by `IsoGrid` at
sprite-refresh time) and the entity's zone membership (computed per frame by
`Level`) must agree on which bit means which building. Otherwise the shader would
cut the wrong roof.

### `MAX_ZONES`
24. The mask travels to the GPU inside an RGBAF texel as a float; 24 bits is the
largest integer range a 32-bit float represents exactly, so the mask survives the
round trip without rounding.

### `collect(tree) -> Array`
`[{inv: Transform3D, ext: Vector3}]`, one per zone in bit order. `inv` is the
zone's inverse global transform and `ext` its half-extents, so containment is a
cheap local-space box test.

### `mask_at(zones, p) -> int`
Transforms the point into each zone's local space and ORs in `1 << i` for every
box that contains it.

### `boxes(tree, group, limit) -> Array`
Every `BoxShape3D` volume of a node group, in scene-tree order, as
`{inv, ext}` records. `limit` differs by caller: `MAX_ZONES` (24) for interior
zones because of the bitmask, `OccluderGroups.MAX_ZONES` (256) for occluder boxes
because they carry no bitmask.

### `contains(zone, p) -> bool`
Local-space box test, shared by `mask_at` and the occluder override.

### `hash_of(tree) -> int`
Hash of every box's transform and size across **both** the `interior` and
`occluder` groups. `IsoGrid._process` compares it against `_zone_hash` each editor
frame, so dragging or resizing either kind of box re-sprites the grid and re-bakes
`tile_zones` and the fade grouping.

---

## 8. `assets/shaders/occlusion.gdshader` — the keyhole half

### Globals
```glsl
global uniform int keyhole_count;
global uniform sampler2D keyhole_data;
global uniform float keyhole_radius;
global uniform float keyhole_fade;
global uniform float keyhole_min_alpha;
global uniform float keyhole_above_reach;
global uniform sampler2D keyhole_groups;
global uniform float keyhole_gate_enable;
global uniform float keyhole_shell_cut;
```

### Constants
- **`KEY_GATE_SOFT`** (12.0 world units) — how far a tile must reach past the
  entity's far corner on an axis before it counts as a *full* occluder along it.
  Below that the reveal ramps in. It is half a cell, so a tile that only just
  clears the entity — a low slab it walks past, the wall cell level with it —
  ghosts instead of popping open.
- **`KEY_ABOVE_LAYERS`** (2.0) — how many grid layers above the entity's floor a
  tile must sit before it reads as *overhead* (roof, ceiling, bridge deck) rather
  than a wall at the entity's own level.
- **`KEY_SHELL_SHARPEN`** (0.25) — how much of the shell's reveal is enough to
  fully clear the group's interior cells. Smaller values make the interior vanish
  sooner relative to the shell's soft gradient.

Note that the loop's local `axis` (the three-axis test) and the post-loop `gate`
(the occlusion gate) are different things; `axis` was named `gate` in earlier
revisions of this shader.

### The fragment loop

```glsl
float reveal = 0.0;
bool cut = false;
for (int i = 0; i < keyhole_count; i++) {
    vec4 e0 = texelFetch(keyhole_data, ivec2(i, 0), 0);
    vec4 e1 = texelFetch(keyhole_data, ivec2(i, 1), 0);
    bool above = tile_layer >= e0.z + KEY_ABOVE_LAYERS;

    if (above && (tile_zones & int(e0.w)) != 0) { cut = true; break; }

    vec3 clear = smoothstep(vec3(0.0), vec3(KEY_GATE_SOFT), tile_near - e1.xyz);
    float axis = min(min(clear.x, clear.y), clear.z);
    if (axis <= 0.0) continue;

    vec2 center = floor(e0.xy) + 0.5;
    float dist = length(FRAGCOORD.xy - center);
    float reach = keyhole_fade + (above ? keyhole_above_reach : 0.0);
    reveal = max(reveal, axis * (1.0 - smoothstep(keyhole_radius, keyhole_radius + reach, dist)));
}

float gate = 1.0;
if (tile_group >= 0)
    gate = texelFetch(keyhole_groups, ivec2(tile_group, 0), 0).r;
gate = mix(1.0, gate, keyhole_gate_enable);

float shell = mix(1.0, tile_shell, keyhole_shell_cut);
float shell_alpha = 1.0 - reveal * (1.0 - keyhole_min_alpha);
float inner_alpha = 1.0 - smoothstep(0.0, KEY_SHELL_SHARPEN, reveal);
ALPHA = cut ? 0.0 : ALPHA * mix(1.0, mix(inner_alpha, shell_alpha, shell), gate);
```

Step by step:

1. **`above`** — the tile is overhead relative to *this* entity's floor.
2. **The zone cut.** An overhead tile that shares an interior zone with the entity
   disappears entirely, regardless of distance: you are inside the building, so
   its roof comes off. `break` is safe because `cut` forces `ALPHA = 0` no matter
   what the remaining entities would contribute. Exterior tiles (zone mask 0 — a
   bridge, an unentered building) never take this path and only ever get the
   circular keyhole.
3. **The three-axis gate.** `tile_near - e1.xyz` is how far the tile reaches past
   the entity's far corner on each cameraward axis. `smoothstep` over
   `[0, KEY_GATE_SOFT]` turns each into a 0–1 factor and `min` takes the weakest.
   A miss on any single axis (the entity is east of the wall, south of it, or
   standing on top of it) yields 0 and leaves the tile fully solid.
4. **The disc.** The centre is snapped to the pixel grid with `floor(...) + 0.5`
   so the gradient locks to whole pixels and steps in whole pixels as the entity
   moves — without this, the low-resolution viewport shows the fringe shimmering.
   `dist` is the fragment's distance from that centre in screen pixels.
5. **`reach`.** Overhead tiles get `keyhole_above_reach` extra gradient width, so
   they start fading from farther out and clear sooner than a wall at the
   entity's own level.
6. **`reveal`** accumulates as a `max` over entities: the most-revealing entity
   wins, and two players standing apart each open their own window.
7. **The occlusion gate** is fetched for this cell's group and blended out
   entirely by `keyhole_gate_enable`. §13 covers why this can only ever make the
   tile more opaque.
8. **The shell split.** `shell_alpha` is the original soft gradient, kept for the
   group's camera-facing shell. `inner_alpha` is the sharpened version used by the
   cells the group hides behind itself — they clear once the shell is only
   `KEY_SHELL_SHARPEN` revealed, so the hole shows *through* the wall rather than
   into its interior faces. `keyhole_shell_cut` blends between the two treatments.
9. The final alpha keeps `keyhole_min_alpha` of the sprite at the very centre —
   for shell cells. Interior cells go fully transparent; a ghost of a hidden
   interior face is exactly what the shell split exists to remove.

**The zone cut deliberately bypasses the gate.** `cut` is applied before and
independently of `gate`, because "you are inside this building, take its roof off"
is not a claim about occluding the entity — a roof directly overhead occludes
nothing and would never light the gate. Routing it through the gate would silently
kill roof removal.

### Why `depth_prepass_alpha`
The shader declares `render_mode unshaded, cull_disabled, depth_prepass_alpha`.
Opaque interiors write depth in a pre-pass, so tile-vs-tile and tile-vs-player
sorting stays correct, while the semi-transparent keyhole fringe blends smoothly
over whatever is behind it. This is what lets the occluder fade out with distance
instead of hard-cutting or dithering.

---

## 9. Entity geometry

The player capsule in `scenes/level.tscn` is **1.8 grid layers tall**
(`height = 35.272652` = `1.8 × Iso.cell().y`) with a radius of 5.0, its
`CollisionShape3D` and `MeshInstance3D` both offset to `y = 17.636326` so the
`CharacterBody3D` origin lands at the feet.

Two numbers must be kept in sync with that capsule:

- **`Level.keyhole_body_layers`** (1.8) — drives where the disc centres. If the
  capsule gets taller or shorter, change this too or the window will drift off
  the body.
- **`Level.keyhole_body_radius`** (4.0) — must stay *under* the capsule radius
  (5.0). If it matched or exceeded it, a wall the player is pressed against from
  the visible side would satisfy the three-axis gate and fade when it should not.

`Player.max_step_px` and `floor_max_angle` are movement concerns and do not
affect this system.

---

## 10. The `(1,1,1)` view diagonal

Everything in §11–§13 rests on one geometric fact.

The direction from a point *toward* the camera is `Iso.facing().z`, which for yaw
45° / pitch 30° is `(0.6123724…, 0.5, 0.6123724…)` in world units. Divide that by
`Iso.cell()` = `(24, 19.5959…, 24)` and every component comes out to
`0.0255155181539914…` — equal to within 1e-16.

**So in grid coordinates the camera looks exactly along `+(1,1,1)`.** Two
consequences do all the work:

1. The cell directly in front of `c` from the camera's point of view is
   `c + (1,1,1)`. Enumerating potential occluders is not a search — it is a
   diagonal walk in integer grid space.
2. A cell's screen position depends only on `(x−y, z−y)`. Cells sharing that key
   form a **depth column** and project to *the same screen point*, so a column's
   screen position is computed once and reused for every cell in it.
   (Equivalently: screen x ∝ `x−z`, screen y ∝ `x+z−2y`; both are invariant
   under `+(1,1,1)`.)

### The invariant this depends on

Writing `P` for `Iso.PITCH`:

```
world dir  = (cos P · sin 45°, sin P, cos P · cos 45°)
cell       = (UNIT, LAYER_PX · (√2/2) / cos P, UNIT)

dir.x / cell.x == dir.y / cell.y   ⟺   sin(P) == LAYER_PX / (2 · UNIT)
```

With `PITCH = 30°` and `LAYER_PX == UNIT == 24`, that is `0.5 == 0.5`. **Change
either constant and the diagonal stops being `(1,1,1)`**, and the walk needs to
become a general voxel DDA.

`OccluderGroups.diagonal_is_exact()` checks this at runtime. `Level._ready` calls
it and, if it fails, pushes a warning and disables the gate rather than producing
silently wrong occlusion. `tools/keyhole_diag.gd` asserts both the ratio and that
a diagonal step really moves a cell zero pixels on screen.

### Why not physics raycasts

Casting rays from the player toward the camera is the obvious approach, and it is
the one the grid structure lets us beat:

- `GridMap` collision is a concave trimesh per octant. `intersect_ray` returns the
  `GridMap`, not the cell — you would have to map the hit position back to a cell.
- A ray reports only its *first* hit, so enumerating a whole column means repeated
  queries with growing exclusion lists.
- Rays sample the **collision** mesh, but the thing that must fade is the
  **sprite**. `MeshDepth`'s raster is the sprite's own ground truth.
- Physics runs on the physics tick, not the render frame, so a ray-driven gate
  would step rather than track.

Raycasts remain the right tool for occluders that are *not* grid cells (props,
doors as separate meshes); those would need to register their own group.

---

## 11. The occlusion query — `Level._gather_occluders`

Runs once per tracked entity per frame, and answers "which fade groups actually
cover this entity on screen, and by how much?".

### Step 1 — sample the body's screen silhouette

Nine points: three heights (`SAMPLE_HEIGHTS` = 15%, 50%, 85% of body height) ×
three lateral offsets (centre, `+side`, `−side`). The lateral offset is
`keyhole_body_radius / √2` applied along world `(+x, −z)`, which projects to
**pure screen-horizontal** — `(r/√2, 0, −r/√2)·facing.x / PIXEL_SCALE` is `r`,
with zero screen-y component. Each point is unprojected once.

Nine samples means the coverage fraction is quantised to ninths (0.11, 0.22, …),
which is plenty given it feeds a hysteresis threshold.

### Step 2 — pick the screen columns to search

**This is the part that is easy to get wrong.** The obvious choice — search only
the columns the body's own cells fall in — is *not* enough, and produced a real
bug: a wall one step `+Z` from the player (so the player stands **NE of it** on
screen) never registered, because `player_cell + (0,0,1)` is not of the form
`player_cell + n·(1,1,1)`. The wall visibly covered the player and stayed solid.

The body is ~14 px wide but ~43 px tall on screen (1.8 layers × 24 px), and each
tile sprite is a 64×64 quad reaching ±32 px around its cell centre. So the body's
silhouette overlaps a whole **band** of neighbouring columns.

Column centres sit on a lattice: `+X` moves the screen position by `(24, 12)`,
`+Z` by `(-24, 12)`, `+Y` by `(0, -24)`. In key space a column offset `(dx, dz)`
is reached from the body's cell by `base + (dx, 0, dz)`, and it lands at screen
offset `(24(dx − dz), 12(dx + dz))`. So:

- `dx − dz` is the **horizontal** offset in columns — the body is narrow, so this
  stays tight: `COLUMN_SIDESTEP = 1`.
- `dx + dz` is the **vertical** offset — the body is tall, so this must reach:
  `COLUMN_SPREAD = 3`.

As a rule of thumb the spread needs to be about the body's height in layers plus
two for the sprite's own reach. It is not derived at runtime; it is a constant
**verified by the oracle test** (§16), which sweeps 80 player positions and
compares the walk against a brute-force scan of every placed cell. Measured on
the shipped level: spread 1 misses 5 positions, spread 2 misses none, spread 3
(the shipped value) leaves a full step of margin, and spread 4 finds nothing more.
`COLUMN_SIDESTEP = 2` also finds nothing more than 1.

**If `keyhole_body_layers` grows, re-run the oracle test** — a taller body spans
more columns and `COLUMN_SPREAD` will need to grow with it.

### Step 3 — walk the diagonal

Each column starts at `base + (dx, 0, dz) − COLUMN_SPREAD·(1,1,1)`, i.e.
deliberately *behind* the body, so nothing between it and the camera is skipped
however far the column's key offset displaced the start depth. The walk steps by
`(1,1,1)` until the cell leaves the grid's inclusive bounds
(`IsoGrid.cell_span()`) or `WALK_LIMIT` (64) steps elapse. All three coordinates
increase monotonically, so one `>` test per axis suffices.

Cells behind the body are discarded by a depth test rather than by the start
position:

```gdscript
if type != null and (center + type.near_offset).dot(view) > floor_depth:
```

`center + type.near_offset` is the tile's cameraward corner (the same quantity
the shader's three-axis rule uses) and `floor_depth` is the body's *minimum*
toward-camera depth, at the feet. The cell centre is advanced incrementally by a
constant world step rather than re-derived per cell.

For each surviving cell, `_coverage` scores it and the best score per group is
kept in `hits`.

Cost: 19 columns × ~25 steps ≈ 475 candidate cells per entity per frame, but the
group lookup rejects empty cells immediately, so only the handful that are
occupied reach the coverage test. One `unproject_position` per column, nine per
entity.

### Step 4 — `_coverage`, the exact test

Cell occupancy is *not* enough — a `slope_n` or `slab_1` in the column may cover
none of the body. The exact answer is already sitting in `_types[id].depth`, the
per-pixel `[front, back]` raster `MeshDepth` builds for the outline system:

```gdscript
p_region = type.origin + (sample_screen − column_screen)
covered  = MeshDepth.covered(type.depth, type.region_size, p_region)
```

This works because **region pixels and screen pixels are 1:1** in this projection:
`_quad` sizes each billboard to `region.size × PIXEL_SCALE` world units and
`Iso.camera_size` sets the orthographic height to `viewport_height × PIXEL_SCALE`,
so the world→screen scale is exactly `1 / PIXEL_SCALE` and the two cancel. Both
spaces also put `+y` down, so the offset maps through with no flip.

`type.origin` is `MeshDepth.origin(size, offset_px)` — where the cell centre lands
in region pixels — and `column_screen` is where that centre lands on screen. The
difference is therefore a pure screen-space delta.

`_body_samples` is factored out of the walk so `tools/keyhole_diag.gd` can build
the identical sample set for its brute-force oracle — the two must agree on
*what* is being tested for the comparison to isolate the column enumeration.

---

## 12. Grouping and the shell — `scripts/o_groups.gd`

`OccluderGroups.build(cells)` runs inside `IsoGrid._refresh_sprites`, so it costs
nothing per frame — it re-runs only when the placed cells change (already gated by
`_occ_hash` / `_zone_hash`).

### What a group is

A group is **one wall, with the walls it turns into fused in**. Union-find over
three relations:

**1. Plane runs.** A cell "shows a +X face" when `c + (1,0,0)` is empty, and
similarly for +Z — those are the two camera-facing vertical faces. Two cells that
both show the same face and are face-adjacent within that plane are unioned:

```gdscript
if not filled.has(c + FX):
    for n in [UP, FZ]:
        if filled.has(c + n) and not filled.has(c + n + FX):
            _union(parent, c, c + n)
```

**2. Corner fusion.** This is the subtle one. When two walls meet at an L, they
*bury each other's faces* — the corner cell has a wall on its +X side and a wall
on its +Z side, so it shows neither, and no single cell belongs to both planes.
Plane runs alone therefore leave an L as two groups, and walking behind one wall
fades only half the corner. The fix:

```gdscript
if filled.has(c + FX): continue          # no +X face here
var turn := c + Vector3i(1, 0, -1)
if filled.has(turn) and not filled.has(turn + FZ):
    _union(parent, c, turn)
```

`(1,0,-1)` is the **only** offset at which an +X face and a +Z face can both stay
exposed. `(0,0,0)` is already handled (a lone thin wall's cell shows both faces
and is one union-find node); `(1,0,0)` and `(0,0,-1)` are geometrically impossible
— each requires a cell to be simultaneously filled and empty.

**3. Backing adoption.** A cell that shows no camera-facing face of its own (the
buried column at an inner corner, wall fill) joins whichever neighbour does show
one — **one hop only**, checked in the order `+X, +Z, +Y, −X, −Z, −Y`. The single
hop is deliberate: it pulls a corner column into its walls without letting a
floor's interior chain across the entire map.

**4. Designer override.** Every cell whose centre falls inside the same
`occluder` box is unioned. Applied last, after the automatic rules.

### The `occluder` zone override

Drop `scenes/occluder_zone.tscn` into the level and drag its box over a
structure: everything inside fades as a single unit. It is the same machinery as
`interior_zone.tscn` — an `Area3D` with a `BoxShape3D`, no physics, found by node
group — and `InteriorZones.boxes(tree, group, limit)` is shared between them.
`OccluderGroups.collect_zones` is the thin wrapper that asks for the `occluder`
group, capped at `MAX_ZONES` (256).

`InteriorZones.hash_of` hashes **both** groups, so dragging an occluder box in the
editor re-sprites the grid and re-bakes the grouping, exactly as an interior zone
does.

> **The override is union-only.** A box can force separate walls to fade
> together; it *cannot* split apart a group the automatic rules already fused.
> Union-find merges, it never divides. If you need two walls that the corner rule
> fused to fade independently, the rules themselves have to change — a box will
> not do it.

Boxes may overlap: a cell inside two boxes fuses both, since each box unions all
its members into a shared anchor and the anchors then meet through that cell.

The whole level wrapped in one box collapses to a single group — that is the
degenerate case `tools/keyhole_diag.gd` asserts (29 groups → 1, and back to 29
when the box is removed).

### What "shell" means

Along the view ray a group can be **more than one cell deep**. Picture an alcove:
a flat wall with a short return that steps one cell toward the camera. Both belong
to the same group, and the return sits at `wall_cell + (1,1,1)` — directly in
front of the wall cell, hiding it.

> **A cell is *shell* when nothing of its own group stands in front of it**, i.e.
> `group[c + (1,1,1)] != group[c]`. The shell is the group's outer skin as the
> camera sees it. Cells behind the skin are the group's **interior**.

```gdscript
shell[c] = g < 0 or group.get(c + VIEW_STEP, -1) != g
```

Why it matters: each tile draws a *whole cube*, and the outline system has already
erased its outlines where it met its neighbours. Punch a keyhole through the shell
and the interior cell behind it renders its full cube art with those outlines
gone — which reads as *the inside of the wall*, a cross-section. Marking interior
cells lets the shader clear them along with (in fact slightly ahead of) the shell,
so the hole shows through the group to whatever genuinely lies beyond it.

A flat wall plane has **no** interior cells — it is exactly one cell deep along
any ray. Interior cells appear at returns, nooks, doorway reveals and fused
corners. The shipped `level.tscn` has 5, all at ground level.

Note `g < 0` forces shell: an ungrouped cell must fall back to the ungated
behaviour, and treating it as interior would make it vanish aggressively for no
reason.

### `MAX_GROUPS`

4096, the gate texture's width. Every placed cell gets a group, singletons
included (an isolated pillar still deserves its own gate), so a very large level
of mostly-singleton floor tiles is the pressure case. On overflow the remaining
cells get `-1`, which reads as gate 1.0 — the ungated behaviour. The failure mode
is graceful and silent by design.

For reference, the current `level.tscn`: 90 cells → 29 groups, largest 37, none
ungrouped.

### Known trade-off

Corner fusion is offset-based, so two structures that merely *meet* at that offset
fuse — a wall standing diagonally adjacent to a raised floor's edge run, for
instance. The gate limits the damage (the fused group still only fades when it
genuinely occludes), and the group-size histogram printed by
`tools/keyhole_diag.gd` makes an over-fused group obvious. Because the `occluder`
override is union-only, it cannot undo such a fusion — separating them means
changing the rules.

---

## 13. Gate smoothing — `Level._advance_gates`

Per group, per frame:

1. **Latch with hysteresis.** Coverage ≥ `keyhole_cover_on` (0.15) sets `_on = 1`
   and recharges `_hold`. Coverage ≤ `keyhole_cover_off` (0.05) drains `_hold` and
   then clears `_on`. Between the two thresholds nothing changes, so a group
   hovering near the boundary cannot chatter.
2. **Dwell.** `keyhole_hold` (0.15 s) keeps a group latched on after coverage
   stops, so brushing past a corner cannot strobe it.
3. **Rate-limited approach.** `move_toward(_gate[i], target, rate * delta)` with
   `keyhole_fade_in_rate` (6/s ≈ 0.17 s) rising and `keyhole_fade_out_rate` (3/s ≈
   0.33 s) falling. Linear rather than exponential: predictable, and it actually
   reaches its target instead of trailing an infinite tail. Scaling by `delta`
   keeps it frame-rate independent.
4. **Upload only when something moved.** `dirty` tracks whether any pixel changed;
   groups that reach 0 with `_on == 0` drop out of `_live`.

Thresholding *before* smoothing is what makes walls commit. Feeding the raw
coverage fraction straight to the gate would leave a wall sitting at 40 %
transparency indefinitely whenever the player stands half-behind it.

### Why the gate is purely subtractive

The shader applies it as:

```glsl
ALPHA *= mix(1.0, faded_alpha, gate)     //  = 1 + gate·(faded_alpha − 1)
```

`faded_alpha ≤ 1` always, so `(faded_alpha − 1) ≤ 0`, so for any `gate ∈ [0,1]`
the result is **≥ `faded_alpha`**. The gate can only ever make a tile *more*
opaque than the ungated rules would leave it; it can never reveal something the
old rules kept solid. `gate = 1` reproduces the old behaviour exactly.

`keyhole_require_occlusion = false` publishes `keyhole_gate_enable = 0`, which
forces `gate = 1` for every tile — a clean A/B switch.

`tools/keyhole_diag.gd` guards the precondition by asserting every gate value
stays inside `[0,1]`; the algebra above does the rest.

The **shell cut is the one part that adds transparency**, and only for interior
cells — cells the group hides behind itself, which by definition are not what you
were looking at. Set `keyhole_shell_cut = 0` to disable it and get behaviour
identical to before this feature.

---

## 14. Data flow, end to end

```
"keyhole" group ─▶ Level.refresh ─▶ _entities
"interior" group ─▶ InteriorZones.collect ─▶ _zones
placed cells ─┐
"occluder" group ─▶ OccluderGroups.collect_zones ─┐
              └────▶ OccluderGroups.build ◀───────┘
                                     │  ─▶ group / shell / count / lo / hi
                                     │        (on sprite refresh only)
Level._process (per frame):          │
  foot = e.global_position           │
  screen = unproject(foot + mid)  ◀──┘ mid = keyhole_body_layers * cell.y / 2
  far    = foot - (r, 0, r)
  layer  = _floor_layer(foot)
  zones  = InteriorZones.mask_at(_zones, foot)
        └─▶ _data_image ─▶ _data_texture.update() ─▶ global keyhole_data
        └─▶ global keyhole_count

  _gather_occluders:
    9 body samples ─▶ screen px
    per screen column in the COLUMN_SPREAD band: walk c + n*(1,1,1)
        └─▶ depth test vs type.near_offset (drop cells behind the body)
        └─▶ MeshDepth.covered(type.depth, ...) ─▶ coverage per group ─▶ hits

  _advance_gates(hits, delta):
    hysteresis latch ─▶ _on      (cover_on / cover_off / hold)
    move_toward      ─▶ _gate    (fade_in_rate / fade_out_rate)
        └─▶ _gate_image ─▶ _gate_texture.update() ─▶ global keyhole_groups

  (setters) ─▶ globals keyhole_radius / _fade / _min_alpha / _above_reach
                    / keyhole_gate_enable / keyhole_shell_cut

IsoGrid._apply_occlusion (per cell, on refresh):
  tile_near  = cell_center + type.near_offset
  tile_layer = cell.y
  tile_zones = InteriorZones.mask_at(_int_zones, cell_center)
  tile_group = _cell_group[cell]
  tile_shell = _cell_shell[cell]
        └─▶ instance shader parameters

occlusion.gdshader fragment():
  overhead + shared zone      ─▶ ALPHA = 0            (bypasses the gate)
  else three-axis axis × disc ─▶ reveal
       × group gate           ─▶ only while really occluding
       shell vs interior      ─▶ soft gradient vs sharpened cut
                              ─▶ ALPHA *= mix(1, mix(inner, shell, shell_flag), gate)
```

---

## 15. Tuning notes

- **The window feels too small / too large** — `keyhole_radius`. The gradient is
  separate, so raising the radius keeps the same softness.
- **The edge is too hard** — `keyhole_fade`.
- **Walls vanish completely and lose readability** — raise `keyhole_min_alpha` to
  0.15–0.3 for a ghosted wall.
- **Roofs linger too long when walking under a bridge** — `keyhole_above_reach`.
  Note this only affects tiles at `floor + 2` layers or higher; a low overhang is
  treated as a wall.
- **A wall the player is leaning on flickers** — lower `keyhole_body_radius`, or
  raise `KEY_GATE_SOFT` in the shader so borderline tiles ghost more gently.
- **A roof does not come off** — check that both the roof cells and the player's
  standing position are inside the same `interior` zone box, and that the roof is
  at least `KEY_ABOVE_LAYERS` above the player's floor layer. In the editor, drag
  the zone and watch `IsoGrid` re-sprite (it hashes zone transforms each frame).
- **More than 8 tracked entities** — widen `_data_image` and `MAX_KEYHOLES`
  together. The shader needs no change but costs one more texel-fetch pair and
  axis evaluation per fragment.

### Gate-specific

- **A wall that should fade stays solid** — its coverage never reached
  `keyhole_cover_on`. Run `tools/keyhole_diag.gd` and read the sweep line for that
  position: it prints the per-group coverage the walk actually found. Either lower
  the threshold or raise `keyhole_body_radius` so the silhouette samples spread
  wider.
- **A wall fades a beat late** — raise `keyhole_fade_in_rate`, or lower
  `keyhole_cover_on` so it latches earlier.
- **A wall flickers as the player skirts it** — widen the hysteresis band (raise
  `keyhole_cover_on`, lower `keyhole_cover_off`) or raise `keyhole_hold`.
- **Half an L-corner fades and half does not** — the two walls did not fuse.
  Check the corner-fusion rule in §12; the offset it looks for is `(1,0,-1)`
  between an exposed +X face and an exposed +Z face.
- **Too much of a structure fades at once** — corner fusion merged more than
  intended, or an `occluder` box is too generous. `tools/keyhole_diag.gd` prints
  the group-size histogram; an unexpectedly large group is the tell.
- **Two walls should fade together but do not** — drop
  `scenes/occluder_zone.tscn` over both. Remember it can only merge, never split
  (§12).
- **A wall covering the player from one side only never reacts** — that is the
  column-enumeration failure mode. Run the oracle sweep in
  `tools/keyhole_diag.gd`; if it reports mismatches, `COLUMN_SPREAD` is too small
  for the current body height.
- **You can see the inside of a wall through the hole** — `keyhole_shell_cut` is
  0, or the cells in question are not being marked interior. The diag prints every
  interior cell's coordinates.
- **Everything is one frame stale** — expected. The gate is computed in
  `_process` from the current frame's entity positions and consumed by the same
  frame's draw, but a group's *smoothed* value always lags its target by design.
- **Disable the whole feature** — untick `keyhole_require_occlusion` and set
  `keyhole_shell_cut` to 0. That is bit-for-bit the pre-gate behaviour.

---

## 16. Verifying changes

```
godot --headless --path <project> --script res://tools/keyhole_diag.gd
```

`tools/keyhole_diag.gd` exits non-zero on failure and covers:

| Check | What it catches |
|-------|-----------------|
| **Invariants** | Prints the view direction in grid space and asserts it is `(1,1,1)`; asserts a diagonal step moves a cell < 0.01 px on screen. Fires if `Iso.PITCH` or `Iso.LAYER_PX` changes (§10). |
| **Grouping** | Cell / group / ungrouped counts, the group-size histogram, and every interior cell's coordinates. A sudden jump in group count means the fusion rules changed behaviour. |
| **Synthetic layouts** | A flat wall (1 group, 0 interior), an L-corner (must fuse to 1 group), and an alcove return (the hidden cell must be interior, the front cell shell). These run on `OccluderGroups.build` directly, so they hold regardless of what the shipped level contains. |
| **Occluder override** | Wraps the level in one `occluder` box, asserts it fuses to a single group, then removes it and asserts the original grouping returns. |
| **Oracle sweep** | The important one. At 80 player positions across the built-up map it runs the cheap column walk *and* a brute-force scan of every placed cell, and asserts they agree — same groups, same coverage. This is what catches an incomplete `COLUMN_SPREAD` (§11). |
| **Fade ramp** | Prints the peak gate over 24 frames from a clean state; it must rise gradually rather than snapping to 1. |
| **Gate range** | Asserts every gate stays within `[0,1]`, the precondition for the gate being purely subtractive (§13). |

The synthetic layouts matter because level geometry does not reliably exercise
these paths: the shipped `level.tscn` had **zero** interior cells before corner
fusion was added, so the shell logic was entirely untested by it.

The oracle sweep matters because the column enumeration is the one part of this
system with no closed-form correctness argument — it is a constant chosen with
margin. The oracle is far too slow for `_process` (O(placed cells) per entity per
frame) but it is exact, which makes it the right shape for a test. Its teeth are
measurable: narrowing `COLUMN_SPREAD` to 0 — the original "search only the body's
own column" enumeration — fails 33 of the 80 positions.

### Two things the diag does not cover

- **The shader path.** `keyhole_diag` is headless, so it never rasterises. To
  confirm the shader consumes `tile_group` / `tile_shell`, run windowed and force
  the parameter across the sprite layer — flipping `tile_shell` to 0.0 on every
  billboard must change the frame.
- **The subtractive property, empirically.** The diag asserts the precondition
  (gates in `[0,1]`); the guarantee itself comes from the shader's
  `mix(1.0, faded_alpha, gate)` form (§13), not from a pixel test.

### Regressions in the other direction

The gate touches `occlusion.gdshader` and `IsoGrid._apply_occlusion`, both shared
with the outline system. After any change here, also run the outline suite from
[`outline_occlusion.md`](outline_occlusion.md) §11 — `occ_diag`, `repro4`,
`ramp_diag`, `stair_slope_diag`, `repro`, `repro2`, `tile_fit` — and diff the
output text; it should be byte-identical. Note that `stair_slope_diag` loads
`scenes/level.tscn`, so editing the level legitimately changes its output.
