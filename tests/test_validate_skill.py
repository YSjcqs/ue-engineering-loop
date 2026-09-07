from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import validate_skill  # noqa: E402


class ValidateSkillTests(unittest.TestCase):
    def test_current_skill_passes(self) -> None:
        self.assertEqual(validate_skill.main([]), 0)

    def test_missing_conceptual_name_is_not_silently_accepted(self) -> None:
        source = ROOT / "references" / "CONTEXT_MANAGEMENT.md"
        self.assertFalse(validate_skill.resolve_reference(source, "DESIGN_EXAMPLE.md"))

    def test_real_reference_resolves(self) -> None:
        source = ROOT / "SKILL.md"
        self.assertTrue(validate_skill.resolve_reference(source, "references/MCP_CHANNELS.md"))

    def test_reference_cannot_escape_skill_root(self) -> None:
        source = ROOT / "references" / "CONTEXT_MANAGEMENT.md"
        self.assertFalse(validate_skill.resolve_reference(source, "../../outside.md"))

    def test_release_profile_rejects_incomplete_catalog(self) -> None:
        self.assertEqual(validate_skill.main(["--release"]), 1)

    def test_release_profile_accepts_complete_catalog_fixture(self) -> None:
        catalog = json.loads((ROOT / "scripts" / "mcp_catalog.json").read_text(encoding="utf-8"))
        catalog.update({
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "producer": "dump_mcp_catalog.py/1.1",
            "provenance_source": "operator-supplied versions plus MCP initialize serverInfo",
            "engine_version": "UE 5.8 CL 123456",
            "model_context_protocol_version": "1.2.3",
            "all_toolsets_version": "1.2.3",
            "server_info": {"name": "test-server", "version": "1.2.3"},
            "provenance_complete": True,
        })
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            path.write_text(json.dumps(catalog), encoding="utf-8")
            self.assertEqual(validate_skill.main(["--release", "--catalog", str(path)]), 0)

    def test_duplicate_frontmatter_key_is_rejected(self) -> None:
        content = '''---
name: ue-engineering-loop
name: other
description: >-
  x
description_en: >-
  x
version: "1.1.0"
engine_version: "UE"
min_rider_version: "none"
last_updated: "2026-09-07"
agent_created: true
---
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "SKILL.md"
            path.write_text(content, encoding="utf-8")
            errors: list[str] = []
            validate_skill.validate_frontmatter(errors, path)
            self.assertTrue(any("duplicate" in error for error in errors))

    def test_invalid_calendar_date_is_rejected(self) -> None:
        content = '''---
name: ue-engineering-loop
description: >-
  x
description_en: >-
  x
version: "1.1.0"
engine_version: "UE"
min_rider_version: "none"
last_updated: "9999-99-99"
agent_created: true
---
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "SKILL.md"
            path.write_text(content, encoding="utf-8")
            errors: list[str] = []
            validate_skill.validate_frontmatter(errors, path)
            self.assertTrue(any("calendar date" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
