import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "tools/atlas_live_control.py"


class LiveControlCLI(unittest.TestCase):
    def invoke(self, *args):
        return subprocess.run(
            [sys.executable, "-B", str(CLI), "--app", "community", *args],
            cwd=ROOT, capture_output=True, text=True, timeout=12,
        )

    def test_comets_and_dual_dry_run_without_running_app(self):
        for mode in ("comets", "dual", "idle-lines", "work-lines", "backdrop"):
            with self.subTest(mode=mode):
                p = self.invoke("--dry-run", mode, "on")
                self.assertEqual(p.returncode, 0, p.stderr)
                data = json.loads(p.stdout)
                self.assertTrue(data["dry_run"])
                self.assertEqual(data["option"], mode)

    def test_speed_bounds_and_screen_route(self):
        for value in ("0", "1.2", "3"):
            p = self.invoke("--dry-run", "speed", value)
            self.assertEqual(p.returncode, 0, p.stderr)
        p = self.invoke("--dry-run", "speed", "3.1")
        self.assertNotEqual(p.returncode, 0)
        p = self.invoke("--dry-run", "screen", "main")
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_status_only_reads_settings(self):
        p = self.invoke("status")
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads(p.stdout)
        self.assertTrue(data["ok"])
        self.assertEqual(data["app"], "community")
        self.assertIn("comets", data["settings"])


if __name__ == "__main__":
    unittest.main()
