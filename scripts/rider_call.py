#!/usr/bin/env python3
"""Call RiderMCP tools in one initialized streamable-HTTP session."""

from __future__ import annotations

import argparse
import sys

from mcp_common import McpClient, McpFailure, parse_json_object, render_result

DEFAULT_URL = "http://127.0.0.1:64482/stream"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Call one RiderMCP tool in an initialized session.")
    parser.add_argument("call", help='JSON object: {"name":"<tool>","arguments":{...}}')
    parser.add_argument("--url", default=DEFAULT_URL, help=f"MCP endpoint (default: {DEFAULT_URL})")
    parser.add_argument("--timeout", type=float, default=120.0, help="request timeout in seconds")
    parser.add_argument("--allow-remote", action="store_true", help="allow a non-loopback endpoint; requires explicit user authorization")
    return parser


def main(argv: list[str] | None = None) -> int:
    ns = build_parser().parse_args(argv)
    try:
        call = parse_json_object(ns.call, "call")
        name = call.get("name")
        arguments = call.get("arguments", {})
        if not isinstance(name, str) or not name.strip():
            raise McpFailure("call.name must be a non-empty string", 2)
        if not isinstance(arguments, dict):
            raise McpFailure("call.arguments must be a JSON object", 2)
        client = McpClient(ns.url, ns.timeout, "ue-engineering-loop-rider", allow_remote=ns.allow_remote)
        client.initialize()
        result = client.call_tool(name, arguments)
        print(render_result(result))
        return 0
    except McpFailure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
