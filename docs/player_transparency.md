# Player transparency ("keyhole") pipeline

Any tile that stands between the camera and a tracked entity fades away inside a
soft circular window centred on that entity, so the player is never lost behind a
wall. Roofs and ceilings of the building the player is currently inside are cut
away entirely.

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

---

## 2. Cast of files

| File | Role |
|------|------|
| `scripts/level.gd` (`Level`) | The director. Collects entities, packs the data texture, publishes the globals. |
| `scripts/interior_zones.gd` (`InteriorZones`) | Collects designer-drawn interior volumes and resolves point → zone bitmask. |
| `scripts/iso_grid.gd` (`IsoGrid`) | Bakes `tile_near`, `tile_layer` and `tile_zones` onto each billboard. |
| `assets/shaders/occlusion.gdshader` | Does the per-pixel reveal. |
| `project.godot` `[shader_globals]` | Declares the six global uniforms and their editor defaults. |
| `scenes/level.tscn` | Holds the `Level` node, the `GridMap`, and the `Player` (in the `keyhole` group). |
| `scenes/interior_zone.tscn` | A ready-made `Area3D` + `BoxShape3D` in the `interior` group. |

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

### State
- `_entities` — the tracked `Node3D`s, from the `keyhole` group.
- `_zones` — the interior zones, collected once (see `refresh()`).
- `_data_image` / `_data_texture` — the 8×2 `FORMAT_RGBAF` image and the
  `ImageTexture` wrapping it.
- `_grid` — the sibling `GridMap`, used to resolve an entity's floor layer.

### `MAX_KEYHOLES`
8. This is simultaneously the data texture's width and the shader's loop budget.
Raising it means widening the image; the shader loops to `keyhole_count` and needs
no change, but the per-fragment cost scales linearly.

### `_ready()`
Creates the 8×2 RGBAF image and its `ImageTexture`, publishes the texture as the
`keyhole_data` global **once**, pushes the tuning floats, and calls `refresh()`.
Because `ImageTexture.update()` mutates the same GPU resource in place, the global
never has to be re-set after this.

### `refresh()`
Re-scans the `keyhole` group into `_entities` and re-collects `_zones`. Call it
after spawning or despawning a tracked entity, or after moving an interior zone at
runtime. Entities register themselves simply by joining the group — the player,
and later party members or NPCs, need no other wiring.

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

After the loop, the texture is uploaded only when at least one entity was packed
(with `keyhole_count == 0` the shader ignores the texture entirely), and
`keyhole_count` is published.

Invalid instances are skipped but not pruned; `refresh()` is the pruning step.

### `_floor_layer(foot) -> float`
`_grid.local_to_map(_grid.to_local(foot - (0, 0.5, 0))).y`. Sampling half a unit
*below* the feet lands inside the floor cell whether that cell is a full block or
a shallow slab. Returns 0 when there is no `GridMap`.

### `_push_tuning()`
Publishes `keyhole_radius`, `keyhole_fade`, `keyhole_min_alpha` and
`keyhole_above_reach` as global shader parameters.

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

Because these are instance parameters rather than uniforms, all cells of the same
tile type still share one `ShaderMaterial` — which is the reason the sprite layer
exists at all (a `GridMap` batches cells and offers no per-cell inputs).

---

## 7. `scripts/interior_zones.gd` — interior zones

A designer marks the inside of a building by dropping `scenes/interior_zone.tscn`
(an `Area3D` with a `BoxShape3D`, in the `interior` group) and dragging its box
over the building. Any node in the `interior` group carrying a `BoxShape3D` works;
`_box` accepts the shape on the node itself or on a direct child.

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

### `hash_of(tree) -> int`
Hash of every zone's transform and size. `IsoGrid._process` compares it against
`_zone_hash` each editor frame, so dragging or resizing a zone re-sprites the grid
and re-bakes `tile_zones`.

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
    float gate = min(min(clear.x, clear.y), clear.z);
    if (gate <= 0.0) continue;

    vec2 center = floor(e0.xy) + 0.5;
    float dist = length(FRAGCOORD.xy - center);
    float reach = keyhole_fade + (above ? keyhole_above_reach : 0.0);
    reveal = max(reveal, gate * (1.0 - smoothstep(keyhole_radius, keyhole_radius + reach, dist)));
}
ALPHA = cut ? 0.0 : ALPHA * (1.0 - reveal * (1.0 - keyhole_min_alpha));
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
7. The final alpha keeps `keyhole_min_alpha` of the sprite at the very centre.

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

## 10. Data flow, end to end

```
"keyhole" group ─▶ Level.refresh ─▶ _entities
"interior" group ─▶ InteriorZones.collect ─▶ _zones
                                     │
Level._process (per frame):          │
  foot = e.global_position           │
  screen = unproject(foot + mid)  ◀──┘ mid = keyhole_body_layers * cell.y / 2
  far    = foot - (r, 0, r)
  layer  = _floor_layer(foot)
  zones  = InteriorZones.mask_at(_zones, foot)
        └─▶ _data_image ─▶ _data_texture.update() ─▶ global keyhole_data
        └─▶ global keyhole_count
  (setters) ─▶ globals keyhole_radius / _fade / _min_alpha / _above_reach

IsoGrid._apply_occlusion (per cell, on refresh):
  tile_near  = cell_center + type.near_offset
  tile_layer = cell.y
  tile_zones = InteriorZones.mask_at(_int_zones, cell_center)
        └─▶ instance shader parameters

occlusion.gdshader fragment():
  overhead + shared zone      ─▶ ALPHA = 0
  else three-axis gate × disc ─▶ ALPHA *= 1 - reveal * (1 - min_alpha)
```

---

## 11. Tuning notes

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
  gate evaluation per fragment.
