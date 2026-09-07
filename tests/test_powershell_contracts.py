from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
POWERSHELL = shutil.which("powershell.exe") or shutil.which("powershell") or shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL, "PowerShell executable not available")
class PowerShellContractTests(unittest.TestCase):
    def invoke(self, script: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPTS / script), *arguments],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
            timeout=30,
        )

    def test_headless_selftest(self) -> None:
        self.assertEqual(self.invoke("run_spec_headless.ps1", "-SelfTest").returncode, 0)

    def test_pid_tracker_selftest(self) -> None:
        self.assertEqual(self.invoke("engine_pid_tracker.ps1", "-SelfTest").returncode, 0)

    def test_headless_missing_args(self) -> None:
        self.assertEqual(self.invoke("run_spec_headless.ps1").returncode, 4)

    def test_health_invalid_timeout(self) -> None:
        self.assertEqual(self.invoke("env_health_check.ps1", "-TimeoutMs", "99").returncode, 3)

    def test_pid_invalid_action(self) -> None:
        self.assertEqual(self.invoke("engine_pid_tracker.ps1", "-Action", "bad").returncode, 4)

    def test_health_rejects_remote_without_opt_in(self) -> None:
        result = self.invoke(
            "env_health_check.ps1",
            "-Endpoints",
            "TEST=https://example.com/mcp",
            "-ExpectedStatus",
            "TEST=200",
        )
        self.assertEqual(result.returncode, 3)

    def test_multiple_uproject_files_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "A.uproject").write_text("{}", encoding="utf-8")
            Path(directory, "B.uproject").write_text("{}", encoding="utf-8")
            runner = self.invoke("run_spec_headless.ps1", "-ProjectPath", directory, "-Spec", "A.Test")
            self.assertEqual(runner.returncode, 4)
            health = self.invoke(
                "env_health_check.ps1",
                "-ProjectPath",
                directory,
                "-Endpoints",
                "TEST=http://127.0.0.1:1/x",
                "-ExpectedStatus",
                "TEST=200",
                "-TimeoutMs",
                "100",
            )
            self.assertEqual(health.returncode, 3)


if __name__ == "__main__":
    unittest.main()
