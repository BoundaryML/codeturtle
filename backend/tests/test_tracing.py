"""Real pinned runtime -> local BTEL files -> SQL query, without service secrets."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


BACKEND = Path(__file__).resolve().parents[1]


class TracingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codeturtle-tracing-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        (self.project / "baml_src").mkdir()
        for name in ("baml.toml", "start.sh", "traces.sh"):
            shutil.copyfile(BACKEND / name, self.project / name)
        shutil.copyfile(BACKEND / "baml_src/observability.baml",
                        self.project / "baml_src/observability.baml")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("BOUNDARY_", "CODETURTLE_", "BAML_"))}
        self.env["BAML_VERSION"] = "0.20.2-nightly.20261004.a"

    def run_script(self, script, *args, **env):
        return subprocess.run(["sh", str(self.project / script), *args],
                              cwd=self.project, env={**self.env, **env},
                              capture_output=True, text=True, timeout=30)

    def test_local_recording_ignores_inherited_cloud_credentials(self):
        result = self.run_script("start.sh", "studio_probe",
                                 BOUNDARY_API_KEY="do-not-use-this-credential",
                                 BOUNDARY_API_URL="https://invalid.invalid",
                                 BOUNDARY_URL="https://invalid.invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(list(self.project.glob(".baml/btel/recordings/**/*.btel")))
        query = self.run_script("traces.sh", "--format", "json",
                               "SELECT span_name, status, input_args, output_value, "
                               "error_value, context_metadata FROM spans "
                               "WHERE span_name LIKE '%studio_probe_step'")
        self.assertEqual(query.returncode, 0, query.stderr)
        data = json.loads(query.stdout)
        self.assertEqual(data["outcome"]["status"], "complete")
        self.assertEqual(len(data["rows"]), 1)
        row = data["rows"][0]
        self.assertEqual(row[1], "return")
        self.assertEqual(row[2:5], [None, None, None])
        self.assertIn("probe", json.dumps(row[5]))

    def test_telemetry_can_be_disabled(self):
        result = self.run_script("start.sh", "studio_probe", BAML_TELEMETRY="off")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list(self.project.glob(".baml/btel/recordings/**/*.btel")))

    def test_studio_requires_explicit_local_gateway_and_key(self):
        for endpoint, key in (("", "test"), ("https://example.com", "test"),
                              ("http://127.0.0.1:1234", ""),
                              ("http://127.0.0.1:1234", "local"),
                              ("http://127.0.0.1:1234@evil.test", "test")):
            with self.subTest(endpoint=endpoint, key=key):
                result = self.run_script("start.sh", "studio_probe",
                                         CODETURTLE_TRACE_MODE="studio",
                                         CODETURTLE_STUDIO_URL=endpoint,
                                         BOUNDARY_API_KEY=key)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list(self.project.glob(".baml/btel/recordings/**/*.btel")))


if __name__ == "__main__":
    unittest.main()
