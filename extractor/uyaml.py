"""Minimal Unity-YAML loader.

Unity serializes each object as a YAML document prefixed with a custom tag line:
    --- !u!114 &123456789
We register a multi-constructor so PyYAML ignores the `!u!<n>` tags, and we parse
the `&anchor` (fileID) from the document separator lines ourselves.

Returns: dict fileID(str) -> {"class": <unity_class_int>, "type": <top_key>, "data": <dict>}
"""
import re, yaml

class _Loader(yaml.SafeLoader):
    pass

def _construct_undefined(loader, tag_suffix, node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_scalar(node)

# Unity uses tags like tag:unity3d.com,2011:114 -> multi-constructor on that prefix.
_Loader.add_multi_constructor("tag:unity3d.com,2011:", _construct_undefined)
_Loader.add_multi_constructor("!u!", _construct_undefined)

_doc_re = re.compile(r'^--- !u!(\d+) &(\d+)(?:\s+stripped)?\s*$', re.M)

def load(path):
    txt = open(path, "r", errors="replace").read()
    # Split on document markers, capturing class + fileID.
    marks = list(_doc_re.finditer(txt))
    objs = {}
    for i, m in enumerate(marks):
        cls = int(m.group(1)); fid = m.group(2)
        start = m.end()
        end = marks[i+1].start() if i+1 < len(marks) else len(txt)
        body = txt[start:end]
        try:
            data = yaml.load(body, Loader=_Loader)
        except Exception as e:
            data = {"_parse_error": str(e)}
        if isinstance(data, dict) and len(data) == 1:
            topkey = next(iter(data))
            inner = data[topkey]
        else:
            topkey = None; inner = data
        objs[fid] = {"class": cls, "type": topkey, "data": inner if isinstance(inner, dict) else {}}
    return objs

if __name__ == "__main__":
    import sys, json
    objs = load(sys.argv[1])
    # summary
    from collections import Counter
    c = Counter(o["type"] for o in objs.values())
    print("docs:", len(objs))
    for k, n in c.most_common():
        print(f"  {n:>4} {k}")
