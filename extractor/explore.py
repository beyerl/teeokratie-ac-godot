import sys, json, os
sys.path.insert(0, os.path.dirname(__file__))
import uyaml, re

BASE="/home/lorenz/Dokumente/Game Design/Development/Teeokratie"
ASSETS=os.path.join(BASE,"Assets")

# guid -> class name (from .cs.meta)
guid_re=re.compile(r'guid:\s*([0-9a-f]{32})')
def guidmap():
    m={}
    for root,_,fs in os.walk(ASSETS):
        for f in fs:
            if f.endswith('.cs.meta'):
                t=open(os.path.join(root,f),errors='replace').read()
                g=guid_re.search(t)
                if g: m[g.group(1)]=os.path.splitext(f[:-5])[0]
    return m

GM=guidmap()
objs=uyaml.load(os.path.join(ASSETS,"TeaistCloisterOffice.unity"))

def cls_of(mb):
    s=mb["data"].get("m_Script") or {}
    g=s.get("guid")
    return GM.get(g, f"?{g}")

# index GameObjects and their component MBs
def go_name(fid):
    o=objs.get(fid)
    if not o: return None
    return o["data"].get("m_Name")

# find hotspot MBs
for fid,o in objs.items():
    if o["type"]=="MonoBehaviour" and cls_of(o)=="Hotspot":
        d=o["data"]
        goid=(d.get("m_GameObject") or {}).get("fileID")
        print("=== HOTSPOT on GameObject:", go_name(str(goid)), " fid",fid)
        # print keys of interest
        for k in ("useButtons","lookButton","useButton","invButton","unhandledInvButtons",
                  "interactions","provideUseInteraction","provideLookInteraction","displayLineID"):
            if k in d: print("   ",k,"=",json.dumps(d[k])[:300])
        break

# dump one Interaction (ActionList) fully with resolved action classes
def dump_actionlist(fid, label=""):
    o=objs.get(str(fid))
    if not o:
        print("  (no obj for",fid,")"); return
    d=o["data"]
    acts=d.get("actions") or []
    print(f"--- ActionList {label} fid={fid} name={d.get('m_Name')} type={cls_of(o)} nActions={len(acts)}")
    for i,a in enumerate(acts):
        aid=str((a or {}).get("fileID"))
        ao=objs.get(aid)
        if not ao:
            print(f"   [{i}] MISSING {aid}"); continue
        acls=cls_of(ao)
        ad=ao["data"]
        flow={k:ad.get(k) for k in ("endAction","skipAction","resultActionTrue","resultActionFail","skipActionTrue","skipActionFail") if k in ad}
        print(f"   [{i}] {acls} flow={flow}")

# find a GameObject named Bookshelve, list its component MBs
for fid,o in objs.items():
    if o["type"]=="GameObject" and o["data"].get("m_Name")=="Bookshelve":
        comps=o["data"].get("m_Component") or []
        print("\n=== Bookshelve components ===")
        for c in comps:
            cf=str((c.get("component") or {}).get("fileID"))
            co=objs.get(cf)
            if co:
                t=co["type"]
                extra=cls_of(co) if t=="MonoBehaviour" else ""
                print("   ",t,extra)
