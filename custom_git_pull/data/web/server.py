#!/usr/bin/env python3
"""Web UI server for Custom Git Pull addon."""

import asyncio
import json
import os
import subprocess
import time
from pathlib import Path

from aiohttp import web

EVENTS_FILE = Path("/data/events.jsonl")
LOG_FILE = Path("/config/.git_pull.log")
BACKUP_DIR = Path("/config/.git_pull_backups")
STAGING_DIR = Path("/config/.git_sync_repo")
OPTIONS_FILE = Path("/data/options.json")
TRIGGER_FILE = Path("/tmp/webhook_trigger")
RESTORE_FILE = Path("/tmp/restore_request")
WEB_DIR = Path(__file__).parent

SUPERVISOR_TOKEN = os.environ.get("SUPERVISOR_TOKEN", "")
SUPERVISOR_URL = "http://supervisor"

routes = web.RouteTableDef()


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

@routes.get("/")
async def index(request):
    html = (WEB_DIR / "index.html").read_text()
    ingress_path = request.headers.get("X-Ingress-Path", "")
    html = html.replace("{{INGRESS_PATH}}", ingress_path)
    return web.Response(text=html, content_type="text/html")


# ---------------------------------------------------------------------------
# API -- Status
# ---------------------------------------------------------------------------

@routes.get("/api/status")
async def api_status(request):
    result = {
        "state": "idle",
        "commit": None,
        "commit_full": None,
        "branch": None,
        "repo": None,
        "commit_message": None,
        "commit_author": None,
        "commit_date": None,
        "recent_commits": [],
        "last_sync": None,
        "last_sync_files": [],
        "stats": {"total_syncs": 0, "successful": 0, "failed": 0, "no_changes": 0, "backups": 0},
    }

    # Git info from staging repo
    if (STAGING_DIR / ".git").is_dir():
        git_cmds = {
            "commit": ["git", "rev-parse", "--short", "HEAD"],
            "commit_full": ["git", "rev-parse", "HEAD"],
            "branch": ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            "commit_message": ["git", "log", "-1", "--format=%s"],
            "commit_author": ["git", "log", "-1", "--format=%an"],
            "commit_date": ["git", "log", "-1", "--format=%aI"],
        }
        for key, cmd in git_cmds.items():
            try:
                result[key] = subprocess.check_output(
                    cmd, cwd=str(STAGING_DIR), text=True, timeout=5
                ).strip()
            except Exception:
                pass

        # Recent commits
        try:
            log_out = subprocess.check_output(
                ["git", "log", "--oneline", "-10"],
                cwd=str(STAGING_DIR), text=True, timeout=5,
            ).strip()
            result["recent_commits"] = [
                {"hash": parts[0], "message": " ".join(parts[1:])}
                for line in log_out.splitlines()
                if (parts := line.split()) and len(parts) >= 2
            ]
        except Exception:
            pass

    # Config info
    try:
        opts = json.loads(OPTIONS_FILE.read_text())
        result["repo"] = opts.get("repository", "")
        result["configured_branch"] = opts.get("git_branch", "main")
    except Exception:
        pass

    # Stats and last sync from events
    events = _read_events()
    for e in events:
        t = e.get("type", "")
        if t == "sync_complete":
            result["stats"]["total_syncs"] += 1
            result["stats"]["successful"] += 1
        elif t == "sync_no_changes":
            result["stats"]["total_syncs"] += 1
            result["stats"]["no_changes"] += 1
        elif t == "sync_failed":
            result["stats"]["total_syncs"] += 1
            result["stats"]["failed"] += 1
        elif t == "backup_created":
            result["stats"]["backups"] += 1

    for e in reversed(events):
        if e.get("type") in ("sync_complete", "sync_failed", "sync_no_changes"):
            result["last_sync"] = e
            if e.get("files_changed"):
                result["last_sync_files"] = [
                    f.strip() for f in e["files_changed"].split(",") if f.strip()
                ]
            else:
                result["last_sync_files"] = []
            break

    # Syncing state check
    lock = Path("/tmp/git_pull.lock")
    if lock.exists():
        try:
            # flock leaves the file; check if fd is actually held
            fd = os.open(str(lock), os.O_RDONLY)
            import fcntl
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
            except (OSError, IOError):
                result["state"] = "syncing"
            finally:
                os.close(fd)
        except Exception:
            pass

    return web.json_response(result)


# ---------------------------------------------------------------------------
# API -- Events
# ---------------------------------------------------------------------------

@routes.get("/api/events")
async def api_events(request):
    limit = int(request.query.get("limit", "200"))
    type_filter = request.query.get("type", "")
    events = _read_events()
    if type_filter:
        types = set(type_filter.split(","))
        events = [e for e in events if e.get("type") in types]
    return web.json_response(events[-limit:])


# ---------------------------------------------------------------------------
# API -- Log
# ---------------------------------------------------------------------------

@routes.get("/api/log")
async def api_log(request):
    lines = int(request.query.get("lines", "500"))
    try:
        all_lines = LOG_FILE.read_text().splitlines()
        return web.json_response({"lines": all_lines[-lines:]})
    except Exception:
        return web.json_response({"lines": []})


# ---------------------------------------------------------------------------
# API -- Backups
# ---------------------------------------------------------------------------

@routes.get("/api/backups")
async def api_backups(request):
    result = []
    if BACKUP_DIR.is_dir():
        for entry in sorted(
            BACKUP_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True
        ):
            if entry.is_dir():
                try:
                    size = subprocess.check_output(
                        ["du", "-sh", str(entry)], text=True, timeout=10
                    ).split()[0]
                except Exception:
                    size = "?"
                result.append({
                    "name": entry.name,
                    "path": str(entry),
                    "size": size,
                    "timestamp": entry.stat().st_mtime,
                })
    return web.json_response(result)


# ---------------------------------------------------------------------------
# API -- Config (read)
# ---------------------------------------------------------------------------

@routes.get("/api/config")
async def api_config_get(request):
    try:
        opts = json.loads(OPTIONS_FILE.read_text())
        # Redact secrets for display
        if opts.get("deployment_password"):
            opts["_has_password"] = True
            opts["deployment_password"] = ""
        if opts.get("deployment_key") and any(opts["deployment_key"]):
            opts["_has_key"] = True
            opts["deployment_key"] = []
        if opts.get("webhook", {}).get("secret"):
            opts["_has_webhook_secret"] = True
            opts["webhook"]["secret"] = ""
        return web.json_response(opts)
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


# ---------------------------------------------------------------------------
# API -- Config (update)
# ---------------------------------------------------------------------------

@routes.post("/api/config")
async def api_config_post(request):
    data = await request.json()
    try:
        current = json.loads(OPTIONS_FILE.read_text())
    except Exception:
        return web.json_response({"ok": False, "error": "Cannot read config"}, status=500)

    allowed = {
        "repository", "git_branch", "git_remote", "git_command",
        "auto_restart", "git_prune", "deploy_delete", "deploy_dry_run",
        "mirror_protect_user_dirs", "allow_legacy_config_git_dir",
        "push_custom_components", "push_on_start",
        "restart_ignore", "repeat", "webhook",
        "deployment_user", "deployment_password",
        "deployment_key", "deployment_key_protocol",
    }

    for key, value in data.items():
        if key in allowed:
            current[key] = value

    headers = {
        "Authorization": f"Bearer {SUPERVISOR_TOKEN}",
        "Content-Type": "application/json",
    }
    try:
        proc = await asyncio.create_subprocess_exec(
            "curl", "-s", "-X", "POST",
            "-H", f"Authorization: Bearer {SUPERVISOR_TOKEN}",
            "-H", "Content-Type: application/json",
            "-d", json.dumps({"options": current}),
            f"{SUPERVISOR_URL}/addons/self/options",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await proc.communicate()
        result = json.loads(stdout)
        if result.get("result") == "ok":
            return web.json_response({"ok": True, "restart_required": True})
        return web.json_response({"ok": False, "error": str(result)}, status=400)
    except Exception as e:
        return web.json_response({"ok": False, "error": str(e)}, status=500)


# ---------------------------------------------------------------------------
# API -- Actions
# ---------------------------------------------------------------------------

@routes.post("/api/sync")
async def api_sync(request):
    TRIGGER_FILE.touch()
    _emit_event("sync_requested", trigger="web_ui")
    return web.json_response({"ok": True})


@routes.post("/api/restore")
async def api_restore(request):
    data = await request.json()
    path = data.get("path", "")
    real = os.path.realpath(path)
    backup_real = os.path.realpath(str(BACKUP_DIR))
    if not real.startswith(backup_real + "/"):
        return web.json_response({"ok": False, "error": "Invalid backup path"}, status=400)
    if not os.path.isdir(real):
        return web.json_response({"ok": False, "error": "Backup not found"}, status=404)
    RESTORE_FILE.write_text(real)
    return web.json_response({"ok": True, "message": "Restore queued"})


@routes.post("/api/restart")
async def api_restart(request):
    try:
        proc = await asyncio.create_subprocess_exec(
            "curl", "-s", "-X", "POST",
            "-H", f"Authorization: Bearer {SUPERVISOR_TOKEN}",
            f"{SUPERVISOR_URL}/addons/self/restart",
            stdout=asyncio.subprocess.PIPE,
        )
        await proc.communicate()
        return web.json_response({"ok": True})
    except Exception as e:
        return web.json_response({"ok": False, "error": str(e)}, status=500)


@routes.post("/api/validate-key")
async def api_validate_key(request):
    """Validate an SSH key without saving it."""
    data = await request.json()
    key_text = data.get("key", "").strip()
    if not key_text:
        return web.json_response({"valid": False, "error": "Empty key"})

    tmp = Path("/tmp/validate_key_tmp")
    try:
        tmp.write_text(key_text + "\n")
        tmp.chmod(0o600)
        result = subprocess.run(
            ["ssh-keygen", "-l", "-f", str(tmp)],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return web.json_response({
                "valid": True,
                "fingerprint": result.stdout.strip(),
            })
        return web.json_response({
            "valid": False,
            "error": result.stderr.strip() or "Invalid key format",
        })
    except Exception as e:
        return web.json_response({"valid": False, "error": str(e)})
    finally:
        tmp.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _read_events():
    events = []
    try:
        for line in EVENTS_FILE.read_text().splitlines():
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except FileNotFoundError:
        pass
    return events


def _emit_event(event_type, **data):
    event = {"ts": int(time.time()), "type": event_type, **data}
    with open(EVENTS_FILE, "a") as f:
        f.write(json.dumps(event) + "\n")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = web.Application()
app.add_routes(routes)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=8099)
