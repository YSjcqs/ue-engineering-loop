#!/usr/bin/env python3
"""Shared, fail-closed MCP streamable-HTTP client helpers."""

from __future__ import annotations

import ipaddress
import json
import os
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

EXIT_USAGE = 2
EXIT_NETWORK = 3
EXIT_PROTOCOL = 4
EXIT_TOOL = 5
EXIT_IO = 6
PROTOCOL_VERSION = "2024-11-05"


@dataclass
class McpFailure(Exception):
    message: str
    exit_code: int

    def __str__(self) -> str:
        return self.message


def validate_url(url: str, allow_remote: bool = False) -> str:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise McpFailure(f"invalid MCP URL: {url!r}", EXIT_USAGE)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise McpFailure(
            "MCP URL must not contain credentials, query parameters, or fragments; use secure headers in the host configuration",
            EXIT_USAGE,
        )
    host = parsed.hostname.lower()
    is_loopback = host == "localhost"
    if not is_loopback:
        try:
            is_loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            is_loopback = False
    if not is_loopback and not allow_remote:
        raise McpFailure(
            f"remote MCP endpoint is disabled by default: {host}; use --allow-remote only after explicit authorization",
            EXIT_USAGE,
        )
    if not is_loopback and parsed.scheme != "https":
        raise McpFailure("remote MCP endpoints must use HTTPS", EXIT_USAGE)
    return url


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


def parse_json_object(raw: str, label: str = "JSON") -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise McpFailure(f"invalid {label}: {exc}", EXIT_USAGE) from exc
    if not isinstance(value, dict):
        raise McpFailure(f"{label} must be a JSON object", EXIT_USAGE)
    return value


def parse_jsonrpc(body: str, content_type: str, expected_id: int | None = None) -> dict[str, Any]:
    candidates: list[str] = []
    if "text/event-stream" in content_type.lower():
        event_data: list[str] = []
        for raw_line in body.splitlines():
            line = raw_line.rstrip("\r")
            if not line:
                if event_data:
                    candidates.append("\n".join(event_data))
                    event_data = []
                continue
            if line.startswith("data:"):
                event_data.append(line[5:].lstrip())
        if event_data:
            candidates.append("\n".join(event_data))
    else:
        candidates.append(body)

    for candidate in candidates:
        try:
            obj = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        if obj.get("jsonrpc") != "2.0":
            continue
        has_result = "result" in obj
        has_error = "error" in obj
        if has_result == has_error:
            continue
        if expected_id is not None:
            response_id = obj.get("id")
            if type(response_id) is not int or response_id != expected_id:
                continue
        return obj
    preview = body[:500].replace("\n", "\\n")
    raise McpFailure(f"unable to parse JSON-RPC response: {preview}", EXIT_PROTOCOL)


def atomic_write_text(path: str | os.PathLike[str], text: str) -> None:
    temp_name: str | None = None
    target = Path(path).expanduser()
    try:
        target = target.resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix=target.name + ".", suffix=".tmp", dir=target.parent)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, target)
    except OSError as exc:
        raise McpFailure(f"failed to write output {target}: {exc}", EXIT_IO) from exc
    finally:
        if temp_name and os.path.exists(temp_name):
            try:
                os.unlink(temp_name)
            except OSError:
                pass


class McpClient:
    def __init__(
        self,
        url: str,
        timeout: float = 120.0,
        client_name: str = "ue-engineering-loop",
        allow_remote: bool = False,
        max_response_bytes: int = 16 * 1024 * 1024,
    ) -> None:
        self.url = validate_url(url, allow_remote)
        if timeout <= 0 or timeout > 3600:
            raise McpFailure("timeout must be > 0 and <= 3600 seconds", EXIT_USAGE)
        if max_response_bytes < 1024 or max_response_bytes > 256 * 1024 * 1024:
            raise McpFailure("max_response_bytes must be between 1024 and 268435456", EXIT_USAGE)
        self.timeout = timeout
        self.client_name = client_name
        self.allow_remote = allow_remote
        self.max_response_bytes = max_response_bytes
        self.session_id: str | None = None
        self._next_id = 1
        self._opener = urllib.request.build_opener(_NoRedirectHandler())

    def _read_response(self, response) -> bytes:  # type: ignore[no-untyped-def]
        deadline = time.monotonic() + self.timeout
        chunks: list[bytes] = []
        total = 0

        def _bind_read_deadline() -> None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise McpFailure("MCP response exceeded absolute deadline", EXIT_NETWORK)
            try:
                sock = response.fp.raw._sock  # type: ignore[attr-defined]
                sock.settimeout(max(0.05, min(self.timeout, remaining)))
            except (AttributeError, OSError):
                pass

        read_method = getattr(response, "read1", response.read)
        while True:
            _bind_read_deadline()
            chunk = read_method(min(65536, self.max_response_bytes + 1 - total))
            if time.monotonic() > deadline:
                raise McpFailure("MCP response exceeded absolute deadline", EXIT_NETWORK)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > self.max_response_bytes:
                raise McpFailure("MCP response exceeded configured size limit", EXIT_PROTOCOL)
        return b"".join(chunks)

    def _post(self, payload: dict[str, Any], allow_empty: bool = False) -> dict[str, Any] | None:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        expected_id = payload.get("id")
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                raw = self._read_response(response)
                body = raw.decode("utf-8", "replace")
                content_type = response.headers.get("Content-Type", "")
                new_session = response.headers.get("Mcp-Session-Id")
                if new_session:
                    self.session_id = new_session
        except urllib.error.HTTPError as exc:
            raw = self._read_response(exc)
            body = raw.decode("utf-8", "replace")
            try:
                obj = parse_jsonrpc(body, exc.headers.get("Content-Type", ""), expected_id)
            except McpFailure:
                raise McpFailure(f"HTTP {exc.code} from MCP endpoint: {body[:300]}", EXIT_NETWORK) from exc
            if "error" in obj:
                raise McpFailure(f"JSON-RPC error: {json.dumps(obj['error'], ensure_ascii=False)}", EXIT_TOOL) from exc
            raise McpFailure(f"HTTP {exc.code} from MCP endpoint", EXIT_NETWORK) from exc
        except McpFailure:
            raise
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise McpFailure(f"MCP connection failed: {exc}", EXIT_NETWORK) from exc

        if allow_empty:
            if body.strip():
                raise McpFailure("notification request returned an unexpected response body", EXIT_PROTOCOL)
            return None
        return parse_jsonrpc(body, content_type, expected_id)

    def initialize(self) -> dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        obj = self._post(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": self.client_name, "version": "1.1"},
                },
            }
        )
        if obj is None or "error" in obj:
            error = None if obj is None else obj.get("error")
            raise McpFailure(f"MCP initialize failed: {error}", EXIT_PROTOCOL)
        result = obj.get("result")
        if not isinstance(result, dict):
            raise McpFailure("MCP initialize result is not an object", EXIT_PROTOCOL)
        negotiated = result.get("protocolVersion")
        if negotiated != PROTOCOL_VERSION:
            raise McpFailure(
                f"unsupported MCP protocol version: expected {PROTOCOL_VERSION}, got {negotiated!r}",
                EXIT_PROTOCOL,
            )
        self._post(
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
            allow_empty=True,
        )
        return result

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        request_id = self._next_id
        self._next_id += 1
        obj = self._post(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            }
        )
        if obj is None:
            raise McpFailure("empty JSON-RPC tool response", EXIT_PROTOCOL)
        if "error" in obj:
            raise McpFailure(f"JSON-RPC error: {json.dumps(obj['error'], ensure_ascii=False)}", EXIT_TOOL)
        result = obj.get("result")
        if not isinstance(result, dict):
            raise McpFailure("tools/call result is not an object", EXIT_PROTOCOL)
        if result.get("isError") is True:
            raise McpFailure(f"tool returned isError: {render_result(result)}", EXIT_TOOL)
        return result


def render_result(result: dict[str, Any]) -> str:
    content = result.get("content")
    if isinstance(content, list):
        text_parts = [
            str(item.get("text", ""))
            for item in content
            if isinstance(item, dict) and item.get("type") == "text"
        ]
        if text_parts:
            return "\n".join(text_parts)
    return json.dumps(result, ensure_ascii=False, indent=2)
