from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

from mcp_common import (  # noqa: E402
    EXIT_IO,
    EXIT_NETWORK,
    EXIT_PROTOCOL,
    EXIT_TOOL,
    EXIT_USAGE,
    McpClient,
    McpFailure,
    _NoRedirectHandler,
    atomic_write_text,
    parse_json_object,
    parse_jsonrpc,
    render_result,
    validate_url,
)
from mcp_call import resolve_toolset  # noqa: E402
from dump_mcp_catalog import normalize_toolset, normalize_toolset_names, output_lock, validate_catalog  # noqa: E402


class McpCommonTests(unittest.TestCase):
    def test_parse_plain_jsonrpc(self) -> None:
        obj = parse_jsonrpc('{"jsonrpc":"2.0","id":1,"result":{"ok":true}}', "application/json")
        self.assertTrue(obj["result"]["ok"])

    def test_parse_multiline_sse_event(self) -> None:
        body = 'event: message\ndata: {"jsonrpc":"2.0",\ndata: "id":1,"result":{"ok":true}}\n\n'
        obj = parse_jsonrpc(body, "text/event-stream")
        self.assertTrue(obj["result"]["ok"])

    def test_unparseable_response_is_protocol_failure(self) -> None:
        with self.assertRaises(McpFailure) as ctx:
            parse_jsonrpc("not-json", "application/json")
        self.assertEqual(ctx.exception.exit_code, EXIT_PROTOCOL)

    def test_response_id_and_version_are_validated(self) -> None:
        with self.assertRaises(McpFailure):
            parse_jsonrpc('{"jsonrpc":"2.0","id":999,"result":{}}', "application/json", expected_id=1)
        with self.assertRaises(McpFailure):
            parse_jsonrpc('{"jsonrpc":"1.0","id":1,"result":{}}', "application/json", expected_id=1)
        with self.assertRaises(McpFailure):
            parse_jsonrpc('{"jsonrpc":"2.0","id":true,"result":{}}', "application/json", expected_id=1)

    def test_initialize_requires_object_result(self) -> None:
        client = McpClient("http://127.0.0.1:8000/mcp")
        client._post = mock.Mock(return_value={"jsonrpc": "2.0", "id": 1, "result": []})
        with self.assertRaises(McpFailure) as ctx:
            client.initialize()
        self.assertEqual(ctx.exception.exit_code, EXIT_PROTOCOL)

    def test_arguments_must_be_object(self) -> None:
        with self.assertRaises(McpFailure) as ctx:
            parse_json_object("[]", "arguments")
        self.assertEqual(ctx.exception.exit_code, EXIT_USAGE)

    def test_url_rejects_embedded_credentials_and_query(self) -> None:
        for url in ("http://user:pass@localhost/mcp", "http://localhost/mcp?token=secret"):
            with self.subTest(url=url), self.assertRaises(McpFailure):
                validate_url(url)

    def test_remote_url_requires_explicit_opt_in(self) -> None:
        with self.assertRaises(McpFailure) as ctx:
            validate_url("https://example.com/mcp")
        self.assertEqual(ctx.exception.exit_code, EXIT_USAGE)
        with self.assertRaises(McpFailure):
            validate_url("http://example.com/mcp", allow_remote=True)
        with self.assertRaises(McpFailure):
            validate_url("http://spoof.localhost/mcp")
        self.assertEqual(validate_url("https://example.com/mcp", allow_remote=True), "https://example.com/mcp")

    def test_atomic_write_replaces_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.txt"
            path.write_text("old", encoding="utf-8")
            atomic_write_text(path, "new")
            self.assertEqual(path.read_text(encoding="utf-8"), "new")
            self.assertFalse(list(path.parent.glob("*.tmp")))

    def test_atomic_write_maps_io_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch("mcp_common.os.replace", side_effect=OSError("blocked")):
            with self.assertRaises(McpFailure) as ctx:
                atomic_write_text(Path(directory) / "result.txt", "new")
            self.assertEqual(ctx.exception.exit_code, EXIT_IO)
            self.assertFalse(list(Path(directory).glob("*.tmp")))

    def test_render_text_content(self) -> None:
        result = {"content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}
        self.assertEqual(render_result(result), "a\nb")


class CliContractTests(unittest.TestCase):
    def test_callers_use_stable_usage_exit_code(self) -> None:
        for script in ("mcp_call.py", "wb_call.py", "rider_call.py"):
            with self.subTest(script=script):
                completed = subprocess.run(
                    [sys.executable, str(SCRIPTS / script)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(completed.returncode, EXIT_USAGE)
                self.assertNotIn("Traceback", completed.stderr)


class FakeResponse:
    def __init__(self, body: str, content_type: str = "application/json", session_id: str | None = None) -> None:
        self._body = body.encode("utf-8")
        self._offset = 0
        self.headers = {"Content-Type": content_type}
        if session_id:
            self.headers["Mcp-Session-Id"] = session_id

    def read(self, size: int = -1) -> bytes:
        if self._offset >= len(self._body):
            return b""
        if size < 0:
            chunk = self._body[self._offset :]
            self._offset = len(self._body)
            return chunk
        chunk = self._body[self._offset : self._offset + size]
        self._offset += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class McpClientProtocolTests(unittest.TestCase):
    def test_initialize_and_call_reuse_session_header(self) -> None:
        client = McpClient("http://127.0.0.1:8000/mcp")
        responses = [
            FakeResponse('{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}', session_id="session-1"),
            FakeResponse(""),
            FakeResponse('{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}'),
        ]
        requests = []

        def fake_open(request, timeout):
            requests.append(request)
            return responses.pop(0)

        client._opener.open = fake_open
        client.initialize()
        result = client.call_tool("ping", {})
        self.assertEqual(render_result(result), "ok")
        self.assertEqual(requests[1].get_header("Mcp-session-id"), "session-1")
        self.assertEqual(requests[2].get_header("Mcp-session-id"), "session-1")

    def test_initialize_rejects_unexpected_protocol_version(self) -> None:
        client = McpClient("http://127.0.0.1:8000/mcp")
        client._post = mock.Mock(return_value={"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "unexpected"}})
        with self.assertRaises(McpFailure) as ctx:
            client.initialize()
        self.assertEqual(ctx.exception.exit_code, EXIT_PROTOCOL)

    def test_tool_is_error_maps_to_exit_five(self) -> None:
        client = McpClient("http://127.0.0.1:8000/mcp")
        client._post = mock.Mock(return_value={"jsonrpc": "2.0", "id": 1, "result": {"isError": True, "content": [{"type": "text", "text": "bad"}]}})
        with self.assertRaises(McpFailure) as ctx:
            client.call_tool("bad", {})
        self.assertEqual(ctx.exception.exit_code, EXIT_TOOL)

    def test_response_size_limit(self) -> None:
        client = McpClient("http://127.0.0.1:8000/mcp", max_response_bytes=1024)
        client._opener.open = mock.Mock(return_value=FakeResponse("x" * 1025))
        with self.assertRaises(McpFailure) as ctx:
            client._post({"jsonrpc": "2.0", "id": 1, "method": "x"})
        self.assertEqual(ctx.exception.exit_code, EXIT_PROTOCOL)

    def test_redirects_are_disabled(self) -> None:
        handler = _NoRedirectHandler()
        request = urllib.request.Request(
            "http://127.0.0.1:8000/mcp",
            data=b"{}",
            headers={"Mcp-Session-Id": "secret-session"},
            method="POST",
        )
        redirected = handler.redirect_request(request, None, 302, "Found", {}, "http://127.0.0.1:9000/other")
        self.assertIsNone(redirected)


class ToolsetResolutionTests(unittest.TestCase):
    def write_catalog(self, names: list[str], directory: str) -> Path:
        path = Path(directory) / "catalog.json"
        path.write_text(json.dumps({"provenance_complete": True, "toolsets": [{"name": name} for name in names]}), encoding="utf-8")
        return path

    def test_unique_suffix_resolves(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_catalog(["A.B.Toolset", "C.Other"], directory)
            self.assertEqual(resolve_toolset("Toolset", path), "A.B.Toolset")

    def test_ambiguous_prefix_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_catalog(["A.One", "A.Two"], directory)
            with self.assertRaises(McpFailure) as ctx:
                resolve_toolset("A", path)
            self.assertEqual(ctx.exception.exit_code, EXIT_USAGE)

    def test_incomplete_provenance_disables_short_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            path.write_text(json.dumps({"provenance_complete": False, "toolsets": [{"name": "A.Toolset"}]}), encoding="utf-8")
            with self.assertRaises(McpFailure) as ctx:
                resolve_toolset("Toolset", path)
            self.assertEqual(ctx.exception.exit_code, EXIT_PROTOCOL)
            self.assertEqual(resolve_toolset("A.Toolset", path), "A.Toolset")


class CatalogTests(unittest.TestCase):
    @staticmethod
    def add_digest(catalog: dict) -> None:
        payload = json.dumps(catalog["toolsets"], ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        catalog["toolset_digest_sha256"] = hashlib.sha256(payload).hexdigest()

    def test_preserves_full_tool_schema(self) -> None:
        tool = {"name": "T.Do", "description": "x", "inputSchema": {"type": "object"}}
        normalized = normalize_toolset({"name": "T", "description": "d", "tools": [tool]}, "T")
        self.assertEqual(normalized["tools"][0]["inputSchema"]["type"], "object")

    def test_partial_or_invalid_toolset_fails(self) -> None:
        with self.assertRaises(McpFailure):
            normalize_toolset({"name": "T"}, "T")

    def test_describe_name_must_match_requested_name(self) -> None:
        with self.assertRaises(McpFailure):
            normalize_toolset({"name": "Other", "tools": []}, "Expected")

    def test_catalog_rejects_missing_input_schema(self) -> None:
        catalog = {
            "schema_version": 2,
            "generated_at_utc": "2026-09-07T00:00:00+00:00",
            "protocol_version": "2024-11-05",
            "producer": "test",
            "provenance_source": "test",
            "engine_version": "test",
            "model_context_protocol_version": "test",
            "all_toolsets_version": "test",
            "provenance_complete": True,
            "toolsets": [{"name": "T", "tool_count": 1, "tools": [{"name": "T.Do"}]}],
            "toolset_count": 1,
            "total_tool_count": 1,
        }
        self.add_digest(catalog)
        with self.assertRaises(McpFailure):
            validate_catalog(catalog)

    def test_catalog_rejects_wrong_schema_and_unknown_provenance(self) -> None:
        base = {
            "schema_version": 1,
            "generated_at_utc": "2026-09-07T00:00:00+00:00",
            "protocol_version": "2024-11-05",
            "producer": "test",
            "provenance_source": "test",
            "engine_version": "unknown",
            "model_context_protocol_version": "test",
            "all_toolsets_version": "test",
            "provenance_complete": True,
            "toolsets": [{"name": "T", "tool_count": 1, "tools": [{"name": "T.Do", "inputSchema": {"type": "object"}}]}],
            "toolset_count": 1,
            "total_tool_count": 1,
        }
        self.add_digest(base)
        with self.assertRaises(McpFailure):
            validate_catalog(base)
        base["schema_version"] = 2
        with self.assertRaises(McpFailure):
            validate_catalog(base)

    def test_catalog_count_validation(self) -> None:
        catalog = {
            "schema_version": 2,
            "generated_at_utc": "2026-09-07T00:00:00+00:00",
            "protocol_version": "2024-11-05",
            "producer": "test",
            "provenance_source": "test",
            "engine_version": "test",
            "model_context_protocol_version": "test",
            "all_toolsets_version": "test",
            "provenance_complete": True,
            "toolsets": [{"name": "T", "tool_count": 1, "tools": [{"name": "T.Do", "inputSchema": {"type": "object"}}]}],
            "toolset_count": 1,
            "total_tool_count": 1,
        }
        self.add_digest(catalog)
        validate_catalog(catalog)
        catalog["total_tool_count"] = 2
        with self.assertRaises(McpFailure):
            validate_catalog(catalog)

    def test_duplicate_toolset_names_fail(self) -> None:
        with self.assertRaises(McpFailure):
            normalize_toolset_names(["T", "T"])

    def test_output_lock_is_process_safe_and_reusable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.lock"
            with output_lock(path):
                with self.assertRaises(McpFailure):
                    with output_lock(path):
                        pass
            with output_lock(path):
                self.assertTrue(path.exists())


if __name__ == "__main__": 
    unittest.main()
