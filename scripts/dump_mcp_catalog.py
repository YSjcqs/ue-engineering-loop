#!/usr/bin/env python3
"""Regenerate mcp_catalog.json atomically from a live UE MCP server."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from mcp_common import McpClient, McpFailure, atomic_write_text, render_result, validate_url

DEFAULT_URL = "http://127.0.0.1:8000/mcp"
SCHEMA_VERSION = 2


def parse_embedded_json(result: dict[str, Any], label: str) -> Any:
    text = render_result(result)
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise McpFailure(f"{label} did not return JSON: {exc}; preview={text[:300]!r}", 4) from exc


def normalize_toolset_names(data: Any) -> list[str]:
    if isinstance(data, dict):
        data = data.get("toolsets", data.get("items", []))
    if not isinstance(data, list):
        raise McpFailure("list_toolsets response is not a list", 4)
    names: list[str] = []
    for item in data:
        name = item if isinstance(item, str) else item.get("name") if isinstance(item, dict) else None
        if not isinstance(name, str) or not name.strip():
            raise McpFailure("list_toolsets contains an empty/invalid name", 4)
        names.append(name.strip())
    if len(names) != len(set(names)):
        raise McpFailure("list_toolsets contains duplicate names", 4)
    return sorted(names)


def normalize_toolset(data: Any, expected_name: str) -> dict[str, Any]:
    if isinstance(data, list):
        data = {"name": expected_name, "description": "", "tools": data}
    if not isinstance(data, dict):
        raise McpFailure(f"describe_toolset({expected_name}) returned a non-object", 4)
    returned_name = str(data.get("name") or expected_name)
    if returned_name != expected_name:
        raise McpFailure(
            f"describe_toolset name mismatch: requested {expected_name!r}, got {returned_name!r}",
            4,
        )
    tools = data.get("tools")
    if not isinstance(tools, list):
        raise McpFailure(f"describe_toolset({expected_name}) has no tools array", 4)
    normalized_tools: list[dict[str, Any]] = []
    names: set[str] = set()
    for item in tools:
        if isinstance(item, str):
            item = {"name": item}
        if not isinstance(item, dict) or not isinstance(item.get("name"), str) or not item["name"].strip():
            raise McpFailure(f"describe_toolset({expected_name}) contains an invalid tool", 4)
        if item["name"] in names:
            raise McpFailure(f"describe_toolset({expected_name}) contains duplicate tool {item['name']}", 4)
        names.add(item["name"])
        normalized_tools.append(item)
    normalized_tools.sort(key=lambda item: item["name"])
    return {
        "name": returned_name,
        "description": str(data.get("description") or ""),
        "tool_count": len(normalized_tools),
        "tools": normalized_tools,
    }


def validate_catalog(catalog: dict[str, Any]) -> None:
    if catalog.get("schema_version") != SCHEMA_VERSION:
        raise McpFailure(f"catalog schema_version must be {SCHEMA_VERSION}", 4)
    for field in (
        "schema_version",
        "generated_at_utc",
        "protocol_version",
        "producer",
        "provenance_source",
        "engine_version",
        "model_context_protocol_version",
        "all_toolsets_version",
    ):
        if field not in catalog or catalog[field] in (None, ""):
            raise McpFailure(f"catalog missing provenance field: {field}", 4)
    if catalog.get("provenance_complete") is not True:
        raise McpFailure("generated catalog provenance must be complete", 4)
    for field in ("engine_version", "model_context_protocol_version", "all_toolsets_version"):
        if str(catalog.get(field)).strip().lower() == "unknown":
            raise McpFailure(f"generated catalog provenance cannot be unknown: {field}", 4)
    toolsets = catalog.get("toolsets")
    if not isinstance(toolsets, list) or not toolsets:
        raise McpFailure("catalog has no toolsets", 4)
    names = [item.get("name") for item in toolsets]
    if any(not isinstance(name, str) or not name for name in names):
        raise McpFailure("catalog contains an invalid toolset name", 4)
    if len(names) != len(set(names)):
        raise McpFailure("catalog contains duplicate toolsets", 4)
    if catalog.get("toolset_count") != len(toolsets):
        raise McpFailure("catalog toolset_count mismatch", 4)
    actual_tools = 0
    for item in toolsets:
        tools = item.get("tools")
        if not isinstance(tools, list) or item.get("tool_count") != len(tools):
            raise McpFailure(f"catalog tool_count mismatch: {item.get('name')}", 4)
        tool_names: set[str] = set()
        for tool in tools:
            if not isinstance(tool, dict) or not isinstance(tool.get("name"), str) or not tool["name"]:
                raise McpFailure(f"catalog contains an invalid tool in {item.get('name')}", 4)
            if tool["name"] in tool_names:
                raise McpFailure(f"catalog contains duplicate tool {tool['name']} in {item.get('name')}", 4)
            if not isinstance(tool.get("inputSchema"), dict):
                raise McpFailure(f"catalog tool missing object inputSchema: {tool['name']}", 4)
            tool_names.add(tool["name"])
        actual_tools += len(tools)
    if catalog.get("total_tool_count") != actual_tools:
        raise McpFailure("catalog total_tool_count mismatch", 4)
    canonical = json.dumps(toolsets, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()
    if catalog.get("toolset_digest_sha256") != digest:
        raise McpFailure("catalog toolset_digest_sha256 mismatch", 4)


@contextlib.contextmanager
def output_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+b")
    locked = False
    try:
        if handle.seek(0, os.SEEK_END) == 0:
            handle.write(b"0")
            handle.flush()
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
        except (OSError, BlockingIOError) as exc:
            raise McpFailure(f"catalog generation already in progress: {path}", 6) from exc
        handle.seek(0)
        handle.truncate()
        handle.write((str(os.getpid()) + "\n").encode("ascii"))
        handle.flush()
        yield
    finally:
        if locked:
            handle.seek(0)
            try:
                if os.name == "nt":
                    import msvcrt

                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        handle.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Regenerate the UE MCP toolset catalog.")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"MCP endpoint (default: {DEFAULT_URL})")
    parser.add_argument("--out", type=Path, default=Path(__file__).with_name("mcp_catalog.json"))
    parser.add_argument("--timeout", type=float, default=30.0, help="per-request timeout in seconds")
    parser.add_argument("--allow-remote", action="store_true", help="allow a non-loopback endpoint; requires explicit user authorization")
    parser.add_argument("--engine-version", required=True, help="engine version and changelist/commit for provenance")
    parser.add_argument("--mcp-plugin-version", required=True, help="ModelContextProtocol plugin version")
    parser.add_argument("--toolsets-plugin-version", required=True, help="AllToolsets plugin version")
    parser.add_argument("--pretty", action="store_true", help="pretty-print JSON")
    return parser


def generate_catalog(ns: argparse.Namespace) -> int:
    validate_url(ns.url, ns.allow_remote)
    client = McpClient(ns.url, ns.timeout, "ue-engineering-loop-catalog", allow_remote=ns.allow_remote)
    print(f"[1/4] Handshake with {ns.url}")
    init_result = client.initialize()

    print("[2/4] Listing toolsets")
    list_data = parse_embedded_json(client.call_tool("list_toolsets", {}), "list_toolsets")
    names = normalize_toolset_names(list_data)
    if not names:
        print("ERROR: no toolsets returned; verify AllToolsets is enabled", file=sys.stderr)
        return 2

    print(f"[3/4] Describing {len(names)} toolsets")
    toolsets: list[dict[str, Any]] = []
    for index, name in enumerate(names, 1):
        data = parse_embedded_json(
            client.call_tool("describe_toolset", {"toolset_name": name}),
            f"describe_toolset({name})",
        )
        toolset = normalize_toolset(data, name)
        toolsets.append(toolset)
        if index % 5 == 0 or index == len(names):
            print(f"  [{index}/{len(names)}] {name} ({toolset['tool_count']} tools)")

    end_list_data = parse_embedded_json(client.call_tool("list_toolsets", {}), "final list_toolsets")
    end_names = normalize_toolset_names(end_list_data)
    if end_names != names:
        raise McpFailure("toolset list changed during catalog generation; refusing mixed snapshot", 4)

    canonical_toolsets = json.dumps(toolsets, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    toolset_digest = hashlib.sha256(canonical_toolsets).hexdigest()
    catalog = {
        "schema_version": SCHEMA_VERSION,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "protocol_version": init_result.get("protocolVersion"),
        "server": ns.url,
        "server_info": init_result.get("serverInfo"),
        "producer": "dump_mcp_catalog.py/1.1",
        "provenance_source": "operator-supplied versions plus MCP initialize serverInfo",
        "engine_version": ns.engine_version,
        "model_context_protocol_version": ns.mcp_plugin_version,
        "all_toolsets_version": ns.toolsets_plugin_version,
        "provenance_complete": True,
        "toolset_digest_sha256": toolset_digest,
        "toolset_count": len(toolsets),
        "total_tool_count": sum(item["tool_count"] for item in toolsets),
        "toolsets": toolsets,
    }
    validate_catalog(catalog)

    print(f"[4/4] Validating and atomically writing {ns.out}")
    indent = 2 if ns.pretty else None
    text = json.dumps(catalog, ensure_ascii=False, indent=indent) + "\n"
    atomic_write_text(ns.out, text)
    print(f"OK: {catalog['toolset_count']} toolsets, {catalog['total_tool_count']} tools")
    return 0


def main(argv: list[str] | None = None) -> int:
    ns = build_parser().parse_args(argv)
    ns.out = ns.out.expanduser().resolve()
    lock_path = ns.out.with_suffix(ns.out.suffix + ".lock")
    try:
        with output_lock(lock_path):
            return generate_catalog(ns)
    except McpFailure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return exc.exit_code
    except OSError as exc:
        print(f"ERROR: output I/O failed: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
