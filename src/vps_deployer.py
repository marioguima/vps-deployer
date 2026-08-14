#!/usr/bin/env python3
"""Small, dependency-free GitHub webhook deploy agent for a VPS."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import logging
import os
import signal
import sqlite3
import subprocess
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

LOG = logging.getLogger("vps-deployer")
ZERO_SHA = "0" * 40


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value or ""


@dataclass(frozen=True)
class Settings:
    secret: str
    bind: str
    port: int
    config_path: Path
    db_path: Path
    log_dir: Path
    max_body_bytes: int

    @classmethod
    def from_env(cls) -> "Settings":
        secret = env("VPS_DEPLOYER_WEBHOOK_SECRET", required=True)
        if len(secret) < 24 or secret.startswith("CHANGE_ME"):
            raise RuntimeError("VPS_DEPLOYER_WEBHOOK_SECRET must be a strong secret (at least 24 characters)")
        return cls(
            secret=secret,
            bind=env("VPS_DEPLOYER_BIND", "127.0.0.1"),
            port=int(env("VPS_DEPLOYER_PORT", "9100")),
            config_path=Path(env("VPS_DEPLOYER_CONFIG", "/etc/vps-deployer/projects.json")),
            db_path=Path(env("VPS_DEPLOYER_DB", "/var/lib/vps-deployer/jobs.sqlite3")),
            log_dir=Path(env("VPS_DEPLOYER_LOG_DIR", "/var/log/vps-deployer")),
            max_body_bytes=int(env("VPS_DEPLOYER_MAX_BODY_BYTES", str(1024 * 1024))),
        )


@dataclass(frozen=True)
class Target:
    repository: str
    branch: str
    command: tuple[str, ...]
    timeout_seconds: int
    enabled: bool = True

    @property
    def ref(self) -> str:
        return f"refs/heads/{self.branch}"


def load_targets(path: Path) -> dict[tuple[str, str], Target]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RuntimeError(f"Deployment registry not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON in deployment registry {path}: {exc}") from exc
    deployments = raw.get("deployments")
    if not isinstance(deployments, list):
        raise RuntimeError("projects.json must contain a 'deployments' array")
    targets: dict[tuple[str, str], Target] = {}
    for i, item in enumerate(deployments):
        if not isinstance(item, dict):
            raise RuntimeError(f"deployments[{i}] must be an object")
        repository = item.get("repository")
        branch = item.get("branch")
        command = item.get("command")
        enabled = item.get("enabled", True)
        timeout = item.get("timeout_seconds", 1800)
        if not isinstance(repository, str) or "/" not in repository:
            raise RuntimeError(f"deployments[{i}].repository must be 'owner/repo'")
        if not isinstance(branch, str) or not branch:
            raise RuntimeError(f"deployments[{i}].branch must be a non-empty string")
        if not isinstance(command, list) or not command or not all(isinstance(v, str) and v for v in command):
            raise RuntimeError(f"deployments[{i}].command must be a non-empty string array")
        if not isinstance(enabled, bool):
            raise RuntimeError(f"deployments[{i}].enabled must be boolean")
        if not isinstance(timeout, int) or timeout < 1:
            raise RuntimeError(f"deployments[{i}].timeout_seconds must be a positive integer")
        key = (repository.lower(), f"refs/heads/{branch}")
        if key in targets:
            raise RuntimeError(f"Duplicate deployment mapping for {repository}@{branch}")
        targets[key] = Target(repository, branch, tuple(command), timeout, enabled)
    return targets


class JobStore:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def _init_db(self) -> None:
        with self.connect() as conn:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    delivery_id TEXT NOT NULL UNIQUE,
                    repository TEXT NOT NULL,
                    ref TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    sha TEXT NOT NULL,
                    sender TEXT,
                    command_json TEXT NOT NULL,
                    timeout_seconds INTEGER NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('queued','running','succeeded','failed')),
                    attempts INTEGER NOT NULL DEFAULT 0,
                    received_at TEXT NOT NULL,
                    started_at TEXT,
                    finished_at TEXT,
                    exit_code INTEGER,
                    error TEXT,
                    log_path TEXT
                );
                CREATE INDEX IF NOT EXISTS jobs_status_id_idx ON jobs(status, id);
                CREATE INDEX IF NOT EXISTS jobs_repo_ref_idx ON jobs(repository, ref, id);
            """)
            conn.execute("UPDATE jobs SET status='queued', started_at=NULL, error='requeued after deployer restart' WHERE status='running'")

    def enqueue(self, *, delivery_id: str, repository: str, ref: str, branch: str, sha: str, sender: str, target: Target) -> tuple[bool, int | None]:
        with self.connect() as conn:
            try:
                cur = conn.execute("""
                    INSERT INTO jobs (delivery_id, repository, ref, branch, sha, sender, command_json, timeout_seconds, status, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?)
                """, (delivery_id, repository, ref, branch, sha, sender, json.dumps(list(target.command)), target.timeout_seconds, utcnow()))
                return True, int(cur.lastrowid)
            except sqlite3.IntegrityError:
                row = conn.execute("SELECT id FROM jobs WHERE delivery_id=?", (delivery_id,)).fetchone()
                return False, int(row["id"]) if row else None

    def claim_next(self) -> sqlite3.Row | None:
        with self.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM jobs WHERE status='queued' ORDER BY id LIMIT 1").fetchone()
            if row is None:
                conn.execute("COMMIT")
                return None
            conn.execute("UPDATE jobs SET status='running', attempts=attempts+1, started_at=?, finished_at=NULL, error=NULL WHERE id=?", (utcnow(), row["id"]))
            conn.execute("COMMIT")
            return conn.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone()

    def finish(self, job_id: int, *, status: str, exit_code: int | None, error: str | None, log_path: str) -> None:
        with self.connect() as conn:
            conn.execute("UPDATE jobs SET status=?, finished_at=?, exit_code=?, error=?, log_path=? WHERE id=?", (status, utcnow(), exit_code, error, log_path, job_id))

    def retry(self, job_id: int) -> bool:
        with self.connect() as conn:
            cur = conn.execute("UPDATE jobs SET status='queued', started_at=NULL, finished_at=NULL, exit_code=NULL, error=NULL WHERE id=? AND status='failed'", (job_id,))
            return cur.rowcount == 1

    def list_jobs(self, limit: int = 30) -> list[sqlite3.Row]:
        with self.connect() as conn:
            return list(conn.execute("SELECT * FROM jobs ORDER BY id DESC LIMIT ?", (limit,)).fetchall())


class Worker(threading.Thread):
    daemon = True

    def __init__(self, settings: Settings, store: JobStore, wake: threading.Event, stop: threading.Event) -> None:
        super().__init__(name="deploy-worker")
        self.settings = settings
        self.store = store
        self.wake = wake
        self.stop_event = stop

    def run(self) -> None:
        LOG.info("deploy worker started; jobs are serialized globally")
        while not self.stop_event.is_set():
            job = self.store.claim_next()
            if job is None:
                self.wake.wait(timeout=2.0)
                self.wake.clear()
                continue
            self.execute(job)

    def execute(self, job: sqlite3.Row) -> None:
        job_id = int(job["id"])
        command = json.loads(job["command_json"])
        timeout = int(job["timeout_seconds"])
        self.settings.log_dir.mkdir(parents=True, exist_ok=True)
        log_path = self.settings.log_dir / f"job-{job_id}.log"
        child_env = os.environ.copy()
        child_env.update({
            "DEPLOY_JOB_ID": str(job_id), "DEPLOY_DELIVERY_ID": job["delivery_id"], "DEPLOY_REPOSITORY": job["repository"],
            "DEPLOY_REF": job["ref"], "DEPLOY_BRANCH": job["branch"], "DEPLOY_SHA": job["sha"], "DEPLOY_SENDER": job["sender"] or ""
        })
        LOG.info("job %s started: %s@%s sha=%s", job_id, job["repository"], job["branch"], job["sha"][:12])
        try:
            with log_path.open("a", encoding="utf-8") as log:
                log.write(f"[{utcnow()}] job {job_id} command={json.dumps(command)}\n")
                log.flush()
                result = subprocess.run(command, env=child_env, stdout=log, stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
            if result.returncode == 0:
                self.store.finish(job_id, status="succeeded", exit_code=0, error=None, log_path=str(log_path))
                LOG.info("job %s succeeded", job_id)
            else:
                error = f"command exited with code {result.returncode}"
                self.store.finish(job_id, status="failed", exit_code=result.returncode, error=error, log_path=str(log_path))
                LOG.error("job %s failed: %s", job_id, error)
        except subprocess.TimeoutExpired:
            error = f"command timed out after {timeout}s"
            self.store.finish(job_id, status="failed", exit_code=None, error=error, log_path=str(log_path))
            LOG.error("job %s failed: %s", job_id, error)
        except Exception as exc:
            error = f"execution error: {exc}"
            self.store.finish(job_id, status="failed", exit_code=None, error=error, log_path=str(log_path))
            LOG.exception("job %s failed unexpectedly", job_id)


class App:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.store = JobStore(settings.db_path)
        self.wake = threading.Event()
        self.stop = threading.Event()
        self.worker = Worker(settings, self.store, self.wake, self.stop)

    def resolve_target(self, repository: str, ref: str) -> Target | None:
        target = load_targets(self.settings.config_path).get((repository.lower(), ref))
        return target if target and target.enabled else None

    def verify_signature(self, body: bytes, supplied: str) -> bool:
        expected = "sha256=" + hmac.new(self.settings.secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
        return bool(supplied) and hmac.compare_digest(expected, supplied)


class Handler(BaseHTTPRequestHandler):
    server_version = "VPSDeployer/1.0"

    @property
    def app(self) -> App:
        return self.server.app  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        LOG.info("http %s - %s", self.address_string(), fmt % args)

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"ok": True, "service": "vps-deployer", "time": utcnow()})
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path != "/github":
            self.send_json(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_json(400, {"error": "invalid_content_length"})
            return
        if length < 0 or length > self.app.settings.max_body_bytes:
            self.send_json(413, {"error": "payload_too_large"})
            return
        body = self.rfile.read(length)
        if not self.app.verify_signature(body, self.headers.get("X-Hub-Signature-256", "")):
            self.send_json(401, {"error": "invalid_signature"})
            return
        event = self.headers.get("X-GitHub-Event", "")
        delivery_id = self.headers.get("X-GitHub-Delivery", "")
        if not delivery_id:
            self.send_json(400, {"error": "missing_delivery_id"})
            return
        if event == "ping":
            self.send_json(200, {"ok": True, "event": "ping"})
            return
        if event != "push":
            self.send_json(202, {"accepted": False, "reason": "event_ignored", "event": event})
            return
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid_json"})
            return
        repository = ((payload.get("repository") or {}).get("full_name") or "").strip()
        ref = (payload.get("ref") or "").strip()
        sha = (payload.get("after") or "").strip()
        sender = ((payload.get("sender") or {}).get("login") or "").strip()
        deleted = bool(payload.get("deleted")) or sha == ZERO_SHA
        if not repository or not ref or not sha:
            self.send_json(400, {"error": "missing_push_fields"})
            return
        if len(sha) != 40 or any(ch not in "0123456789abcdefABCDEF" for ch in sha):
            self.send_json(400, {"error": "invalid_sha"})
            return
        if deleted:
            self.send_json(202, {"accepted": False, "reason": "deleted_ref_ignored"})
            return
        try:
            target = self.app.resolve_target(repository, ref)
        except RuntimeError as exc:
            LOG.error("registry error: %s", exc)
            self.send_json(503, {"error": "registry_unavailable"})
            return
        if target is None:
            self.send_json(202, {"accepted": False, "reason": "no_deployment_mapping", "repository": repository, "ref": ref})
            return
        branch = ref.removeprefix("refs/heads/") if ref.startswith("refs/heads/") else ref
        inserted, job_id = self.app.store.enqueue(delivery_id=delivery_id, repository=repository, ref=ref, branch=branch, sha=sha, sender=sender, target=target)
        if inserted:
            self.app.wake.set()
            LOG.info("queued job %s for %s@%s sha=%s delivery=%s", job_id, repository, branch, sha[:12], delivery_id)
        self.send_json(202, {"accepted": True, "queued": inserted, "job_id": job_id})


def configure_logging() -> None:
    logging.basicConfig(level=os.environ.get("VPS_DEPLOYER_LOG_LEVEL", "INFO").upper(), format="%(asctime)s %(levelname)s %(name)s %(message)s")


def serve(settings: Settings) -> int:
    settings.log_dir.mkdir(parents=True, exist_ok=True)
    app = App(settings)
    load_targets(settings.config_path)
    app.worker.start()
    server = ThreadingHTTPServer((settings.bind, settings.port), Handler)
    server.app = app  # type: ignore[attr-defined]
    server.daemon_threads = True

    def request_stop(signum: int, _frame: Any) -> None:
        LOG.info("signal %s received; shutting down", signum)
        app.stop.set(); app.wake.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    LOG.info("listening on %s:%s", settings.bind, settings.port)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        app.stop.set(); app.wake.set(); server.server_close(); app.worker.join(timeout=10)
    return 0


def doctor(settings: Settings) -> int:
    failures: list[str] = []
    try:
        targets = load_targets(settings.config_path)
        print(f"OK registry: {settings.config_path} ({len(targets)} mappings)")
    except Exception as exc:
        failures.append(str(exc)); print(f"FAIL registry: {exc}")
    print("OK webhook secret configured")
    for path, label in ((settings.db_path.parent, "state directory"), (settings.log_dir, "log directory")):
        try:
            path.mkdir(parents=True, exist_ok=True)
            probe = path / ".write-test"; probe.write_text("ok", encoding="utf-8"); probe.unlink()
            print(f"OK {label}: {path}")
        except Exception as exc:
            failures.append(f"{label}: {exc}"); print(f"FAIL {label}: {exc}")
    return 1 if failures else 0


def list_jobs(settings: Settings, limit: int) -> int:
    rows = JobStore(settings.db_path).list_jobs(limit)
    print("ID\tSTATUS\tREPOSITORY\tBRANCH\tSHA\tRECEIVED")
    for row in rows:
        print(f"{row['id']}\t{row['status']}\t{row['repository']}\t{row['branch']}\t{row['sha'][:12]}\t{row['received_at']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    configure_logging()
    parser = argparse.ArgumentParser(description="Global GitHub webhook deploy agent for a VPS")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("serve"); sub.add_parser("doctor")
    jobs = sub.add_parser("jobs"); jobs.add_argument("--limit", type=int, default=30)
    retry_parser = sub.add_parser("retry"); retry_parser.add_argument("job_id", type=int)
    args = parser.parse_args(argv)
    settings = Settings.from_env()
    if args.command == "serve": return serve(settings)
    if args.command == "doctor": return doctor(settings)
    if args.command == "jobs": return list_jobs(settings, args.limit)
    if args.command == "retry":
        ok = JobStore(settings.db_path).retry(args.job_id)
        print("queued" if ok else "job not found or not failed")
        return 0 if ok else 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
