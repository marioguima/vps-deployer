#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

CONFIG = Path("/etc/vps-deployer/projects.json")
WORKSPACES = Path("/var/lib/vps-deployer/workspaces")
ADAPTER = "/opt/vps-deployer/project-scripts/trackpixel.sh"
PROJECT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*--[0-9a-f]{12}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def load_config() -> dict:
    if not CONFIG.exists():
        return {"deployments": []}
    data = json.loads(CONFIG.read_text(encoding="utf-8"))
    if not isinstance(data.get("deployments"), list):
        raise SystemExit("projects.json must contain a deployments array")
    return data


def find_project_id(deployments: list[dict], repository: str) -> str | None:
    ids = {
        item.get("project_id")
        for item in deployments
        if isinstance(item, dict)
        and item.get("repository", "").lower() == repository.lower()
        and item.get("project_id")
    }
    if len(ids) > 1:
        raise SystemExit(f"multiple project_id values found for {repository}: {sorted(ids)}")
    return next(iter(ids), None)


def validate_repository(value: str) -> str:
    value = value.strip()
    if not REPOSITORY_RE.fullmatch(value):
        raise SystemExit("repository must be owner/repo")
    return value


def require_trackpixel_host_dependencies() -> None:
    docker = shutil.which("docker")
    if not docker:
        raise SystemExit(
            "Docker Engine is required for TrackPixel. Run: sudo vps-deployer-bootstrap-host"
        )
    compose = subprocess.run(
        [docker, "compose", "version"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if compose.returncode != 0:
        raise SystemExit(
            "Docker Compose plugin is required for TrackPixel. Run: sudo vps-deployer-bootstrap-host"
        )
    active = subprocess.run(
        ["systemctl", "is-active", "--quiet", "docker"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if active.returncode != 0:
        raise SystemExit(
            "Docker service is not active. Run: sudo vps-deployer-bootstrap-host"
        )


def _group_id(name: str) -> int:
    import grp
    try:
        return grp.getgrnam(name).gr_gid
    except KeyError as exc:
        raise SystemExit(f"group not found: {name}") from exc


def main() -> int:
    if os.geteuid() != 0:
        raise SystemExit("run as root: sudo vps-deployer-onboard-trackpixel ...")

    parser = argparse.ArgumentParser(description="Register TrackPixel homolog/main in VPS Deployer")
    parser.add_argument("--repository", default="marioguima/trackpixel")
    parser.add_argument("--project-id")
    parser.add_argument(
        "--from-repository",
        help="old owner/repo when transferring an existing project; reuses its project_id",
    )
    args = parser.parse_args()

    repository = validate_repository(args.repository)
    old_repository = validate_repository(args.from_repository) if args.from_repository else None

    # Fail before changing the allowlist/workspaces when the host cannot run the
    # TrackPixel adapter. Host preparation is a one-time bootstrap concern.
    require_trackpixel_host_dependencies()

    data = load_config()
    deployments = data["deployments"]

    project_id = args.project_id
    if not project_id and old_repository:
        project_id = find_project_id(deployments, old_repository)
        if not project_id:
            raise SystemExit(f"no project_id found for old repository {old_repository}")
    if not project_id:
        project_id = find_project_id(deployments, repository)
    if not project_id:
        repo_name = repository.split("/", 1)[1].lower()
        project_id = f"{repo_name}--{secrets.token_hex(6)}"
    if not PROJECT_ID_RE.fullmatch(project_id):
        raise SystemExit("project_id must end with -- followed by 12 lowercase hex characters")

    repo_names = {repository.lower()}
    if old_repository:
        repo_names.add(old_repository.lower())

    kept: list[dict] = []
    for item in deployments:
        if not isinstance(item, dict):
            kept.append(item)
            continue
        same_project = item.get("project_id") == project_id
        same_repo_branch = (
            str(item.get("repository", "")).lower() in repo_names
            and item.get("branch") in {"homolog", "main", "vps-deployer-smoke"}
        )
        if same_project or same_repo_branch:
            continue
        kept.append(item)

    for branch, environment in (("homolog", "homolog"), ("main", "production")):
        kept.append(
            {
                "project_id": project_id,
                "repository": repository,
                "branch": branch,
                "command": ["sudo", "-n", ADAPTER, project_id, environment],
                "timeout_seconds": 3600,
                "enabled": True,
            }
        )

    data["deployments"] = kept
    temp = CONFIG.with_suffix(".json.tmp")
    temp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(temp, 0o640)
    os.chown(temp, 0, _group_id("vps-deployer"))
    temp.replace(CONFIG)

    for environment in ("homolog", "production"):
        path = WORKSPACES / project_id / environment
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o750)
        os.chown(path, 0, _group_id("vps-deployer"))

    print(f"project_id={project_id}")
    if old_repository:
        print(f"repository_transfer={old_repository}->{repository}")
    else:
        print(f"repository={repository}")
    print("branches=homolog,main")
    print(f"workspace={WORKSPACES / project_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
