#!/usr/bin/env python3
"""Call Workbench desktop MCP tools with strict error handling."""

from __future__ import annotations

import argparse
import sys

from mcp_common import McpClient, McpFailure, atomic_write_text, parse_json_object, render_result

DEFAULT_URL = "http://127.0.0.1:3939/mcp"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Call a Workbench MCP tool in one initialized session.")
    parser.add_argument("toolset", help="full toolset name, or '-' for a top-level tool")
    parser.add_argument("tool", help="tool name")
    parser.add_argument("arguments", nargs="?", default="{}", help="JSON object arguments")
    parser.add_argument("output", nargs="?", help="optional output file")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"MCP endpoint (default: {DEFAULT_URL})")
    parser.add_argument("--timeout", type=float, default=120.0, help="request timeout in seconds")
    parser.add_argument("--allow-remote", action="store_true", help="allow a non-loopback endpoint; requires explicit user authorization")
    return parser


def main(argv: list[str] | None = None) -> int:
    ns = build_parser().parse_args(argv)
    try:
        arguments = parse_json_object(ns.arguments, "arguments")
        client = McpClient(ns.url, ns.timeout, "ue-engineering-loop-workbench", allow_remote=ns.allow_remote)
        client.initialize()
        if ns.toolset == "-":
            result = client.call_tool(ns.tool, arguments)
        else:
            result = client.call_tool(
                "call_tool",
                {"toolset_name": ns.toolset, "tool_name": ns.tool, "arguments": arguments},
            )
        text = render_result(result)
        if ns.output:
            atomic_write_text(ns.output, text)
            print(f"wrote {len(text)} chars to {ns.output}")
        else:
            print(text)
        return 0
    except McpFailure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
