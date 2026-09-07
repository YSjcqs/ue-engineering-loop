#!/usr/bin/env python3
"""Call UE ModelContextProtocol tools with strict error handling."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from mcp_common import (
    EXIT_PROTOCOL,
    EXIT_USAGE,
    McpClient,
    McpFailure,
    atomic_write_text,
    parse_json_object,
    render_result,
)

DEFAULT_URL = "http://127.0.0.1:8000/mcp"
CATALOG_PATH = Path(__file__).with_name("mcp_catalog.json")


def resolve_toolset(
    short_name: str | None,
    catalog_path: Path = CATALOG_PATH,
    allow_stale_catalog: bool = False,
) -> str | None:
    if not short_name or short_name == "-":
        return None
    if "." in short_name:
        return short_name
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise McpFailure(f"cannot read MCP catalog {catalog_path}: {exc}", EXIT_PROTOCOL) from exc

    if not isinstance(catalog, dict) or not isinstance(catalog.get("toolsets"), list):
        raise McpFailure(f"invalid MCP catalog root: {catalog_path}", EXIT_PROTOCOL)
    if catalog.get("provenance_complete") is not True and not allow_stale_catalog:
        raise McpFailure(
            "catalog provenance is incomplete; use a fully-qualified toolset name or regenerate the catalog with version metadata",
            EXIT_PROTOCOL,
        )
    if any(not isinstance(item, dict) for item in catalog["toolsets"]):
        raise McpFailure(f"invalid toolset entry in catalog: {catalog_path}", EXIT_PROTOCOL)
    names = [str(item.get("name", "")) for item in catalog["toolsets"] if item.get("name")]
    exact = [name for name in names if name == short_name]
    suffix = [name for name in names if name.endswith("." + short_name)]
    prefix = [name for name in names if name.startswith(short_name + ".")]
    matches = exact or suffix or prefix
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise McpFailure(f"toolset not found in catalog: {short_name}", EXIT_USAGE)
    raise McpFailure(f"ambiguous toolset {short_name!r}: {', '.join(sorted(matches))}", EXIT_USAGE)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Call a UE MCP tool in one initialized session.")
    parser.add_argument("toolset", help="short/full toolset name, or '-' for a top-level tool")
    parser.add_argument("tool", help="tool name")
    parser.add_argument("arguments", nargs="?", default="{}", help="JSON object arguments")
    parser.add_argument("output", nargs="?", help="optional output file")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"MCP endpoint (default: {DEFAULT_URL})")
    parser.add_argument("--timeout", type=float, default=120.0, help="request timeout in seconds")
    parser.add_argument("--allow-remote", action="store_true", help="allow a non-loopback endpoint; requires explicit user authorization")
    parser.add_argument("--catalog", type=Path, default=CATALOG_PATH, help="toolset catalog path")
    parser.add_argument("--allow-stale-catalog", action="store_true", help="permit short-name resolution from incomplete provenance; requires explicit risk acceptance")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    ns = parser.parse_args(argv)
    try:
        arguments = parse_json_object(ns.arguments, "arguments")
        toolset = resolve_toolset(ns.toolset, ns.catalog, ns.allow_stale_catalog)
        client = McpClient(ns.url, ns.timeout, "ue-engineering-loop-ue", allow_remote=ns.allow_remote)
        client.initialize()
        if toolset:
            result = client.call_tool(
                "call_tool",
                {"toolset_name": toolset, "tool_name": ns.tool, "arguments": arguments},
            )
        else:
            result = client.call_tool(ns.tool, arguments)
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
