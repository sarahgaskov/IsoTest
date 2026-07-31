# Lighting — the bake

Light is **photographed, not lit**. Nothing in the shipped level is a light source.

`LightBake` turns every tile plain white, then shoots the level once per elevation from
the game's exact camera. White albedo means the picture that comes back *is* the light —
sun, shadow, ambient, sky tint, AO — with no tile colour mixed into it. Multiply a sprite
by the pixel it lands on and the sprite is lit.

**Two files and one node:**

| Part | Where |
|---|---|
| The node | `LightBake` on `Level/LightBake` in `scenes/dungeon/levels/level.tscn` |
| The bake | `data/lightdata/<level>/elev_<n>.png` + `bake.json` |
| Lights | Any `Light3D` **under `LightBake`** — `SunLight` is the only one so far |

---

## 1. How a bake happens

1. Every cell in the stack is merged into **one white mesh per elevation**
   (`LightBakeTools.slice_meshes`). Elevation is the GridMap **y**, so all three layers at
   y=0 land in the same slice.
2. A `SubViewport` gets its own `World3D`, the level's `Environment`, copies of every light
   under `LightBake`, and an orthogonal camera at `IsoView.camera_basis()` framing the whole
   level at one texel per art pixel.
3. For each elevation: that slice renders normally, **every other slice flips to
   `SHADOWS_ONLY`**. So a wall two floors up still lays its shadow on this floor without ever
   appearing in this floor's picture.
4. The frame is grabbed, boxed down from `supersample`, and saved as a png.

The viewport is transparent and the bake environment's background is forced to clear colour,
so **nothing but tiles reaches the film** — no sky, no horizon. The sky is still switched on
as an ambient and reflection source, and the renderer keeps it for those even when it is never
drawn, so shadows are filled exactly as they are in game.

Alpha is **coverage, not light**: 1 where the bake saw a tile, 0 where it saw nothing. The
light itself is bled a few pixels past every silhouette (`fix_alpha_edges`) before the
downsample, because `Image.resize` knows nothing about alpha and would otherwise average
every edge with transparent black and outline each tile in soot. So a sprite that overhangs
its mesh by a pixel still samples real light.

A bake happens when the `Bake lighting` button is pressed, or when `Level._ready` finds no
bake on disk, or one whose tile stamp no longer matches the tiles. The stamp is the same
fingerprint the old GI bake used.

**Rendering works anywhere; saving does not.** `res://` is only a real directory in an editor
build — an export packs it read-only. So a shipped game missing its bake still lights itself
correctly, it just re-shoots into memory on every launch and warns. Ship the pngs.

> The bake is offline, so **quality is free**. Nothing about it runs in game. Point
> `bake_environment` at an `Environment` with SSIL, high SSAO, and a big shadow size and
> the level pays nothing for it at runtime.

## 2. What comes out

`bake.json` carries the projection that addresses the pngs:

```json
{ "stamp": 1234, "rect": [-334.9, -161.2, 792.0, 468.5], "slices": {"0": "elev_0.png"} }
```

`rect` is the level's footprint **in camera space, in world units** — position is the
bottom-left corner, size is the extent. Image rows run top-down, so:

```
view = IsoView.camera_basis().inverse() * world_position
px.x = (view.x - rect.position.x) / IsoView.WORLD_PER_PX
px.y = (rect.end.y - view.y)      / IsoView.WORLD_PER_PX
```

That is `LightBakeTools.to_pixel`. The depth component is thrown away — which is exactly
why there is one image per elevation, since two elevations land on the same pixel.

Set the pngs to **Lossless, no mipmaps, Nearest** in the import dock, and leave the alpha
channel alone. Anything else softens the light across pixel boundaries and shows up as
fringing on the sprites.

## 3. Using it

**Tiles** — sample by world position, not `SCREEN_UV`, so the bake survives a panning
camera:

```glsl
shader_type spatial;
render_mode unshaded;

uniform sampler2D light : filter_nearest;
uniform vec4 light_rect;   // rect from bake.json
uniform mat3 to_view;      // IsoView.camera_basis().inverse()

void fragment() {
    vec3 v = to_view * (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec2 uv = vec2((v.x - light_rect.x) / light_rect.z,
             1.0 - (v.y - light_rect.y) / light_rect.w);
    ALBEDO = texture(TEXTURE, UV).rgb * texture(light, uv).rgb;
}
```

Each elevation's sprites get that elevation's slice. Folding the slices into one
`Texture2DArray` indexed by elevation collapses this to a single uniform.

**The player and anything else that moves** — the bake never saw them. `LightBake.light_at`
reads one pixel off the CPU-side copy:

```gdscript
sprite.modulate = light_bake.light_at(global_position, elevation)
```

Cheap enough to run every frame. It darkens the character in shadow and warms them in a
torch pool, but it is a single flat tint: it cannot light their head differently from their
feet, and they still cast no shadow. See §5.

## 4. What the bake cannot do

| | |
|---|---|
| Moving lights, flicker, spells | Not in the bake at all |
| The player's own shadow | Not in the bake at all |
| Doors, destructibles | Bake goes stale — the stamp catches it, but only at edit time |
| AO between elevations | Screen-space AO only sees the slice being shot, so it stops at the slice boundary. Real sun shadows do cross elevations |
| Values above 1.0 | Clipped. Keep light energy at or under 1 or bright pools flatten out |

## 5. The dynamic pass, when the bake is not enough

The bake covers everything static. The fix for the rest is a **second, tiny render** — the
same white geometry, at 480×270, holding only what moves:

- **Shadow mask** — the sun plus an invisible capsule proxy at the player, static geometry
  receiving but not casting. Comes back white with a dark blob where the player's shadow
  falls. Multiply it in.
- **Dynamic add** — moving point lights only, no sun, no ambient. Add it in.

`final = albedo * baked * shadow_mask + dynamic_add`

Both are untextured renders of a handful of surfaces at a postage-stamp resolution, so the
cost is nothing. The player's capsule proxy also means the player is *properly* lit by the
moving lights rather than flat-tinted: sample the add pass at `SCREEN_UV` in the player's
shader. None of this exists yet — `LightBake` is the static half.

## 6. Editor aids

- **Bake lighting** on `Level` — re-shoots every elevation and writes the pngs, whether or
  not anything changed.
- **`supersample`** — render multiple, then box down. 2 is usually enough to kill the
  stair-stepping on shadow edges; 1 is a fast preview.
- The pngs are plain images. Painting on them by hand works, until the next bake.
