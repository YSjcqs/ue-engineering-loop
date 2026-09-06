import json, sys, time, urllib.request

URL = "http://127.0.0.1:3939/mcp"
SID = [None]

def rpc(payload):
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if SID[0]:
        headers["Mcp-Session-Id"] = SID[0]
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

def call(tool, args=None, ts=None, rid=2):
    if ts and ts != "-":
        # route through call_tool meta-tool (toolset tool)
        params = {"name": "call_tool", "arguments": {
            "toolset_name": ts, "tool_name": tool, "arguments": args or {}}}
    else:
        # top-level meta tool (list_toolsets / describe_toolset / call_tool)
        params = {"name": tool, "arguments": args or {}}
    body, ctype = rpc({"jsonrpc":"2.0","id":rid,"method":"tools/call","params":params})
    obj = parse_obj(body, ctype)
    if obj is None: return {"_error": "no-parse", "raw": body[:500]}
    if "error" in obj: return {"_error": obj["error"]}
    res = obj.get("result", {})
    texts = [c.get("text","") for c in res.get("content",[]) if c.get("type")=="text"]
    return "\n".join(texts)

if __name__ == "__main__":
    # python wb_call.py <toolset|- > <tool> '<json args>' [outfile]
    ts = None if sys.argv[1] == "-" else sys.argv[1]
    tool = sys.argv[2]
    a = json.loads(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] != "{}" else {}
    out = sys.argv[4] if len(sys.argv) > 4 else None
    init()
    r = call(tool, a, ts)
    text = r if isinstance(r, str) else json.dumps(r, ensure_ascii=False, indent=2)
    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {len(text)} chars -> {out}")
    else:
        print(text)
