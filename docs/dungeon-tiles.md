# Tiles — the barebones mesh editor

IsoTest is Imagima's dungeon tile system cut down to one job: painting correctly
sized 3D meshes onto a stack of grids. No billboards, no shaders, no occlusion,
no fade, no player. What you see is the `.obj` itself. Light is photographed off
these meshes rather than lit in game — see [dungeon-lighting.md](dungeon-lighting.md).

**Two files and one node:**

| Part | Where |
|---|---|
| Catalogue | `data/tiles/tiles.json` |
| Solids | `assets/gfx/dungeon/tiles/meshes/*.obj` |
| The grid | `IsoGrid` on `Level/Floor` in `scenes/dungeon/levels/level.tscn` |

---

## 1. `data/tiles/tiles.json`

Unchanged from Imagima, so a level built here can be moved back over.

```json
{
  "tilesheets": [
    { "path": "res://assets/gfx/dungeon/tiles/dev/block_dev.png", "layer": 1 },
    { "path": "res://assets/gfx/dungeon/tiles/city/concrete_floor_city.png", "layer": 0 }
  ],
  "tiles": [
    { "name": "slab_5", "sheet": 0, "sheet_region": [0, 0, 64, 64],
      "mesh": "res://assets/gfx/dungeon/tiles/meshes/slab_5.obj" },
    { "name": "stairs_e", "sheet": 1, "sheet_region": [448, 0, 64, 64],
      "mesh": "res://assets/gfx/dungeon/tiles/meshes/stairs.obj", "rotation": "e" }
  ]
}
```

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Shown in the editor palette |
| `sheet` | no (default 0) | Index into `tilesheets` — this is what files the tile in a layer |
| `sheet_region` | yes | `[x, y, w, h]` on that sheet. Only used for the palette thumbnail |
| `mesh` | yes | The `.obj`, and the only thing rendered |
| `rotation` | no (default `"n"`) | `n`/`e`/`s`/`w`. One mesh serves all four facings |

The billboard sprite half of Imagima is **mentioned but not drawn**: a tilesheet
region becomes the palette thumbnail so you can tell tiles apart, and nothing
else. `offset_px` is ignored here — it only ever shifted the billboard.

> ⚠️ **A tile's array index IS its GridMap item id.** Reordering `tiles`
> renumbers every placed cell. **Append, never insert.**

## 2. Layers

A level is a stack of `GridMap`s sharing cells, an origin and a cell size, so one
cell can hold one tile per layer:

```
Level
├── Floor      IsoGrid, overlays = [ ../Tiles, ../Overlay ]   layer 0
├── Tiles      GridMap (no script, nothing configured)        layer 1
└── Overlay    GridMap                                        layer 2
```

Each layer gets its **own** `MeshLibrary`, holding exactly the tiles whose
tilesheet names that layer, so a layer's palette offers only what belongs in it.
Tile ids stay global across layers, so a layer's library is a subset with holes
in its numbering. Layer 2 is a spare: no tilesheet claims it yet, so its palette
is empty until one does.

To add a layer, drop a plain `GridMap` beside the others, leave every property at
its default, add its path to `overlays`, and give some tilesheet its index.

## 3. Sizing

Every `.obj` is authored inside a ±12 cube facing `"n"`. `TileBuilder.tile_mesh`
rotates it per `rotation` and squashes Y by `cell_world_size().y / 24`, so a full
cube fills exactly one cell: a 48×24 px diamond, 24 px per layer stacked. The
numbers live in `IsoView` and changing any of them changes the whole look.

The `Camera3D` in `level.tscn` is orthogonal, angled by `IsoView.camera_basis()`,
with `size` = viewport height × `WORLD_PER_PIXEL` — 270 × √2/2 = 190.91883, which
lands one art pixel on one screen pixel.

Nothing is lit. At bake time every triangle gets a flat colour picked from the
direction it faces, written into its vertex colours and drawn unshaded, so faces
pointing the same way share a colour and the shape still reads. The colour itself
is arbitrary — `hash` of the normal, rounded to `NORMAL_STEPS` per axis so a
normal that only differs by rounding error still lands on the same colour. It is
the same across every tile: all four walls of a cube are four colours, and the
north wall of one tile matches the north wall of the next.

## 4. Checklist for a new tile

1. Add the `.obj` to `assets/gfx/dungeon/tiles/meshes/`, facing `"n"` inside the
   ±12 cube.
2. Append an entry to `data/tiles/tiles.json` — one per `rotation` you need.
3. Press **Rebuild tiles** on the `IsoGrid`, or run it headless:
   `godot --headless --path . --script res://tools/rebuild_lib.gd`

`sheet`/`sheet_region` can point at any existing sheet; the thumbnail is
cosmetic.

## 5. Editor aids

- **Rebuild tiles** — regenerates `scenes/dungeon/tilesets/tile_mesh_lib_*.tres`
  from `tiles.json`. Editor only, writes to disk.
- **Isometric view** — snaps the editor viewport to the game's exact camera
  angle, so what you build is what you see.
