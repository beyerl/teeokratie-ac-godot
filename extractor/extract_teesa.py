#!/usr/bin/env python3
"""Extract Teesa's sprite-sheet animations (Unity .anim + sprite sheet) into a
Godot-friendly teesa.json + copy the sheet texture.

- Teesa.png is a 6x5 grid of 40x80 frames (PPU 32), sprites named "Teesa 0..29".
- Each Unity .anim (Walk/Idle/Talk x D/L/R/U) is an ordered list of sprite frame
  references (by fileID). We map fileID -> name (internalIDToNameTable) -> rect
  (spriteSheet.sprites), and emit each animation as a list of top-left pixel rects.
"""
import os, json, shutil, re
import yaml as _yaml

BASE = "/home/lorenz/Dokumente/Game Design/Development/Teeokratie"
TEESA = os.path.join(BASE, "Assets/Teeokratie/Graphics/Sprites/Characters/Teesa")
OUT = os.path.join(os.path.dirname(__file__), "..", "game")
DATA = os.path.join(OUT, "data")
ASSET_OUT = os.path.join(OUT, "assets")

ANIMS = {
    "walk_down": "Teesa_Walk_D.anim", "walk_up": "Teesa_Walk_U.anim",
    "walk_left": "Teesa_Walk_L.anim", "walk_right": "Teesa_Walk_R.anim",
    "idle_down": "Teesa_Idle_D.anim", "idle_up": "Teesa_Idle_U.anim",
    "idle_left": "Teesa_Idle_L.anim", "idle_right": "Teesa_Idle_R.anim",
    "talk_down": "Teesa_Talk_D.anim", "talk_up": "Teesa_Talk_U.anim",
    "talk_left": "Teesa_Talk_L.anim", "talk_right": "Teesa_Talk_R.anim",
}

class _L(_yaml.SafeLoader):
    pass
_L.add_multi_constructor("tag:unity3d.com,2011:", lambda l, s, n:
    l.construct_mapping(n) if isinstance(n, _yaml.MappingNode)
    else (l.construct_sequence(n) if isinstance(n, _yaml.SequenceNode) else l.construct_scalar(n)))

def load_yaml(path):
    txt = open(path, errors="replace").read()
    # strip the "--- !u!NN &id" doc headers into plain docs
    txt = re.sub(r'^--- !u!\d+ &\d+.*$', '---', txt, flags=re.M)
    docs = [d for d in _yaml.load_all(txt, Loader=_L) if isinstance(d, dict)]
    return docs

def sheet_maps():
    metas = load_yaml(os.path.join(TEESA, "Teesa.png.meta"))
    meta = metas[0]
    ti = meta.get("TextureImporter", meta)
    # fileID -> name
    id2name = {}
    for e in ti.get("internalIDToNameTable", []) or []:
        first = e.get("first", {})
        fid = None
        for _k, v in first.items():
            fid = str(v)
        if fid is not None:
            id2name[fid] = e.get("second")
    # name -> rect (top-left)
    img_h = 400
    name2rect = {}
    for s in (ti.get("spriteSheet", {}) or {}).get("sprites", []) or []:
        r = s.get("rect", {})
        x, y, w, h = float(r.get("x",0)), float(r.get("y",0)), float(r.get("width",0)), float(r.get("height",0))
        name2rect[s.get("name")] = [round(x), round(img_h - y - h), round(w), round(h)]
    return id2name, name2rect

def anim_frames(path, id2name, name2rect):
    docs = load_yaml(path)
    clip = None
    for d in docs:
        dd = d.get("AnimationClip", d) if isinstance(d, dict) else d
        if isinstance(dd, dict) and ("m_PPtrCurves" in dd or "m_Name" in dd):
            clip = dd
            if "m_PPtrCurves" in dd:
                break
    if not clip:
        return [], 12.0
    frames = []
    times = []
    curves = clip.get("m_PPtrCurves", []) or []
    for cur in curves:
        for kf in cur.get("curve", []) or []:
            val = kf.get("value", {})
            fid = str(val.get("fileID", ""))
            name = id2name.get(fid)
            rect = name2rect.get(name)
            if rect:
                frames.append(rect)
                times.append(float(kf.get("time", 0)))
        if frames:
            break
    # derive playback fps from keyframe spacing (Unity m_SampleRate is not the fps)
    fps = 8.0
    if len(times) >= 2 and times[-1] > times[0]:
        fps = (len(times) - 1) / (times[-1] - times[0])
    fps = max(1.0, min(fps, 24.0))
    return frames, round(fps, 2)

def main():
    os.makedirs(DATA, exist_ok=True); os.makedirs(ASSET_OUT, exist_ok=True)
    id2name, name2rect = sheet_maps()
    print("sprites:", len(name2rect), "id-map:", len(id2name))
    shutil.copy2(os.path.join(TEESA, "Teesa.png"), os.path.join(ASSET_OUT, "Teesa.png"))
    out = {"texture": "res://assets/Teesa.png", "frameSize": [40, 80], "anims": {}, "fps": {}}
    for key, fn in ANIMS.items():
        p = os.path.join(TEESA, fn)
        if not os.path.exists(p):
            continue
        frames, sample = anim_frames(p, id2name, name2rect)
        out["anims"][key] = frames
        out["fps"][key] = sample
        print(f"  {key:12s} {len(frames)} frames @ {sample}fps")
    json.dump(out, open(os.path.join(DATA, "teesa.json"), "w"), indent=1)
    print("wrote teesa.json")

if __name__ == "__main__":
    main()
