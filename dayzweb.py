#!/usr/bin/env python3
"""Web GUI for the DayZ Linux Server Manager.

Serves a dashboard that drives dayzserver.sh: start/stop/restart, a live
console, mod management, config editing, log browsing and backups.

Deliberately built on the Python standard library alone - no pip install, no
build step, no node_modules. A DayZ server box is usually a bare VPS, and the
whole point of this file is that it runs there as-is.

Security posture:
  * Binds 127.0.0.1 by default. Anything that can reach this page can stop
    your server and wipe your players, so it stays local unless the operator
    explicitly opts into exposing it.
  * Password login, stored as a PBKDF2-HMAC-SHA256 hash in config.ini.
  * Session cookies are HttpOnly + SameSite=Strict with a server-side expiry.
  * Every mutating request needs a CSRF token.
  * Login attempts are rate limited per client address.
  * Server commands come from a fixed allowlist and are executed with a
    list argv - never a shell string built from user input.

Run it with `./dayzserver.sh web start`, or directly with `python3 dayzweb.py`.
"""

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HOME = Path(os.environ.get("DAYZ_HOME", Path.home()))
SCRIPT = HOME / "dayzserver.sh"
CONFIG_FILE = HOME / "config.ini"
WORKSHOP_CFG = HOME / "workshop.cfg"
UI_FILE = Path(__file__).resolve().parent / "webui" / "index.html"

SESSION_TTL = 8 * 60 * 60          # seconds a login stays valid
LOGIN_MAX_ATTEMPTS = 5             # failures before an address is locked out
LOGIN_LOCKOUT = 5 * 60             # how long that lockout lasts
PBKDF2_ROUNDS = 240_000

# Commands the GUI is allowed to run. The browser sends only the key; the
# argv comes from here, so a crafted request cannot reach anything else.
CONTROL_COMMANDS = {
    "start": ["start"],
    "stop": ["stop"],
    "restart": ["restart"],
    "update": ["update"],
    "validate": ["validate"],
    "workshop": ["workshop"],
    "checkmods": ["checkmods"],
    "updateconfig": ["updateconfig"],
    "backup": ["backup"],
    "cleancache": ["cleancache"],
}

# Config files the GUI may read and write, by the name the browser uses.
EDITABLE_FILES = {
    "config.ini": CONFIG_FILE,
    "workshop.cfg": WORKSHOP_CFG,
    "serverDZ.cfg": None,   # resolved at request time from the `config` setting
}

# Settings that must never be sent to the browser.
SECRET_KEYS = {"steamlogin", "web_password_hash", "discord_webhook_url"}


# ---------------------------------------------------------------------------
# Config handling
# ---------------------------------------------------------------------------

def read_config():
    """Parse config.ini into a dict.

    It is a shell file sourced by bash, but the subset we care about is plain
    key=value, so a regex read avoids executing anything.
    """
    values = {}
    if not CONFIG_FILE.exists():
        return values
    for line in CONFIG_FILE.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if not match:
            continue
        key, raw = match.group(1), match.group(2).strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
            raw = raw[1:-1]
        values[key] = raw
    return values


def write_config_value(key, value):
    """Set key=value in config.ini, replacing any existing line for that key."""
    lines = CONFIG_FILE.read_text(errors="replace").splitlines() if CONFIG_FILE.exists() else []
    pattern = re.compile(r'^[ \t]*#?[ \t]*' + re.escape(key) + r'=')
    replaced = False
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = f'{key}="{value}"'
            replaced = True
            break
    if not replaced:
        lines.append(f'{key}="{value}"')
    CONFIG_FILE.write_text("\n".join(lines) + "\n")
    CONFIG_FILE.chmod(0o600)


# ---------------------------------------------------------------------------
# Password handling
# ---------------------------------------------------------------------------

def hash_password(password, salt=None):
    """PBKDF2-HMAC-SHA256. Returns 'pbkdf2$<rounds>$<salt>$<hash>'."""
    if salt is None:
        salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ROUNDS)
    return "pbkdf2${}${}${}".format(
        PBKDF2_ROUNDS,
        base64.b64encode(salt).decode(),
        base64.b64encode(digest).decode(),
    )


def verify_password(password, stored):
    """Constant-time check of a password against a stored hash."""
    try:
        scheme, rounds, salt_b64, hash_b64 = stored.split("$")
        if scheme != "pbkdf2":
            return False
        digest = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), base64.b64decode(salt_b64), int(rounds)
        )
        return hmac.compare_digest(digest, base64.b64decode(hash_b64))
    except (ValueError, TypeError):
        return False


def ensure_password(config):
    """Return the stored password hash, generating a password on first run.

    A freshly installed GUI has no credentials. Rather than starting wide open
    or refusing to run, it mints a random password, prints it once, and stores
    only its hash.
    """
    stored = config.get("web_password_hash", "")
    if stored:
        return stored
    password = secrets.token_urlsafe(12)
    stored = hash_password(password)
    write_config_value("web_password_hash", stored)
    print("=" * 68, flush=True)
    print("  A web GUI password has been generated for you:", flush=True)
    print(f"\n      {password}\n", flush=True)
    print("  It is shown once and stored only as a hash. Change it from the", flush=True)
    print("  GUI, or delete web_password_hash from config.ini to reset it.", flush=True)
    print("=" * 68, flush=True)
    return stored


# ---------------------------------------------------------------------------
# Session and rate-limit state
# ---------------------------------------------------------------------------

class SessionStore:
    """In-memory sessions. Restarting the GUI logs everyone out, which is the
    right trade for not persisting credentials to disk."""

    def __init__(self):
        self._lock = threading.Lock()
        self._sessions = {}

    def create(self):
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._sessions[token] = {
                "expires": time.time() + SESSION_TTL,
                "csrf": secrets.token_urlsafe(32),
            }
        return token, self._sessions[token]["csrf"]

    def get(self, token):
        if not token:
            return None
        with self._lock:
            session = self._sessions.get(token)
            if not session:
                return None
            if session["expires"] < time.time():
                del self._sessions[token]
                return None
            return session

    def destroy(self, token):
        with self._lock:
            self._sessions.pop(token, None)


class RateLimiter:
    """Per-address failed-login counter with a lockout window."""

    def __init__(self):
        self._lock = threading.Lock()
        self._attempts = {}

    def locked_out(self, key):
        with self._lock:
            record = self._attempts.get(key)
            if not record:
                return 0
            count, first = record
            if time.time() - first > LOGIN_LOCKOUT:
                del self._attempts[key]
                return 0
            if count >= LOGIN_MAX_ATTEMPTS:
                return int(LOGIN_LOCKOUT - (time.time() - first))
            return 0

    def record_failure(self, key):
        with self._lock:
            count, first = self._attempts.get(key, (0, time.time()))
            self._attempts[key] = (count + 1, first)

    def clear(self, key):
        with self._lock:
            self._attempts.pop(key, None)


SESSIONS = SessionStore()
LIMITER = RateLimiter()

# Only one server command runs at a time. Two concurrent `start` clicks would
# otherwise race over the same tmux session and lock files.
COMMAND_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Running dayzserver.sh
# ---------------------------------------------------------------------------

def run_script(args, timeout=1800):
    """Run dayzserver.sh with the given arguments.

    argv is passed as a list, so nothing here goes through a shell.
    """
    if not SCRIPT.exists():
        return {"ok": False, "output": f"{SCRIPT} not found", "code": 127}
    env = dict(os.environ)
    env["ansi"] = "off"          # strip colour codes; the page styles its own
    env["HOME"] = str(HOME)
    try:
        proc = subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=str(HOME), env=env, timeout=timeout,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        return {
            "ok": proc.returncode == 0,
            "output": proc.stdout.decode(errors="replace"),
            "code": proc.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": f"Command timed out after {timeout}s", "code": 124}
    except OSError as exc:
        return {"ok": False, "output": str(exc), "code": 1}


def get_status():
    """Server status as a dict, from `dayzserver.sh status --json`."""
    result = run_script(["status", "--json"], timeout=30)
    # The script prints progress lines before the JSON; the payload is the
    # last non-empty line.
    for line in reversed(result["output"].splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                break
    return {"running": False, "error": "status unavailable", "raw": result["output"][-2000:]}


def serverdz_path():
    """Absolute path of serverDZ.cfg, whose name is configurable."""
    config = read_config()
    return HOME / "serverfiles" / config.get("config", "serverDZ.cfg")


def resolve_editable(name):
    """Map a browser-supplied file name to a path, or None if not allowed."""
    if name not in EDITABLE_FILES:
        return None
    if name == "serverDZ.cfg":
        return serverdz_path()
    return EDITABLE_FILES[name]


def tail_file(path, lines=400, max_bytes=256 * 1024):
    """Last N lines of a file, reading only the tail of it.

    Server RPT logs reach hundreds of megabytes, so reading the whole file to
    show its end is not an option.
    """
    try:
        size = path.stat().st_size
    except OSError:
        return ""
    with open(path, "rb") as handle:
        if size > max_bytes:
            handle.seek(size - max_bytes)
            handle.readline()      # discard the partial first line
        data = handle.read()
    return "\n".join(data.decode(errors="replace").splitlines()[-lines:])


def list_backups():
    backup_dir = HOME / "backup"
    if not backup_dir.is_dir():
        return []
    entries = []
    for path in sorted(backup_dir.glob("*.tar"), key=lambda p: p.stat().st_mtime, reverse=True):
        stat = path.stat()
        entries.append({
            "name": path.name,
            "size": stat.st_size,
            "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
        })
    return entries


def list_crashlogs():
    crash_dir = HOME / "crashlogs"
    if not crash_dir.is_dir():
        return []
    entries = []
    for path in sorted(crash_dir.iterdir(), reverse=True)[:30]:
        if path.is_dir():
            entries.append({
                "name": path.name,
                "files": sorted(p.name for p in path.iterdir() if p.is_file()),
            })
    return entries


def list_mods():
    """Mods from workshop.cfg, annotated with whether they are installed."""
    config = read_config()
    dayz_id = config.get("dayz_id", "221100")
    content = HOME / "serverfiles" / "steamapps" / "workshop" / "content" / dayz_id
    mods = []
    if not WORKSHOP_CFG.exists():
        return mods
    for line in WORKSHOP_CFG.read_text(errors="replace").splitlines():
        line = line.replace("\r", "").strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        mod_id = parts[0]
        if not mod_id.isdigit():
            continue
        name = parts[1].strip() if len(parts) > 1 else ""
        link = "@" + name.lower().replace(" ", "_") if name else ""
        mods.append({
            "id": mod_id,
            "name": name,
            "link": link,
            "downloaded": (content / mod_id / "meta.cpp").exists(),
            "linked": bool(link) and (HOME / "serverfiles" / link).exists(),
            "url": f"https://steamcommunity.com/sharedfiles/filedetails/?id={mod_id}",
        })
    return mods


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "DayZManager"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # -- helpers ----------------------------------------------------------

    def log_message(self, fmt, *args):
        # One compact line per request; the default logs are noisy and leak
        # query strings into the journal.
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body=b"", content_type="application/json", extra_headers=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # This page is entirely self-contained; forbid anything external and
        # refuse to be framed.
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
            "img-src data:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'"
        )
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra_headers or {}):
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, payload, code=200, extra_headers=None):
        self._send(code, json.dumps(payload), "application/json", extra_headers)

    def _cookies(self):
        raw = self.headers.get("Cookie", "")
        jar = {}
        for part in raw.split(";"):
            if "=" in part:
                key, value = part.split("=", 1)
                jar[key.strip()] = value.strip()
        return jar

    def _session(self):
        return SESSIONS.get(self._cookies().get("dayz_session"))

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return {}
        if length <= 0 or length > 4 * 1024 * 1024:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode())
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    def _require_auth(self):
        session = self._session()
        if not session:
            self._json({"error": "authentication required"}, 401)
            return None
        return session

    def _require_csrf(self, session, payload):
        """Reject a mutating request whose CSRF token does not match.

        SameSite=Strict already blocks the common cross-site case; this covers
        the rest and costs nothing.
        """
        token = self.headers.get("X-CSRF-Token") or payload.get("csrf", "")
        if not token or not hmac.compare_digest(token, session["csrf"]):
            self._json({"error": "invalid CSRF token"}, 403)
            return False
        return True

    # -- routing ----------------------------------------------------------

    def do_GET(self):
        route = urlparse(self.path)
        path = route.path

        if path in ("/", "/index.html"):
            return self._serve_ui()

        if not path.startswith("/api/"):
            return self._json({"error": "not found"}, 404)

        if path == "/api/session":
            session = self._session()
            if not session:
                return self._json({"authenticated": False})
            return self._json({"authenticated": True, "csrf": session["csrf"]})

        session = self._require_auth()
        if not session:
            return

        if path == "/api/status":
            return self._json(get_status())

        if path == "/api/console":
            return self._json({"content": tail_file(HOME / "tmux.log", 500)})

        if path == "/api/mods":
            return self._json({"mods": list_mods()})

        if path == "/api/config":
            name = parse_qs(route.query).get("file", [""])[0]
            target = resolve_editable(name)
            if target is None:
                return self._json({"error": "unknown file"}, 400)
            content = target.read_text(errors="replace") if target.exists() else ""
            if name == "config.ini":
                content = redact_config(content)
            return self._json({"file": name, "content": content, "exists": target.exists()})

        if path == "/api/logs":
            which = parse_qs(route.query).get("which", ["monitor"])[0]
            return self._json(read_log(which))

        if path == "/api/backups":
            return self._json({"backups": list_backups(), "crashlogs": list_crashlogs()})

        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        payload = self._body()

        if path == "/api/login":
            return self._handle_login(payload)

        session = self._require_auth()
        if not session:
            return
        if not self._require_csrf(session, payload):
            return

        if path == "/api/logout":
            SESSIONS.destroy(self._cookies().get("dayz_session"))
            return self._json({"ok": True}, extra_headers=[
                ("Set-Cookie", "dayz_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")
            ])

        if path == "/api/control":
            return self._handle_control(payload)

        if path == "/api/mods":
            return self._handle_mods(payload)

        if path == "/api/config":
            return self._handle_config_save(payload)

        if path == "/api/rcon":
            return self._handle_rcon(payload)

        if path == "/api/password":
            return self._handle_password(payload)

        return self._json({"error": "not found"}, 404)

    # -- handlers ---------------------------------------------------------

    def _serve_ui(self):
        if not UI_FILE.exists():
            return self._send(500, "webui/index.html is missing", "text/plain")
        return self._send(200, UI_FILE.read_bytes(), "text/html; charset=utf-8")

    def _handle_login(self, payload):
        key = self.client_address[0]
        remaining = LIMITER.locked_out(key)
        if remaining:
            return self._json(
                {"error": f"Too many attempts. Try again in {remaining // 60 + 1} minute(s)."},
                429,
            )

        password = payload.get("password", "")
        stored = ensure_password(read_config())
        if not isinstance(password, str) or not verify_password(password, stored):
            LIMITER.record_failure(key)
            time.sleep(0.5)     # blunt the speed of an online guessing attempt
            return self._json({"error": "Incorrect password"}, 401)

        LIMITER.clear(key)
        token, csrf = SESSIONS.create()
        return self._json({"ok": True, "csrf": csrf}, extra_headers=[
            ("Set-Cookie",
             f"dayz_session={token}; Path=/; Max-Age={SESSION_TTL}; HttpOnly; SameSite=Strict")
        ])

    def _handle_control(self, payload):
        action = payload.get("action", "")
        if action not in CONTROL_COMMANDS:
            return self._json({"error": "unknown action"}, 400)

        if not COMMAND_LOCK.acquire(blocking=False):
            return self._json({"error": "another command is already running"}, 409)
        try:
            result = run_script(CONTROL_COMMANDS[action])
        finally:
            COMMAND_LOCK.release()
        return self._json({"action": action, **result})

    def _handle_mods(self, payload):
        action = payload.get("action", "")
        value = str(payload.get("value", ""))
        # Only a workshop id is ever forwarded, and it is re-extracted here so
        # nothing else can ride along in the field.
        match = re.search(r"\d{6,}", value)
        if action in ("add", "remove"):
            if not match:
                return self._json({"error": "no workshop id found in that value"}, 400)
            result = run_script(["mods", action, match.group(0)], timeout=60)
            return self._json({**result, "mods": list_mods()})
        return self._json({"error": "unknown action"}, 400)

    def _handle_config_save(self, payload):
        name = payload.get("file", "")
        content = payload.get("content", "")
        target = resolve_editable(name)
        if target is None:
            return self._json({"error": "unknown file"}, 400)
        if not isinstance(content, str) or len(content) > 2 * 1024 * 1024:
            return self._json({"error": "invalid content"}, 400)
        if name == "config.ini" and REDACTED in content:
            return self._json(
                {"error": "config.ini still contains redacted placeholders; "
                          "edit those settings from the CLI instead"}, 400)

        target.parent.mkdir(parents=True, exist_ok=True)
        # Keep a timestamped copy: a bad edit to serverDZ.cfg stops the server
        # from starting, and the previous version is the fastest way back.
        if target.exists():
            backup = target.with_suffix(target.suffix + f".bak.{datetime.now():%Y%m%d-%H%M%S}")
            shutil.copy2(target, backup)
        target.write_text(content)
        target.chmod(0o600)
        return self._json({"ok": True, "file": name})

    def _handle_rcon(self, payload):
        command = payload.get("command", "")
        if not isinstance(command, str) or not command.strip():
            return self._json({"error": "empty command"}, 400)
        if len(command) > 200:
            return self._json({"error": "command too long"}, 400)
        # shlex.split turns the typed line into argv without a shell, so
        # metacharacters are inert rather than interpreted.
        try:
            args = shlex.split(command)
        except ValueError as exc:
            return self._json({"error": f"could not parse command: {exc}"}, 400)
        if not args:
            return self._json({"error": "empty command"}, 400)
        result = run_script(["rcon", *args], timeout=30)
        return self._json(result)

    def _handle_password(self, payload):
        current = payload.get("current", "")
        new = payload.get("new", "")
        if not isinstance(new, str) or len(new) < 8:
            return self._json({"error": "the new password must be at least 8 characters"}, 400)
        stored = read_config().get("web_password_hash", "")
        if stored and not verify_password(current, stored):
            return self._json({"error": "current password is incorrect"}, 403)
        write_config_value("web_password_hash", hash_password(new))
        return self._json({"ok": True})


REDACTED = "********"


def redact_config(content):
    """Blank out secrets before config.ini is shown in a browser."""
    out = []
    for line in content.splitlines():
        match = re.match(r'^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if match and match.group(2) in SECRET_KEYS:
            out.append(f'{match.group(1)}{match.group(2)}="{REDACTED}"')
        else:
            out.append(line)
    return "\n".join(out)


def read_log(which):
    """Return one of the known log files. `which` never becomes a path."""
    if which == "monitor":
        return {"name": "monitor.log", "content": tail_file(HOME / "monitor.log", 300)}
    if which == "web":
        return {"name": "dayzweb.log", "content": tail_file(HOME / "dayzweb.log", 300)}
    if which == "rpt":
        profile = HOME / "serverprofile"
        rpts = sorted(profile.glob("*.RPT"), key=lambda p: p.stat().st_mtime, reverse=True) \
            if profile.is_dir() else []
        if not rpts:
            return {"name": "server RPT", "content": "No .RPT log found yet."}
        return {"name": rpts[0].name, "content": tail_file(rpts[0], 400)}
    return {"name": which, "content": "Unknown log."}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    config = read_config()
    bind = os.environ.get("DAYZ_WEB_BIND", config.get("web_bind", "127.0.0.1"))
    try:
        port = int(os.environ.get("DAYZ_WEB_PORT", config.get("web_port", "8080")))
    except ValueError:
        port = 8080

    if not SCRIPT.exists():
        print(f"[FAIL] {SCRIPT} not found. Run the GUI from the server's home directory.")
        return 1

    ensure_password(config)

    try:
        server = ThreadingHTTPServer((bind, port), Handler)
    except OSError as exc:
        # "Address already in use" is by far the most common startup failure -
        # usually a GUI left running from an earlier session. A traceback is a
        # poor way to say that.
        print(f"[FAIL] Cannot listen on {bind}:{port} - {exc}")
        print("       Another process is using that port. Stop it with")
        print("       './dayzserver.sh web stop', or set web_port in config.ini.")
        return 1
    server.daemon_threads = True

    print(f"[ OK ] DayZ Server Manager web GUI on http://{bind}:{port}")
    if bind not in ("127.0.0.1", "localhost", "::1"):
        print("[WARN] This GUI is reachable from the network over plain HTTP.")
        print("       It can start, stop and wipe your server. Put it behind a")
        print("       reverse proxy with HTTPS, or bind 127.0.0.1 and use:")
        print(f"           ssh -L {port}:127.0.0.1:{port} {os.environ.get('USER', 'dayz')}@<server>")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[ OK ] Shutting down.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
