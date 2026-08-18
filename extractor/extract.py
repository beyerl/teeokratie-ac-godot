#!/usr/bin/env python3
"""
Unity(AdventureCreator) -> Godot data extractor for Teeokratie.

Emits data-driven JSON (game/data/*.json) + copies referenced textures
(game/assets/) so the Godot runtime can build each room without hand-authoring.

What it extracts per scene:
  - sprites  : every SpriteRenderer (texture, world pos, scale, flip, sorting)
  - hotspots : name, world AABB (from collider), verb buttons -> interaction id
  - markers / playerStarts : world positions (walk targets, spawn points)
  - navPolys : PolygonCollider2D points (world) used for the walkable nav mesh
  - actionLists : every reachable Interaction/Cutscene/OnStart as an Action graph
  - camera   : orthographic size + position
Globals (globals.json):
  - inventory items, variables, cursorIcons, speech table (lineID->text), settings.

Unity is Y-up, Godot is Y-down; we flip Y and scale world units by PPU (100).
"""
import os, re, json, shutil, sys
sys.path.insert(0, os.path.dirname(__file__))
import uyaml

BASE = "/home/lorenz/Dokumente/Game Design/Development/Teeokratie"
ASSETS = os.path.join(BASE, "Assets")
OUT = os.path.join(os.path.dirname(__file__), "..", "game")
DATA = os.path.join(OUT, "data")
ASSET_OUT = os.path.join(OUT, "assets")
PPU = 32.0  # sprite import "spritePixelsToUnits" for this project's pixel art

SCENES = {
    "Office":   "TeaistCloisterOffice.unity",
    "Kitchen":  "TeaistCloisterKitchen.unity",
    "Anteroom": "TeaistCloisterAnteroom.unity",
    "Intro":    "IntroCutscene.unity",
    "Title":    "TitleScreen.unity",
    "Credits":  "Credits.unity",
}
ICON_VERB = {0: "use", 1: "talk", 2: "look"}

# ---------------------------------------------------------------- asset maps
_guid_re = re.compile(r'guid:\s*([0-9a-f]{32})')

def build_asset_maps():
    """guid -> {path, name, is_script}; also class-name for scripts."""
    gmap = {}
    for root, _d, files in os.walk(ASSETS):
        for f in files:
            if not f.endswith(".meta"):
                continue
            src = f[:-5]
            try:
                t = open(os.path.join(root, f), errors="replace").read()
            except Exception:
                continue
            m = _guid_re.search(t)
            if not m:
                continue
            rel = os.path.relpath(os.path.join(root, src), ASSETS)
            gmap[m.group(1)] = {
                "path": os.path.join(root, src),
                "rel": rel,
                "name": os.path.splitext(src)[0],
                "is_script": src.endswith(".cs"),
                "ext": os.path.splitext(src)[1].lower(),
            }
    return gmap

GMAP = {}

def script_class(mb):
    s = mb["data"].get("m_Script") or {}
    info = GMAP.get(s.get("guid"))
    return info["name"] if info else None

# ------------------------------------------------------- transform world pos
def build_index(objs):
    """Return helpers over a loaded scene."""
    go_transform = {}      # gameObject fileID -> transform fileID
    for fid, o in objs.items():
        if o["type"] in ("Transform", "RectTransform"):
            go = str((o["data"].get("m_GameObject") or {}).get("fileID"))
            go_transform[go] = fid
    return go_transform

def local_pos(tr):
    p = tr["data"].get("m_LocalPosition") or {}
    return [float(p.get("x", 0)), float(p.get("y", 0)), float(p.get("z", 0))]

def local_scale(tr):
    s = tr["data"].get("m_LocalScale") or {}
    return [float(s.get("x", 1)), float(s.get("y", 1)), float(s.get("z", 1))]

def world_of_transform(objs, tr):
    """Accumulate position/scale up the m_Father chain (2D, ignore rotation)."""
    x = y = 0.0; sx = sy = 1.0
    seen = set()
    cur = tr
    while cur is not None:
        cid = id(cur)
        if cid in seen:
            break
        seen.add(cid)
        lp = local_pos(cur); ls = local_scale(cur)
        # apply parent scale to child offset as we go up: approximate by summing
        x += lp[0]; y += lp[1]
        sx *= ls[0]; sy *= ls[1]
        fa = (cur["data"].get("m_Father") or {}).get("fileID")
        cur = objs.get(str(fa)) if fa and str(fa) != "0" else None
    return x, y, sx, sy

def world_of_go(objs, go_transform, go_fid):
    tfid = go_transform.get(str(go_fid))
    if not tfid:
        return None
    return world_of_transform(objs, objs[tfid])

def to_godot(x, y):
    return [round(x * PPU, 2), round(-y * PPU, 2)]

# ------------------------------------------------------------- action graphs
# Editor-only fields we drop from serialized actions.
_DROP = {"m_ObjectHideFlags","m_CorrespondingSourceObject","m_PrefabInstance",
    "m_PrefabAsset","m_GameObject","m_Enabled","m_EditorHideFlags","m_Script",
    "m_Name","m_EditorClassIdentifier","description","isDisplayed","showComment",
    "comment","nodeRect","overrideColor","showOutputSockets","parentActionListInEditor",
    "isAssetFile","isBreakPoint","title","category","id"}

def clean_action(objs, aid):
    ao = objs.get(str(aid))
    if not ao:
        return {"type": "MISSING", "fileID": str(aid)}
    cls = script_class(ao)
    d = ao["data"]
    fields = {k: v for k, v in d.items() if k not in _DROP}
    fields["type"] = cls or "Unknown"
    return fields

def extract_actionlist(objs, fid):
    o = objs.get(str(fid))
    if not o:
        return None
    d = o["data"]
    acts = d.get("actions") or []
    nodes = []
    for a in acts:
        aid = (a or {}).get("fileID")
        nodes.append(clean_action(objs, aid))
    return {
        "name": d.get("m_Name"),
        "type": script_class(o),
        "actionListType": d.get("actionListType"),
        "actions": nodes,
    }

# ---------------------------------------------------------------- sprites
_meta_cache = {}

def _sprite_rects(meta_path):
    """Parse a texture .meta -> {internalID(str): [x,y,w,h]} plus 'first'. Unity rect
    origin is bottom-left; we convert to top-left for Godot AtlasTexture regions."""
    if meta_path in _meta_cache:
        return _meta_cache[meta_path]
    out = {"by_id": {}, "first": None, "img_h": None}
    try:
        objs = uyaml.load(meta_path)  # .meta is single-doc YAML but loader tolerates
    except Exception:
        objs = {}
    # .meta isn't tagged like scenes; fall back to a raw yaml load.
    if not objs:
        try:
            import yaml as _y
            raw = _y.safe_load(open(meta_path, errors="replace").read())
            ti = (raw or {}).get("TextureImporter", {})
            ss = ti.get("spriteSheet", {})
            sprites = ss.get("sprites", []) or []
            for s in sprites:
                r = s.get("rect", {})
                iid = str(s.get("internalID", ""))
                rect = [float(r.get("x",0)), float(r.get("y",0)),
                        float(r.get("width",0)), float(r.get("height",0))]
                if out["first"] is None:
                    out["first"] = rect
                if iid:
                    out["by_id"][iid] = rect
        except Exception:
            pass
    _meta_cache[meta_path] = out
    return out

def resolve_texture(sprite_ref):
    """m_Sprite {fileID,guid} -> (res path, region-or-None).
    For multi-sprite sheets, region crops to the referenced frame (top-left origin)."""
    if not sprite_ref:
        return None, None
    guid = sprite_ref.get("guid")
    info = GMAP.get(guid)
    if not info:
        return None, None
    src = info["path"]
    if not os.path.exists(src) or info["ext"] not in (".png", ".jpg", ".jpeg"):
        return None, None
    dst_name = re.sub(r'[^A-Za-z0-9_.-]', '_', info["name"]) + info["ext"]
    dst = os.path.join(ASSET_OUT, dst_name)
    if not os.path.exists(dst):
        try:
            shutil.copy2(src, dst)
        except Exception:
            return None, None
    region = None
    meta = src + ".meta"
    rects = _sprite_rects(meta)
    if rects["by_id"] or rects["first"]:
        fid = str(sprite_ref.get("fileID", ""))
        rect = rects["by_id"].get(fid) or rects["first"]
        if rect:
            try:
                from PIL import Image
                h = Image.open(src).size[1]
            except Exception:
                h = None
            x, y, w, hh = rect
            if h is not None and w > 0 and hh > 0:
                # convert bottom-left origin -> top-left
                region = [round(x), round(h - y - hh), round(w), round(hh)]
    return "res://assets/" + dst_name, region

# ---------------------------------------------------------------- collider aabb
def collider_world_aabb(objs, go_transform, comp_obj, wx, wy, sx, sy):
    d = comp_obj["data"]
    off = d.get("m_Offset") or {"x": 0, "y": 0}
    size = d.get("m_Size")  # BoxCollider2D
    if size:
        hw = float(size.get("x", 0)) * abs(sx) / 2.0
        hh = float(size.get("y", 0)) * abs(sy) / 2.0
        cx = wx + float(off.get("x", 0)) * sx
        cy = wy + float(off.get("y", 0)) * sy
        return {"cx": cx, "cy": cy, "hw": hw, "hh": hh}
    # CircleCollider2D
    r = d.get("m_Radius")
    if r is not None:
        rr = float(r) * abs(sx)
        cx = wx + float(off.get("x", 0)) * sx
        cy = wy + float(off.get("y", 0)) * sy
        return {"cx": cx, "cy": cy, "hw": rr, "hh": rr}
    return None

def polygon_points(objs, comp_obj, wx, wy, sx, sy):
    d = comp_obj["data"]
    mp = d.get("m_Points")
    # Unity stores PolygonCollider2D points as m_Points: { m_Paths: [ [ {x,y}, ... ] ] }
    paths = None
    if isinstance(mp, dict):
        paths = mp.get("m_Paths")
    elif isinstance(mp, list):
        paths = mp
    else:
        paths = d.get("m_Paths")
    pts = []
    def emit(seq):
        for p in seq:
            pts.append(to_godot(wx + float(p.get("x", 0)) * sx, wy + float(p.get("y", 0)) * sy))
    if isinstance(paths, list) and paths and isinstance(paths[0], list):
        emit(paths[0])
    elif isinstance(paths, list):
        emit(paths)
    return pts

# ------------------------------------------------------------------ per scene
def extract_scene(name, filename):
    path = os.path.join(ASSETS, filename)
    objs = uyaml.load(path)
    go_transform = build_index(objs)

    # map GameObject fileID -> its component fileIDs
    go_comps = {}
    go_name = {}
    for fid, o in objs.items():
        if o["type"] == "GameObject":
            go_name[fid] = o["data"].get("m_Name")
            comps = o["data"].get("m_Component") or []
            go_comps[fid] = [str((c.get("component") or {}).get("fileID")) for c in comps]

    sprites, hotspots, markers, playerstarts, navpolys = [], [], [], [], []
    actionlists = {}
    camera = None
    npcs = []

    # index component fileID -> (gameObject fileID)
    comp_owner = {}
    for gid, comps in go_comps.items():
        for c in comps:
            comp_owner[c] = gid

    def wpos(gid):
        w = world_of_go(objs, go_transform, gid)
        return w if w else (0.0, 0.0, 1.0, 1.0)

    for gid, comps in go_comps.items():
        gname = go_name.get(gid) or ""
        wx, wy, sx, sy = wpos(gid)
        for cfid in comps:
            co = objs.get(cfid)
            if not co:
                continue
            t = co["type"]
            if t == "SpriteRenderer":
                # Skip AC editor gizmos (marker / player-start icons) that live on
                # Marker/PlayerStart GameObjects and shouldn't render in-game.
                sibling_classes = set()
                for sib in comps:
                    so2 = objs.get(sib)
                    if so2 and so2["type"] == "MonoBehaviour":
                        sibling_classes.add(script_class(so2))
                if sibling_classes & {"Marker","PlayerStart","_Camera","GameCamera2D"}:
                    continue
                sr = co["data"]
                tex, region = resolve_texture(sr.get("m_Sprite"))
                if not tex:
                    continue
                base = tex.split("/")[-1].lower()
                if base in ("marker.png","playerstart.png","gizmo.png"):
                    continue
                col = sr.get("m_Color") or {}
                flip = sr.get("m_FlipX", 0)
                sprites.append({
                    "name": gname, "texture": tex, "region": region,
                    "pos": to_godot(wx, wy), "scale": [round(sx,4), round(sy,4)],
                    "flipX": int(flip) if flip else 0,
                    "order": int(sr.get("m_SortingOrder", 0)),
                    "layer": sr.get("m_SortingLayerID", 0),
                    "color": [col.get("r",1), col.get("g",1), col.get("b",1), col.get("a",1)],
                    "enabled": int(sr.get("m_Enabled", 1)),
                })
            elif t == "Camera":
                camera = {"pos": to_godot(wx, wy), "size": float(co["data"].get("orthographic size", 5))}
            elif t == "MonoBehaviour":
                cls = script_class(co)
                if cls == "Hotspot":
                    d = co["data"]
                    buttons = []
                    def add_btn(btn, forced_verb=None):
                        if not btn: return
                        inter = (btn.get("interaction") or {}).get("fileID")
                        icon = btn.get("iconID", -1)
                        verb = forced_verb or ICON_VERB.get(icon)
                        if inter and str(inter) != "0":
                            buttons.append({"verb": verb, "iconID": icon,
                                            "interaction": str(inter),
                                            "playerAction": btn.get("playerAction", 0)})
                    if d.get("provideLookInteraction"):
                        add_btn(d.get("lookButton"), "look")
                    if d.get("provideUseInteraction"):
                        add_btn(d.get("useButton"), "use")
                    for b in (d.get("useButtons") or []):
                        add_btn(b)
                    # collider aabb: search sibling collider on same GO
                    aabb = None
                    for sib in comps:
                        so = objs.get(sib)
                        if so and so["type"] in ("BoxCollider2D","CircleCollider2D"):
                            aabb = collider_world_aabb(objs, go_transform, so, wx, wy, sx, sy)
                            break
                    box = None
                    if aabb:
                        box = {"pos": to_godot(aabb["cx"], aabb["cy"]),
                               "size": [round(aabb["hw"]*2*PPU,2), round(aabb["hh"]*2*PPU,2)]}
                    hotspots.append({"name": gname, "pos": to_godot(wx,wy),
                                     "box": box, "buttons": buttons,
                                     "displayName": d.get("hotspotName") or gname})
                elif cls in ("Marker",):
                    markers.append({"name": gname, "pos": to_godot(wx, wy),
                                    "id": co["data"].get("constantID")})
                elif cls == "PlayerStart":
                    playerstarts.append({"name": gname, "pos": to_godot(wx, wy),
                                         "id": co["data"].get("constantID")})
                elif cls == "NPC":
                    npcs.append({"name": gname, "pos": to_godot(wx, wy),
                                 "speechColor": co["data"].get("speechColor")})
                elif cls == "NavigationMesh":
                    # nav geometry is on sibling PolygonCollider2D(s)
                    for sib in comps:
                        so = objs.get(sib)
                        if so and so["type"] == "PolygonCollider2D":
                            pts = polygon_points(objs, so, wx, wy, sx, sy)
                            if len(pts) >= 3:
                                navpolys.append(pts)
                elif cls in ("Interaction","Cutscene","AC_Trigger","Trigger"):
                    actionlists[cfid] = extract_actionlist(objs, cfid)
                    actionlists[cfid]["hostName"] = gname

    # also collect any ActionList referenced by hotspots that we didn't already grab
    for h in hotspots:
        for b in h["buttons"]:
            fid = b["interaction"]
            if fid not in actionlists:
                al = extract_actionlist(objs, fid)
                if al:
                    actionlists[fid] = al

    # conversations: Conversation components -> options (label, enabled, what to run)
    conversations = {}
    for fid, o in objs.items():
        if o["type"] == "MonoBehaviour" and script_class(o) == "Conversation":
            opts = []
            for i, op in enumerate(o["data"].get("options", []) or []):
                dopt = str((op.get("dialogueOption") or {}).get("fileID", "0"))
                newconv = str((op.get("newConversation") or {}).get("fileID", "0"))
                opts.append({
                    "num": i + 1,                        # AC optionNumber is 1-based
                    "label": op.get("label", ""),
                    "lineID": op.get("lineID", -1),
                    "isOn": int(op.get("isOn", 1)),
                    "conversationAction": int(op.get("conversationAction", 0)),
                    "dialogueOption": dopt,
                    "newConversation": newconv,
                })
                # ensure the option's ActionList is extracted
                if dopt != "0" and dopt not in actionlists:
                    al = extract_actionlist(objs, dopt)
                    if al:
                        actionlists[dopt] = al
            conversations[fid] = {"options": opts}

    # refs: map every GameObject fileID AND its component fileIDs -> {name, pos}
    # so actions that reference markers/objects/characters by fileID can resolve.
    refs = {}
    for gid, comps in go_comps.items():
        wx, wy, sx, sy = wpos(gid)
        entry = {"name": go_name.get(gid) or "", "pos": to_godot(wx, wy)}
        refs[gid] = entry
        for c in comps:
            refs[c] = entry

    # scene onStart from SceneSettings
    on_start = None
    for fid, o in objs.items():
        if o["type"] == "MonoBehaviour" and script_class(o) == "SceneSettings":
            ol = (o["data"].get("actionListSource") ,)
            cs = (o["data"].get("cutsceneOnStart") or {}).get("fileID")
            if cs and str(cs) != "0":
                on_start = str(cs)
                if on_start not in actionlists:
                    al = extract_actionlist(objs, cs)
                    if al: actionlists[on_start] = al

    return {
        "name": name,
        "sprites": sorted(sprites, key=lambda s: s["order"]),
        "hotspots": hotspots,
        "markers": markers,
        "playerStarts": playerstarts,
        "navPolys": navpolys,
        "npcs": npcs,
        "camera": camera,
        "onStart": on_start,
        "actionLists": actionlists,
        "conversations": conversations,
        "refs": refs,
    }

# ------------------------------------------------------------------- globals
def extract_globals():
    M = os.path.join(ASSETS, "Teeokratie", "Managers")
    inv = uyaml.load(os.path.join(M, "Teeokratie_InventoryManager.asset"))
    var = uyaml.load(os.path.join(M, "Teeokratie_VariablesManager.asset"))
    cur = uyaml.load(os.path.join(M, "Teeokratie_CursorManager.asset"))
    spe = uyaml.load(os.path.join(M, "Teeokratie_SpeechManager.asset"))
    setg = uyaml.load(os.path.join(M, "Teeokratie_SettingsManager.asset"))

    def first(o, keypred):
        for fid, d in o.items():
            if keypred(d["data"]):
                return d["data"]
        # fallback: the single manager doc
        return next(iter(o.values()))["data"]

    invd = first(inv, lambda d: "items" in d)
    items = []
    for it in (invd.get("items") or []):
        items.append({"id": it.get("id"), "label": it.get("label"),
                      "carryOnStart": it.get("carryOnStart", 0)})
    vard = first(var, lambda d: "vars" in d)
    variables = []
    for v in (vard.get("vars") or []):
        variables.append({"id": v.get("id"), "label": v.get("label"),
                          "type": v.get("type"), "val": v.get("val"),
                          "floatVal": v.get("floatVal"), "textVal": v.get("textVal"),
                          "popUps": v.get("popUps")})
    curd = first(cur, lambda d: "cursorIcons" in d)
    icons = [{"id": i.get("id"), "label": i.get("label")} for i in (curd.get("cursorIcons") or [])]
    sped = first(spe, lambda d: "lines" in d)
    speech = {}
    for ln in (sped.get("lines") or []):
        speech[str(ln.get("lineID"))] = {"text": ln.get("text"),
                                          "speaker": ln.get("owner"),
                                          "type": ln.get("textType")}
    setd = first(setg, lambda d: "movementMethod" in d)
    settings = {k: setd.get(k) for k in
                ("movementMethod","inputMethod","interactionMethod","cameraPerspective",
                 "hotspotDetection","inventoryDragDrop","defaultShowSubtitles")}
    return {"items": items, "variables": variables, "cursorIcons": icons,
            "speech": speech, "settings": settings}

def stringify_fileids(obj):
    """Unity fileIDs are 64-bit ints that lose precision as JSON floats in Godot.
    Convert every {'fileID': <int>} value to a string so the runtime can match refs."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "fileID" and isinstance(v, (int, float)):
                obj[k] = str(int(v))
            else:
                stringify_fileids(v)
    elif isinstance(obj, list):
        for v in obj:
            stringify_fileids(v)
    return obj

def main():
    global GMAP
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(ASSET_OUT, exist_ok=True)
    print("building asset maps...")
    GMAP = build_asset_maps()
    print("  guids:", len(GMAP))
    g = extract_globals()
    json.dump(g, open(os.path.join(DATA, "globals.json"), "w"), indent=1, ensure_ascii=False)
    print(f"globals: {len(g['items'])} items, {len(g['variables'])} vars, "
          f"{len(g['cursorIcons'])} icons, {len(g['speech'])} speech lines")
    manifest = []
    for name, fn in SCENES.items():
        print("scene:", name)
        data = stringify_fileids(extract_scene(name, fn))
        json.dump(data, open(os.path.join(DATA, name + ".json"), "w"), indent=1, ensure_ascii=False)
        manifest.append(name)
        print(f"  sprites={len(data['sprites'])} hotspots={len(data['hotspots'])} "
              f"markers={len(data['markers'])} navPolys={len(data['navPolys'])} "
              f"actionLists={len(data['actionLists'])} onStart={data['onStart']}")
    json.dump({"scenes": manifest, "start": "Office"},
              open(os.path.join(DATA, "manifest.json"), "w"), indent=1)
    print("done. assets copied:", len(os.listdir(ASSET_OUT)))

if __name__ == "__main__":
    main()
