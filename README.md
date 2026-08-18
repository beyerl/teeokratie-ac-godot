# Teeokratie — data-driven Godot port

A Godot 4.3 re-implementation of *Teeokratie*, a 2D point-and-click adventure
originally built in Unity with the **Adventure Creator** framework.

Rather than hand-rebuilding each room, this port is **data-driven**:

1. **`extractor/`** — a one-time Python pipeline that reads the original Unity
   project (scenes, ActionLists, managers) and emits Godot-friendly JSON
   (`game/data/*.json`) plus the referenced pixel-art textures (`game/assets/`).
   It parses the serialized AdventureCreator *Action graphs*, hotspots (from
   colliders), markers, nav outlines, inventory, variables and the 324-line
   speech table — mechanically, so rooms become **data**, not hand-written code.

2. **`game/`** — a small Godot runtime (the analogue of AC's `KickStarter` +
   managers) that interprets that data:
   - `scripts/Game.gd` — global state, variables, inventory, speech table.
   - `scripts/ActionRunner.gd` — interprets an AC ActionList (the ~30 Action
     types the game actually uses) with AC's Continue/Stop/Skip + branch flow.
   - `scripts/Main.gd` — builds a room from JSON (sprites, hotspots, nav, player),
     the verb-coin interaction menu (Betrachte / Sprich mit / Benutze),
     click-to-walk movement, and subtitle speech.

Reference build (original Unity WebGL): https://beyerl.github.io/teeokratie/

## Status

Early but functional vertical slice: rooms render from extracted data, the
verb-coin interaction loop runs real ActionLists, Teesa walks, and speech shows
the original German lines. See `engine-analysis` (sister folder) for the AC-usage
study that scoped this port.

Implemented Actions: Speech, Pause, VarSet/VarCheck/VarPopup, CharPathFind,
CharFaceDirection, Teleport, Visible, SpriteFade, InventorySet/Check,
HotspotEnable, ObjectiveSet, Scene/SceneCheck, RunActionList, Parallel,
Conversation (basic). Stubs (safe no-ops for now): MenuState, Anim, Instantiate,
Music/Ambience/MixerSnapshot, DialogOption, Event.

Known follow-ups: real Teesa sprite-sheet animation (currently a placeholder
figure), conversation option UI, audio import, save/load, and full ActionList
branch fidelity.

## Build

```bash
# regenerate data from the Unity project (paths hard-coded in extract.py)
python3 extractor/extract.py

# run / export (Godot 4.3)
godot --path game                       # play in editor/runner
godot --headless --path game --export-release "Web" game/build/index.html
```

Web export is single-threaded (no COOP/COEP headers needed) so it runs on GitHub
Pages. CI in `.github/workflows/deploy.yml` builds and publishes automatically.
