import json, sys, urllib.request

URL = "http://127.0.0.1:8000/mcp"
SID = [None]

def rpc(payload):
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if SID[0]: headers["Mcp-Session-Id"] = SID[0]
    req = urllib.request.Request(URL, data=data, headers=headers, method="POST")
    resp = urllib.request.urlopen(req, timeout=120)
    body = resp.read().decode("utf-8", "replace")
    ctype = resp.headers.get("Content-Type", "")
    sid = resp.headers.get("Mcp-Session-Id")
    if sid: SID[0] = sid
    return body, ctype

def parse_obj(body, ctype):
    if "text/event-stream" in ctype:
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                d = line[len("data:"):].strip()
                try:
                    obj = json.loads(d)
                    if "result" in obj or "error" in obj: return obj
                except Exception: pass
        return None
    try: return json.loads(body)
    except Exception: return None

def init():
    body, ctype = rpc({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"1"}}})
    rpc({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})
    return parse_obj(body, ctype)

import os
_CAT = None
def _resolve_ts(ts):
    global _CAT
    if ts is None or ts == "-":
        return None
    if "." in ts:  # already fully qualified
        return ts
    # resolve short prefix -> full name from catalog
    try:
        if _CAT is None:
            with open(os.path.join(os.path.dirname(__file__), "mcp_catalog.json"), encoding="utf-8") as f:
                _CAT = json.load(f)
        for t in _CAT["toolsets"]:
            n = t["name"]
            if n == ts or n.startswith(ts + ".") or n.endswith("." + ts) or n == ts:
                return n
        # fallback: first contains
        for t in _CAT["toolsets"]:
            if ts in t["name"]:
                return t["name"]
    except Exception:
        pass
    return ts

def call(tool, args=None, ts=None, rid=2):
    fts = _resolve_ts(ts)
    if fts:
        # route through the call_tool meta-tool: toolset tool
        params = {"name": "call_tool", "arguments": {
            "toolset_name": fts, "tool_name": tool, "arguments": args or {}}}
    else:
        params = {"name": tool, "arguments": args or {}}
    body, ctype = rpc({"jsonrpc":"2.0","id":rid,"method":"tools/call","params":params})
    obj = parse_obj(body, ctype)
    if obj is None: return {"_error": "no-parse", "raw": body[:500]}
    if "error" in obj: return {"_error": obj["error"]}
    res = obj.get("result", {})
    texts = [c.get("text","") for c in res.get("content",[]) if c.get("type")=="text"]
    joined = "\n".join(texts)
    return joined

if __name__ == "__main__":
    # command: python mcp_call.py <toolset|-> <tool> '<json args>' [outfile]
    args = sys.argv[1:]
    ts = None if args[0] == "-" else args[0]
    tool = args[1]
    a = json.loads(args[2]) if len(args) > 2 else {}
    outfile = args[3] if len(args) > 3 else None
    init()
    out = call(tool, a, ts)
    text = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False, indent=2)
    if outfile:
        with open(outfile, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {len(text)} chars to {outfile}")
    else:
        print(text)
