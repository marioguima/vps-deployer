import importlib.util
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "github_app_git.py"
spec = importlib.util.spec_from_file_location("github_app_git", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)


class EnvTests(unittest.TestCase):
    def test_load_env_file(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "env"
            path.write_text(
                "# comment\nGITHUB_APP_CLIENT_ID=Iv123\n"
                "GITHUB_APP_PRIVATE_KEY='/etc/vps-deployer/key.pem'\n",
                encoding="utf-8",
            )
            values = mod.load_env_file(path)
            self.assertEqual(values["GITHUB_APP_CLIENT_ID"], "Iv123")
            self.assertEqual(
                values["GITHUB_APP_PRIVATE_KEY"],
                "/etc/vps-deployer/key.pem",
            )

    def test_invalid_env_line_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "env"
            path.write_text("NOT_AN_ASSIGNMENT\n", encoding="utf-8")
            with self.assertRaises(mod.AuthError):
                mod.load_env_file(path)


class JwtTests(unittest.TestCase):
    def test_b64url_has_no_padding(self):
        encoded = mod.b64url(b"\xfb\xff")
        self.assertNotIn("=", encoded)
        self.assertNotIn("+", encoded)
        self.assertNotIn("/", encoded)

    def test_invalid_repository_is_rejected_before_api_call(self):
        with self.assertRaises(mod.AuthError):
            mod.installation_token(
                "not a repo",
                client_id="Iv123",
                private_key=Path("/does/not/matter"),
                api_version="2026-03-10",
            )


class AskPassTests(unittest.TestCase):
    def test_askpass_is_private_and_does_not_contain_token(self):
        with tempfile.TemporaryDirectory() as td:
            script = mod.askpass_script(Path(td))
            mode = stat.S_IMODE(script.stat().st_mode)
            self.assertEqual(mode, 0o700)
            content = script.read_text(encoding="utf-8")
            self.assertIn("VPS_DEPLOYER_GITHUB_TOKEN", content)
            self.assertNotIn("ghs_", content)


class RunGitTests(unittest.TestCase):
    def test_token_is_passed_via_environment_not_command_line(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            env_file = root / "env"
            key = root / "app.pem"
            env_file.write_text(
                f"GITHUB_APP_CLIENT_ID=Iv123\n"
                f"GITHUB_APP_PRIVATE_KEY={key}\n",
                encoding="utf-8",
            )
            key.write_text("fake", encoding="utf-8")

            completed = mock.Mock(returncode=0)
            with mock.patch.object(
                mod, "installation_token", return_value=("ghs_secret_value", "later")
            ), mock.patch.object(mod.subprocess, "run", return_value=completed) as run:
                code = mod.run_git(
                    "owner/repo",
                    ["ls-remote", "https://github.com/owner/repo.git"],
                    env_file=env_file,
                    cwd=root,
                )

            self.assertEqual(code, 0)
            command = run.call_args.args[0]
            self.assertNotIn("ghs_secret_value", " ".join(command))
            child_env = run.call_args.kwargs["env"]
            self.assertEqual(
                child_env["VPS_DEPLOYER_GITHUB_TOKEN"],
                "ghs_secret_value",
            )
            self.assertEqual(child_env["GIT_TERMINAL_PROMPT"], "0")


if __name__ == "__main__":
    unittest.main()
