# Lighting — the proxy pass

Nothing you see is lit. Light is rendered every frame off **white stand-ins** for the tiles,
into a viewport the size of the screen, and the sprites multiply themselves by the result.

**One node:**

| Part | Where |
|---|---|
| The node | `Lighting` on `Level/Lighting` in `scenes/dungeon/levels/level.tscn` |
| Lights | Any `Light3D` under it — `SunLight` is the only one so far |

---

## 1. How it works

1. On load every cell in the stack is merged into one white `MeshInstance3D`, put inside a
   `SubViewport` that holds **its own `World3D`** — so the stand-ins exist nowhere the game
   can see them, and the game's tiles are nowhere the pass can see.
2. That world takes the level's **same `Environment` resource**, so ambient, sky tint and the
   rest reach the light exactly as they reach the game. The environment is part of the
   lighting.
3. Copies of every `Light3D` under `Lighting` go in with it.
4. The pass camera copies the game camera every frame — transform, projection, size, near, far.
5. `Lighting.texture` is the result: white where lit, dark in shadow.

> ⚠️ **The separate world is load-bearing, not tidiness.** Godot creates one light instance
> per light *per world*, and `_render_scene` writes each camera's shadow fit onto that
> instance once per viewport render. Two cameras sharing a world therefore overwrite each
> other's shadow setup every frame: shadows flicker in both views and the pass gets none.

Lights must live **under `Lighting`** to be copied in. That is the price of the separate world.

The pass is `transparent_bg`, which stops the sky being *drawn* into it while the sky still
feeds ambient and reflections. The background lands opaque black rather than transparent,
because Godot leaves `clear_color` at its default in the sky branch — harmless, since sprites
carry their own coverage.

> ⚠️ **`Level/Camera3D.far` sets the shadow range.** For an orthogonal camera Godot ignores
> `directional_shadow_max_distance` outright and fits directional shadows across the camera's
> whole `near`..`far`. At the default `far` of 4000 the shadow map is stretched over 4000
> units, which is far too little depth precision: shadows come out smeared and crawl. It is
> set to **600**, which just clears the level.

## 2. Using it

Both passes share a camera, so a sprite reads its own pixel of the light with `SCREEN_UV` —
no projection maths, and it survives a panning camera for free:

```glsl
shader_type spatial;
render_mode unshaded;

uniform sampler2D light : filter_nearest;

void fragment() {
    ALBEDO = texture(TEXTURE, UV).rgb * texture(light, SCREEN_UV).rgb;
}
```

Bind it once from `Lighting.texture`.

**Anything that moves works the same way**, as long as it has a stand-in inside the pass. A
capsule at the player both lights the player's sprite and casts the player's shadow across the
level, because it is in the pass like everything else. There is no separate path for dynamic
objects.

**The keyhole** is a `discard` on the stand-in mesh. Do it in the shadow pass as well as the
colour pass and a hidden wall stops casting as well as stops drawing, so whatever the keyhole
reveals is lit correctly with no extra work. Visibility is resolved fresh every frame, which
is the whole reason this is not baked.

## 3. Cost

The level is ~313 cells, about 2,100 triangles, and the pass is 480×270 — 129,600 pixels.
Rendering it twice a frame is not measurable. The only part not limited by the camera frustum
is the directional shadow map, since off-screen geometry still casts into view — and its range
comes from `Camera3D.far`, as above.

Shadow atlas size is worth lowering from the default: chunky shadow edges suit 480×270, and a
4096² atlas is 16.7M depth samples against 129,600 colour pixels.

## 4. Editor aids

- **`debug`** on `Lighting` — draws the light pass over the level instead of the game, which
  is the only way to see what the pass actually contains.
