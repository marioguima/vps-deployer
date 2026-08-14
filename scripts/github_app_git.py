#!/usr/bin/env python3
"""Run Git commands against private GitHub repositories using a GitHub App.

The installation token is kept out of Git remote URLs and command-line arguments.
It is exposed only to a short-lived GIT_ASKPASS helper through the child process
environment.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Mapping

DEFAULT_ENV_FILE = Path("/etc/vps-deployer/env")
DEFAULT_WORKDIR = Path("/var/lib/vps-deployer")
DEFAULT_API_VERSION = "2026-03-10"
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class AuthError(RuntimeError):
    pass


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as exc:
        raise AuthError(f"environment file not found: {path}") from exc

    for line_no, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise AuthError(f"invalid line {line_no} in {path}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise AuthError(f"invalid line {line_no} in {path}: empty key")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key] = value
    return values


def config_value(name: str, file_values: Mapping[str, str], default: str = "") -> str:
    return os.environ.get(name) or file_values.get(name) or default


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_jwt(client_id: str, private_key: Path, *, now: int | None = None) -> str:
    if not client_id:
        raise AuthError("GITHUB_APP_CLIENT_ID is not configured")
    if not private_key.is_file():
        raise AuthError(f"GitHub App private key not found: {private_key}")

    current = int(time.time() if now is None else now)
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(
        json.dumps(
            {"iat": current - 60, "exp": current + 540, "iss": client_id},
            separators=(",", ":"),
        ).encode()
    )
    unsigned = f"{header}.{payload}".encode("ascii")

    try:
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(private_key), "-binary"],
            input=unsigned,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError as exc:
        raise AuthError("openssl is required but was not found") from exc

    if result.returncode != 0:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        raise AuthError(f"failed to sign GitHub App JWT: {message or 'openssl failed'}")

    return f"{header}.{payload}.{b64url(result.stdout)}"


def github_json(method: str, url: str, *, bearer: str, api_version: str) -> dict:
    request = urllib.request.Request(
        url,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {bearer}",
            "X-GitHub-Api-Version": api_version,
            "User-Agent": "vps-deployer",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        message = ""
        try:
            payload = json.loads(exc.read().decode("utf-8", errors="replace"))
            message = str(payload.get("message", ""))
        except Exception:
            pass
        suffix = f": {message}" if message else ""
        raise AuthError(f"GitHub API {method} {url} returned HTTP {exc.code}{suffix}") from exc
    except urllib.error.URLError as exc:
        raise AuthError(f"GitHub API request failed: {exc.reason}") from exc


def installation_token(
    repository: str,
    *,
    client_id: str,
    private_key: Path,
    api_version: str,
) -> tuple[str, str]:
    if not REPOSITORY_RE.fullmatch(repository):
        raise AuthError("repository must be in owner/repo format")

    jwt = make_jwt(client_id, private_key)
    installation = github_json(
        "GET",
        f"https://api.github.com/repos/{repository}/installation",
        bearer=jwt,
        api_version=api_version,
    )
    installation_id = installation.get("id")
    if not isinstance(installation_id, int):
        raise AuthError("GitHub API did not return a valid installation id")

    token_payload = github_json(
        "POST",
        f"https://api.github.com/app/installations/{installation_id}/access_tokens",
        bearer=jwt,
        api_version=api_version,
    )
    token = token_payload.get("token")
    expires_at = token_payload.get("expires_at", "")
    if not isinstance(token, str) or not token:
        raise AuthError("GitHub API did not return an installation token")
    return token, str(expires_at)


def askpass_script(directory: Path) -> Path:
    script = directory / "askpass.sh"
    script.write_text(
        """#!/bin/sh
case "$1" in
  *Username*) printf '%s\\n' 'x-access-token' ;;
  *Password*) printf '%s\\n' "$VPS_DEPLOYER_GITHUB_TOKEN" ;;
  *) exit 1 ;;
esac
""",
        encoding="utf-8",
    )
    script.chmod(0o700)
    return script


def run_git(repository: str, git_args: list[str], *, env_file: Path, cwd: Path) -> int:
    if not git_args:
        raise AuthError("at least one git argument is required after --")
    if not cwd.is_dir():
        raise AuthError(f"working directory does not exist: {cwd}")

    values = load_env_file(env_file)
    client_id = config_value("GITHUB_APP_CLIENT_ID", values)
    key_value = config_value("GITHUB_APP_PRIVATE_KEY", values)
    api_version = config_value("GITHUB_API_VERSION", values, DEFAULT_API_VERSION)
    if not key_value:
        raise AuthError("GITHUB_APP_PRIVATE_KEY is not configured")
    private_key = Path(key_value)

    token, _expires_at = installation_token(
        repository,
        client_id=client_id,
        private_key=private_key,
        api_version=api_version,
    )

    with tempfile.TemporaryDirectory(prefix="vps-deployer-git-") as temp_dir:
        askpass = askpass_script(Path(temp_dir))
        child_env = os.environ.copy()
        child_env.update(
            {
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_ASKPASS": str(askpass),
                "VPS_DEPLOYER_GITHUB_TOKEN": token,
            }
        )
        try:
            result = subprocess.run(
                ["git", *git_args],
                cwd=str(cwd),
                env=child_env,
                check=False,
            )
        except FileNotFoundError as exc:
            raise AuthError("git is required but was not found") from exc
        finally:
            token = ""
    return result.returncode


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run git with a temporary GitHub App installation token."
    )
    parser.add_argument("repository", help="GitHub repository in owner/repo format")
    parser.add_argument(
        "--env-file",
        type=Path,
        default=DEFAULT_ENV_FILE,
        help=f"configuration file (default: {DEFAULT_ENV_FILE})",
    )
    parser.add_argument(
        "--cwd",
        type=Path,
        default=DEFAULT_WORKDIR,
        help=f"working directory for git (default: {DEFAULT_WORKDIR})",
    )
    parser.add_argument(
        "git_args",
        nargs=argparse.REMAINDER,
        help="git arguments; prefix with -- to stop option parsing",
    )
    args = parser.parse_args(argv)
    if args.git_args and args.git_args[0] == "--":
        args.git_args = args.git_args[1:]
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return run_git(
            args.repository,
            args.git_args,
            env_file=args.env_file,
            cwd=args.cwd,
        )
    except AuthError as exc:
        print(f"vps-deployer-git: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
