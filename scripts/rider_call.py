#!/usr/bin/env python3
# rider_call.py - Minimal MCP streamable-HTTP caller for the IDE build channel
# (RiderMCP, default http://127.0.0.1:64482/stream).
#
# Why this exists (2026-09实测): the MCP session does NOT survive across
# separate processes/connections ("Streamable HTTP session not found") --
# initialize + notifications/initialized + tools/call MUST run in ONE process.
# This script wraps that sequence so shell workflows can call RiderMCP tools:
#
#   python rider_call.py '{"name":"get_solution_projects","arguments":{"rootFolder":"F:/Unreal/Blank"}}'
#   python rider_call.py '{"name":"build_solution_state","arguments":{}}' 120
#
# Output: raw JSON-RPC response of the tools/call on stdout.
# Note: build_solution_start is ASYNC -- it returns a sessionId; poll
#       build_solution_state until state == "Completed" (see UE_BUILD_PITFALLS.md §1.5).
import json
import sys
import urllib.request

DEFAULT_BASE = "http://127.0.0.1:64482/stream"


def post(base, payload, session=None, timeout=120):
    req = urllib.request.Request(
        base,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            **({"mcp-session-id": session} if session else {}),
        },
    )
    resp = urllib.request.urlopen(req, timeout=timeout)
    return resp.headers.get("mcp-session-id"), resp.read().decode("utf-8", "replace")


def main():
    if len(sys.argv) < 2:
        print('usage: rider_call.py \'{"name":"<tool>","arguments":{...}}\' [timeout_ms]', file=sys.stderr)
        return 2
    base = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_BASE
    call = json.loads(sys.argv[1])
    timeout_ms = int(sys.argv[2]) if len(sys.argv) > 2 else 120000

    # 1) handshake (new session per process -- sessions do not survive across processes)
    sid, _ = post(base, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                    "clientInfo": {"name": "ue-engineering-loop", "version": "1.0"}}},
                  timeout=max(timeout_ms // 1000, 10))
    # 2) initialized notification
    post(base, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    # 3) tool call
    _, body = post(base, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": call},
                   sid, timeout=max(timeout_ms // 1000, 10))
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
