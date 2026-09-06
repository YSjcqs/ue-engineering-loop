#!/usr/bin/env python3
# dump_mcp_catalog.py - Regenerate mcp_catalog.json from a live UE 5.8 engine MCP
# server (UnrealEngineMCP at http://127.0.0.1:8000/mcp by default).
#
# WHY THIS EXISTS: mcp_catalog.json (2.3 MB snapshot of 52 toolsets / 830 tools)
# is a runtime dependency for mcp_call.py (it resolves short toolset prefixes
# to fully-qualified names). The catalog is version-bound — UE upgrades or
# AllToolsets plugin updates will change the toolset list. Without a way to
# regenerate it, the snapshot silently drifts and mcp_call.py starts failing
# to resolve toolsets that no longer exist or misses new ones.
#
# Usage:
#   python dump_mcp_catalog.py                         # default endpoint, write next to this script
#   python dump_mcp_catalog.py --url http://...:8000/mcp --out catalog.json
#   python dump_mcp_catalog.py --pretty                # pretty-print (slower, larger file)
#
# Prerequisites:
#   1. Engine running with ModelContextProtocol + AllToolsets plugins enabled
#   2. AutoStart on (Editor Preferences > General > Model Context Protocol)
#   3. Port 8000 reachable (curl http://127.0.0.1:8000/mcp -> 200/405)
#      See references/MCP_CHANNELS.md §5 connection troubleshooting tree.
#
# Output format (matches mcp_call.py expectations):
#   {
#     "server": "http://127.0.0.1:8000/mcp",
#     "toolset_count": <N>,
#     "toolsets": [
#       {"name": "<full.toolset.name>", "tool_count": <M>, "tools": [<tool names>]}
#     ]
#   }
#
# Exit codes:
#   0 = catalog written successfully
#   1 = connection / handshake failure
#   2 = toolset list empty (AllToolsets not enabled? see MCP_CHANNELS.md §6.3)
#   3 = I/O error writing output
import argparse
import json
import sys
import urllib.request

DEFAULT_URL = "http://127.0.0.1:8000/mcp"
DEFAULT_OUT = None  # resolved to mcp_catalog.json next to this script


def rpc(base, payload, session=None, timeout=30):
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(
        base,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    resp = urllib.request.urlopen(req, timeout=timeout)
    body = resp.read().decode("utf-8", "replace")
    ctype = resp.headers.get("Content-Type", "")
    sid = resp.headers.get("Mcp-Session-Id")
    return sid, body, ctype


def parse_obj(body, ctype):
    """Parse JSON-RPC response, handling text/event-stream framing."""
    if "text/event-stream" in ctype:
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                d = line[len("data:"):].strip()
                try:
                    obj = json.loads(d)
                    if "result" in obj or "error" in obj:
                        return obj
                except Exception:
                    pass
        return None
    try:
        return json.loads(body)
    except Exception:
        return None


def init(base):
    """Perform MCP handshake (initialize -> notifications/initialized)."""
    sid, body, ctype = rpc(
        base,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "dump_mcp_catalog", "version": "1.0"},
            },
        },
    )
    rpc(base, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, sid)
    return sid


def list_toolsets(base, sid):
    """Call list_toolsets meta-tool, return list of toolset names."""
    _, body, ctype = rpc(
        base,
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "list_toolsets", "arguments": {}},
        },
        sid,
    )
    obj = parse_obj(body, ctype)
    if obj is None:
        return {"_error": "no-parse", "raw": body[:500]}
    if "error" in obj:
        return {"_error": obj["error"]}
    res = obj.get("result", {})
    texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
    joined = "\n".join(texts)
    return joined


def describe_toolset(base, sid, toolset_name):
    """Call describe_toolset meta-tool for a single toolset, return its tools."""
    _, body, ctype = rpc(
        base,
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "describe_toolset",
                "arguments": {"toolset_name": toolset_name},
            },
        },
        sid,
    )
    obj = parse_obj(body, ctype)
    if obj is None:
        return []
    if "error" in obj:
        return []
    res = obj.get("result", {})
    texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
    joined = "\n".join(texts)
    # Try to parse as JSON first (structured), else extract tool names heuristically
    try:
        data = json.loads(joined)
        if isinstance(data, dict) and "tools" in data:
            return [t.get("name", "") if isinstance(t, dict) else str(t) for t in data["tools"]]
        if isinstance(data, list):
            return [t.get("name", "") if isinstance(t, dict) else str(t) for t in data]
    except Exception:
        pass
    # Heuristic: split by lines, take non-empty stripped lines
    return [ln.strip() for ln in joined.splitlines() if ln.strip()]


def main():
    parser = argparse.ArgumentParser(description="Regenerate mcp_catalog.json from a live UE 5.8 engine MCP server.")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"MCP endpoint URL (default: {DEFAULT_URL})")
    parser.add_argument("--out", default=DEFAULT_OUT, help="Output file path (default: mcp_catalog.json next to this script)")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output (larger file)")
    args = parser.parse_args()

    # Resolve default output path next to this script
    import os
    out_path = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_catalog.json")

    print(f"[1/4] Handshake with {args.url} ...")
    try:
        sid = init(args.url)
    except Exception as e:
        print(f"ERROR: handshake failed: {e}", file=sys.stderr)
        print("       Check: engine running? plugins enabled? port 8000 listening?", file=sys.stderr)
        print("       See references/MCP_CHANNELS.md §5 connection troubleshooting tree.", file=sys.stderr)
        return 1

    print(f"[2/4] Listing toolsets ...")
    raw = list_toolsets(args.url, sid)
    if isinstance(raw, dict) and "_error" in raw:
        print(f"ERROR: list_toolsets failed: {raw['_error']}", file=sys.stderr)
        return 1

    # Parse toolset names from response
    toolset_names = []
    if isinstance(raw, str):
        # Try JSON first
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                toolset_names = [t if isinstance(t, str) else t.get("name", "") for t in data]
            elif isinstance(data, dict) and "toolsets" in data:
                toolset_names = [t.get("name", "") for t in data["toolsets"]]
        except Exception:
            pass
        if not toolset_names:
            # Heuristic: each non-empty stripped line is a toolset name
            toolset_names = [ln.strip() for ln in raw.splitlines() if ln.strip()]

    if not toolset_names:
        print("ERROR: no toolsets returned. AllToolsets plugin enabled? See MCP_CHANNELS.md §6.3.", file=sys.stderr)
        return 2

    print(f"      Found {len(toolset_names)} toolset(s).")

    print(f"[3/4] Describing each toolset (this may take a while for 52 toolsets) ...")
    catalog = {
        "server": args.url,
        "toolset_count": len(toolset_names),
        "toolsets": [],
    }
    for i, name in enumerate(toolset_names, 1):
        tools = describe_toolset(args.url, sid, name)
        catalog["toolsets"].append({
            "name": name,
            "tool_count": len(tools),
            "tools": tools,
        })
        if i % 5 == 0 or i == len(toolset_names):
            print(f"      [{i}/{len(toolset_names)}] {name} ({len(tools)} tools)")

    print(f"[4/4] Writing catalog to {out_path} ...")
    try:
        indent = 2 if args.pretty else None
        with open(out_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(catalog, f, ensure_ascii=False, indent=indent)
    except Exception as e:
        print(f"ERROR: failed to write output: {e}", file=sys.stderr)
        return 3

    total_tools = sum(t["tool_count"] for t in catalog["toolsets"])
    print(f"\nOK: catalog written.")
    print(f"    {catalog['toolset_count']} toolsets, {total_tools} tools total.")
    print(f"    Server: {args.url}")
    print(f"    File:   {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())