#!/usr/bin/env python3
"""Offline quality gate for ue-engineering-loop."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONCEPTUAL_SCRIPTS = {"script.ps1"}


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def validate_frontmatter(errors: list[str], path: Path | None = None) -> None:
    path = path or (ROOT / "SKILL.md")
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        fail(errors, "SKILL.md: frontmatter must start at byte 0")
        return
    end = text.find("\n---\n", 4)
    if end < 0:
        fail(errors, "SKILL.md: frontmatter closing delimiter missing")
        return
    front = text[4:end]
    keys = re.findall(r"(?m)^([A-Za-z_][A-Za-z0-9_-]*):", front)
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        fail(errors, "SKILL.md: duplicate frontmatter keys: " + ", ".join(duplicates))
    allowed = {"name", "description", "description_en", "version", "engine_version", "min_rider_version", "last_updated", "agent_created"}
    unknown = sorted(set(keys) - allowed)
    if unknown:
        fail(errors, "SKILL.md: unsupported frontmatter keys: " + ", ".join(unknown))
    required_patterns = {
        "name": r"(?m)^name:\s*ue-engineering-loop\s*$",
        "description": r"(?m)^description:\s*>-\s*$",
        "description_en": r"(?m)^description_en:\s*>-\s*$",
        "version": r"(?m)^version:\s*\"\d+\.\d+\.\d+\"\s*$",
        "last_updated": r"(?m)^last_updated:\s*\"\d{4}-\d{2}-\d{2}\"\s*$",
        "agent_created": r"(?m)^agent_created:\s*true\s*$",
    }
    for label, pattern in required_patterns.items():
        if not re.search(pattern, front):
            fail(errors, f"SKILL.md: missing/invalid frontmatter field {label}")
    date_match = re.search(r'(?m)^last_updated:\s*"(\d{4}-\d{2}-\d{2})"\s*$', front)
    if date_match:
        try:
            datetime.strptime(date_match.group(1), "%Y-%m-%d")
        except ValueError:
            fail(errors, "SKILL.md: last_updated is not a real calendar date")
    if "canonical_path:" in text:
        fail(errors, "SKILL.md: machine-specific canonical_path is forbidden")


def is_within_root(path: Path) -> bool:
    try:
        path.resolve().relative_to(ROOT.resolve())
        return True
    except ValueError:
        return False


def reference_candidates(source: Path, ref: str) -> list[Path]:
    ref = ref.split("#", 1)[0]
    return [source.parent / ref, ROOT / ref, ROOT / "references" / ref]


def resolve_reference(source: Path, ref: str) -> bool:
    return any(is_within_root(candidate) and candidate.exists() for candidate in reference_candidates(source, ref))


def validate_markdown_links(errors: list[str]) -> None:
    code_ref_pattern = re.compile(r"`([^`]+\.md(?:#[^`]*)?)`")
    markdown_link_pattern = re.compile(r"\[[^\]]+\]\(([^)]+\.md(?:#[^)]+)?)\)")
    script_pattern = re.compile(r"(?:^|[\s`(])((?:scripts/)?[A-Za-z0-9_.-]+\.(?:py|ps1))(?:[\s`)']|$)")
    section_pattern = re.compile(r"`([^`]+\.md)`\s*§([0-9]+(?:\.[0-9]+)?)")
    for path in ROOT.rglob("*.md"):
        text = path.read_text(encoding="utf-8")
        refs = set(code_ref_pattern.findall(text)) | set(markdown_link_pattern.findall(text))
        for ref in sorted(refs):
            if not resolve_reference(path, ref):
                fail(errors, f"{path.relative_to(ROOT)}: unresolved markdown reference `{ref}`")
        for ref, section in section_pattern.findall(text):
            targets = [candidate for candidate in reference_candidates(path, ref) if is_within_root(candidate) and candidate.exists()]
            if targets:
                target_text = targets[0].read_text(encoding="utf-8")
                heading = re.compile(rf"(?m)^#{{1,6}}\s+{re.escape(section)}(?:\s|[.·：:])")
                if not heading.search(target_text):
                    fail(errors, f"{path.relative_to(ROOT)}: missing section §{section} in `{ref}`")
        for script_ref in sorted(set(script_pattern.findall(text))):
            if script_ref in CONCEPTUAL_SCRIPTS:
                continue
            candidates = [
                ROOT / script_ref,
                ROOT / "scripts" / script_ref,
                ROOT / "tests" / script_ref,
            ]
            if not any(candidate.exists() for candidate in candidates):
                fail(errors, f"{path.relative_to(ROOT)}: unresolved script reference `{script_ref}`")


def validate_catalog(errors: list[str], path: Path | None = None) -> None:
    path = path or (ROOT / "scripts" / "mcp_catalog.json")
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(errors, f"mcp_catalog.json unreadable: {exc}")
        return
    if not isinstance(catalog, dict):
        fail(errors, "mcp_catalog.json: root must be an object")
        return
    if catalog.get("schema_version") != 2:
        fail(errors, "mcp_catalog.json: schema_version must be 2")
    for field in ("generated_at_utc", "protocol_version", "producer", "provenance_source", "engine_version", "model_context_protocol_version", "all_toolsets_version"):
        if field not in catalog or catalog[field] in (None, ""):
            fail(errors, f"mcp_catalog.json: missing provenance field {field}")
    if not isinstance(catalog.get("provenance_complete"), bool):
        fail(errors, "mcp_catalog.json: provenance_complete must be boolean")
    toolsets = catalog.get("toolsets")
    if not isinstance(toolsets, list) or not toolsets:
        fail(errors, "mcp_catalog.json: toolsets must be a non-empty array")
        return
    names = [item.get("name") for item in toolsets if isinstance(item, dict)]
    if len(names) != len(toolsets) or any(not isinstance(name, str) or not name for name in names):
        fail(errors, "mcp_catalog.json: invalid toolset name")
    if len(names) != len(set(names)):
        fail(errors, "mcp_catalog.json: duplicate toolset names")
    if catalog.get("toolset_count") != len(toolsets):
        fail(errors, "mcp_catalog.json: toolset_count mismatch")
    total = 0
    for item in toolsets:
        tools = item.get("tools") if isinstance(item, dict) else None
        if not isinstance(tools, list):
            fail(errors, f"mcp_catalog.json: {item.get('name') if isinstance(item, dict) else '?'} tools is not an array")
            continue
        if item.get("tool_count") != len(tools):
            fail(errors, f"mcp_catalog.json: {item.get('name')} tool_count mismatch")
        tool_names: list[str] = []
        for tool in tools:
            if not isinstance(tool, dict) or not isinstance(tool.get("name"), str) or not tool["name"]:
                fail(errors, f"mcp_catalog.json: {item.get('name')} has invalid tool entry")
                continue
            tool_names.append(tool["name"])
            if not isinstance(tool.get("inputSchema"), dict):
                fail(errors, f"mcp_catalog.json: {tool['name']} missing object inputSchema")
        if len(tool_names) != len(set(tool_names)):
            fail(errors, f"mcp_catalog.json: duplicate tools in {item.get('name')}")
        total += len(tools)
    if catalog.get("total_tool_count") != total:
        fail(errors, "mcp_catalog.json: total_tool_count mismatch")
    canonical = json.dumps(toolsets, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    digest = hashlib.sha256(canonical).hexdigest()
    if catalog.get("toolset_digest_sha256") != digest:
        fail(errors, "mcp_catalog.json: toolset_digest_sha256 mismatch")


def validate_taboo_ids(errors: list[str]) -> None:
    text = (ROOT / "references" / "TABOO_LIST.md").read_text(encoding="utf-8")
    section = text.split("## 完整 27 条", 1)[-1].split("## 计数与维护", 1)[0]
    ids = re.findall(r"\| `([A-Z]+(?:-[A-Z]+)*-\d{2})` \|", section)
    unique = set(ids)
    if len(unique) != 27:
        fail(errors, f"TABOO_LIST.md: expected 27 unique rule IDs, found {len(unique)}")


def validate_hygiene(errors: list[str]) -> None:
    forbidden = ["UnrealVibeEngineering", "canonical_path:", "ENVIRONMENT_QUICKSTART.md"]
    for path in [ROOT / "SKILL.md", ROOT / "README.md", *ROOT.joinpath("references").glob("*.md"), *ROOT.joinpath("scripts").glob("*.ps1")]:
        text = path.read_text(encoding="utf-8")
        for token in forbidden:
            if token in text:
                fail(errors, f"{path.relative_to(ROOT)}: stale token {token}")
    legacy_state = list((ROOT / "scripts").glob(".engine_*"))
    if legacy_state:
        fail(errors, "scripts/: runtime PID state files must not live in the skill directory")


def validate_readme_counts(errors: list[str]) -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    reference_count = len(list((ROOT / "references").glob("*.md")))
    script_py_count = len(list((ROOT / "scripts").glob("*.py")))
    expected_ref = f"references/         # {reference_count} 篇"
    expected_py = f"scripts/            # {script_py_count} 个 Python"
    if expected_ref not in readme:
        fail(errors, f"README.md: reference count is stale (expected {reference_count})")
    if expected_py not in readme:
        fail(errors, f"README.md: Python script count is stale (expected {script_py_count})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate ue-engineering-loop structure and content.")
    parser.add_argument("--release", action="store_true", help="require complete, non-placeholder catalog provenance")
    parser.add_argument("--catalog", type=Path, default=ROOT / "scripts" / "mcp_catalog.json", help="catalog to validate")
    args = parser.parse_args(argv)
    errors: list[str] = []
    validate_frontmatter(errors)
    validate_markdown_links(errors)
    validate_catalog(errors, args.catalog)
    validate_taboo_ids(errors)
    validate_hygiene(errors)
    validate_readme_counts(errors)
    try:
        catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        catalog = {}
    if args.release:
        if catalog.get("provenance_complete") is not True:
            fail(errors, "release profile requires provenance_complete=true")
        for field in ("engine_version", "model_context_protocol_version", "all_toolsets_version"):
            value = str(catalog.get(field, "")).strip().lower()
            if value in {"", "unknown", "test", "x", "n/a"}:
                fail(errors, f"release profile requires non-placeholder {field}")
        if catalog.get("protocol_version") != "2024-11-05":
            fail(errors, "release profile requires supported protocol_version 2024-11-05")
        if not isinstance(catalog.get("server_info"), dict) or not catalog["server_info"]:
            fail(errors, "release profile requires non-empty server_info from MCP initialize")
        if not str(catalog.get("producer", "")).startswith("dump_mcp_catalog.py/"):
            fail(errors, "release profile requires catalog generated by dump_mcp_catalog.py")
        try:
            generated = datetime.fromisoformat(str(catalog.get("generated_at_utc", "")))
            if generated.tzinfo is None:
                raise ValueError("timezone missing")
            age_days = (datetime.now(timezone.utc) - generated.astimezone(timezone.utc)).days
            if age_days < 0 or age_days > 365:
                fail(errors, f"release profile requires catalog age between 0 and 365 days; got {age_days}")
        except ValueError:
            fail(errors, "release profile requires a valid timezone-aware generated_at_utc")
    if errors:
        print("SKILL VALIDATION FAILED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("SKILL VALIDATION PASSED")
    print(f"- references: {len(list((ROOT / 'references').glob('*.md')))}")
    print(f"- Python scripts: {len(list((ROOT / 'scripts').glob('*.py')))}")
    print("- taboo rule IDs: 27")
    print("- catalog counts: consistent")
    if catalog.get("provenance_complete") is not True:
        print("- warning: catalog provenance is incomplete; short-name resolution must remain disabled")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
