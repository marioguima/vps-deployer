import hashlib
import hmac
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "src" / "vps_deployer.py"
spec = importlib.util.spec_from_file_location("vps_deployer", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)


class RegistryTests(unittest.TestCase):
    def test_load_targets(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "projects.json"
            p.write_text(json.dumps({"deployments": [{"repository": "owner/repo", "branch": "main", "command": ["/bin/true"], "timeout_seconds": 12}]}))
            targets = mod.load_targets(p)
            target = targets[("owner/repo", "refs/heads/main")]
            self.assertEqual(target.command, ("/bin/true",))
            self.assertEqual(target.timeout_seconds, 12)

    def test_duplicate_mapping_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "projects.json"
            item = {"repository": "owner/repo", "branch": "main", "command": ["/bin/true"]}
            p.write_text(json.dumps({"deployments": [item, item]}))
            with self.assertRaises(RuntimeError):
                mod.load_targets(p)


class StoreTests(unittest.TestCase):
    def test_delivery_is_idempotent(self):
        with tempfile.TemporaryDirectory() as td:
            store = mod.JobStore(Path(td) / "jobs.sqlite3")
            target = mod.Target("owner/repo", "main", ("/bin/true",), 10)
            args = dict(delivery_id="d1", repository="owner/repo", ref="refs/heads/main", branch="main", sha="a" * 40, sender="mario", target=target)
            first, first_id = store.enqueue(**args)
            second, second_id = store.enqueue(**args)
            self.assertTrue(first)
            self.assertFalse(second)
            self.assertEqual(first_id, second_id)


class SignatureTests(unittest.TestCase):
    def test_signature(self):
        with tempfile.TemporaryDirectory() as td:
            settings = mod.Settings(secret="this-is-a-long-test-secret-value", bind="127.0.0.1", port=9100, config_path=Path(td) / "projects.json", db_path=Path(td) / "jobs.sqlite3", log_dir=Path(td) / "logs", max_body_bytes=1024)
            settings.config_path.write_text('{"deployments": []}')
            app = mod.App(settings)
            body = b'{"zen":"ok"}'
            sig = "sha256=" + hmac.new(settings.secret.encode(), body, hashlib.sha256).hexdigest()
            self.assertTrue(app.verify_signature(body, sig))
            self.assertFalse(app.verify_signature(body, "sha256=bad"))


if __name__ == "__main__":
    unittest.main()
