# -*- coding: utf-8 -*-
# codex_tts_watcher.py v1.8 - Automatic TTS for Claude Code (Codex) rollout JSONL sessions.
# Monitors ~/.codex/sessions and speaks completed assistant messages via Kokoro on port 59001.
# Shares the Kokoro server and TTS toggle with Claude Code TTS / Claude Cowork TTS.
#
# v1.8: Per-system voice/speed. Every utterance is tagged "SYS=codex|" so the server
#        applies the voice and speed chosen for Codex in the panel. This watcher stores
#        NO settings of its own - they live server-side in ~/.claude/tts_systems.json -
#        so a setting change needs no reload here and a restart cannot lose one.
#        Requires tts_server v3.4+; older servers ignore the tag and use the global voice.
# v1.6: Panel status endpoint on 127.0.0.1:59012 (GET /state, POST /replay, POST /mode)
#        so the Omnicapable Voice panel can show a Codex chip, replay this system, and
#        switch between Final Replies and Final + Thinking.
# v1.5: Hook removed — watcher-only. The Stop hook added double-speaking of the final
#        reply (watcher + hook both caught the same message). Watcher coverage is complete;
#        the hook provided no additional reliability benefit. Matches Cowork TTS design.
# v1.4: Per-request voice prefix — set WATCHER_VOICE = "voice_name".
# v1.3: Faster poll (0.5 s -> 0.1 s); message age filter; state pruning.
# v1.2: Single-instance lock on UDP 59003.
# v1.1: Log rotation at 1 MB.
# v1.0: Initial release.

import ctypes
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

USERPROFILE             = os.environ.get("USERPROFILE", os.path.expanduser("~"))
CODEX_HOME              = os.environ.get("CODEX_HOME", os.path.join(USERPROFILE, ".codex"))
SESSIONS_DIR            = os.path.join(CODEX_HOME, "sessions")
TOGGLE_FILE             = os.path.join(USERPROFILE, ".claude", "tts_enabled.txt")
MESSAGE_MODE_FILE       = os.path.join(USERPROFILE, ".claude", "codex_tts_message_mode.txt")
PREVIEW_HELPER          = os.path.join(USERPROFILE, ".claude", "kokoro", "tts_preview.py")
LOG_FILE                = os.path.join(os.path.dirname(os.path.abspath(__file__)), "codex_tts_watcher_log.txt")
HOST, PORT              = "127.0.0.1", 59001
POLL                    = 0.1
SCAN_INTERVAL           = 5.0
KOKORO_RETRY_SECONDS    = 15
LOG_ROTATE_BYTES        = 1_048_576
MESSAGE_MAX_AGE_SECONDS = 180
STATE_MAX_AGE_DAYS      = 7
SYSTEM_NAME             = "codex"   # v1.8: identifies this system to the server
# Defined up here (not beside the status server below) because send_to_kokoro uses
# it, and the hotkey thread can call that before the bottom of the file has run.
_CONTROL_PREFIXES = ("__STOP__", "__REPLAY__", "__PREVIEW", "__SET_", "__GET_", "__SPEAK__")
# Legacy per-watcher voice. Since v1.8 this is only a FALLBACK: a Codex voice
# picked in the panel wins over it. Left in place so hand-edited installs work.
WATCHER_VOICE           = None  # e.g. "am_adam"
DEFAULT_MESSAGE_MODE    = os.environ.get("CODEX_TTS_MESSAGE_MODE", "final").strip().lower()
ENABLE_HOTKEY = os.environ.get("TTS_ENABLE_GLOBAL_HOTKEY", "").lower() in {"1", "true", "yes", "on"}

_lock_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    _lock_socket.bind(("127.0.0.1", 59003))
except OSError:
    print("codex_tts_watcher: another instance is already running — exiting.")
    sys.exit(0)

tracked = {}
last_scan = 0
kokoro_retry_after = 0


def log(msg):
    line = f"{time.strftime('[%Y-%m-%d %H:%M:%S]')} {msg}"
    print(line)
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) >= LOG_ROTATE_BYTES:
            prev = LOG_FILE + ".prev"
            if os.path.exists(prev):
                os.remove(prev)
            os.rename(LOG_FILE, prev)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def is_enabled():
    try:
        with open(TOGGLE_FILE, "r", encoding="utf-8") as f:
            return f.read().strip().lower() == "on"
    except Exception:
        return True


def message_mode():
    try:
        with open(MESSAGE_MODE_FILE, "r", encoding="utf-8") as f:
            mode = f.read().strip().lower()
    except Exception:
        mode = DEFAULT_MESSAGE_MODE
    if mode in {"all", "everything", "commentary", "thinking", "updates"}:
        return "all"
    return "final"


def send_to_kokoro(text):
    global kokoro_retry_after
    now = time.time()
    if now < kokoro_retry_after:
        log(f"Kokoro unavailable; skipped {len(text)} chars during cooldown")
        return False
    payload = f"VOICE={WATCHER_VOICE}|{text}" if WATCHER_VOICE else text
    # v1.8: tag real speech with this system so the server can apply the voice and
    # speed chosen for Codex. Control commands are instructions, not utterances.
    if not text.startswith(_CONTROL_PREFIXES):
        payload = f"SYS={SYSTEM_NAME}|{payload}"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(5)
            s.connect((HOST, PORT))
            s.sendall(payload.encode("utf-8"))
        log(f"Spoke {len(text)} chars")
        _remember_spoken(text)
        kokoro_retry_after = 0
        return True
    except Exception as e:
        log(f"ERROR sending to Kokoro: {e}")
        kokoro_retry_after = time.time() + KOKORO_RETRY_SECONDS
        return False


def run_preview_command(text):
    if not os.path.exists(PREVIEW_HELPER):
        return False
    try:
        probe = subprocess.run(
            [sys.executable, PREVIEW_HELPER, "--dry-run", text],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception as e:
        log(f"Preview helper check failed: {e}")
        return False
    detail = (probe.stdout or probe.stderr or "").strip()
    if probe.returncode == 0:
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            subprocess.Popen([sys.executable, PREVIEW_HELPER, text], **kwargs)
            log(f"Started preview command: {text[:60]}")
        except Exception as e:
            log(f"Preview helper launch failed: {e}")
        return True
    if probe.returncode == 1:
        log(f"Invalid preview command: {text[:60]} -> {detail}")
        return True
    return False


def _hotkey_poller():
    if sys.platform != "win32":
        return
    VK_CONTROL = 0x11
    VK_MENU = 0x12
    VK_X = 0x58
    user32 = ctypes.windll.user32
    user32.GetAsyncKeyState.restype = ctypes.c_short
    was_pressed = False
    log("Ctrl+Alt+X hotkey poller started")
    while True:
        ctrl = user32.GetAsyncKeyState(VK_CONTROL) & 0x8000
        alt  = user32.GetAsyncKeyState(VK_MENU)    & 0x8000
        x_key = user32.GetAsyncKeyState(VK_X)      & 0x8000
        pressed = bool(ctrl and alt and x_key)
        if pressed and not was_pressed:
            threading.Thread(target=send_to_kokoro, args=("__STOP__",), daemon=True).start()
            log("Hotkey Ctrl+Alt+X: speech stopped")
        was_pressed = pressed
        time.sleep(0.05)


def iter_rollouts():
    scan_root = SESSIONS_DIR
    if sys.platform == "win32" and not scan_root.startswith("\\\\"):
        scan_root = "\\\\?\\" + os.path.abspath(scan_root)
    try:
        for root, dirs, files in os.walk(scan_root):
            for fname in files:
                if fname.startswith("rollout-") and fname.endswith(".jsonl"):
                    yield os.path.join(root, fname)
    except Exception as e:
        log(f"ERROR scanning sessions: {e}")


def prune_tracked_state():
    cutoff = time.time() - STATE_MAX_AGE_DAYS * 86400
    to_remove = []
    for path in list(tracked.keys()):
        try:
            if os.path.getmtime(path) < cutoff:
                to_remove.append(path)
        except Exception:
            to_remove.append(path)
    for path in to_remove:
        del tracked[path]
    if to_remove:
        log(f"Pruned {len(to_remove)} stale tracked rollout entries.")


def add_new_rollouts(initial_scan=False):
    count = 0
    for path in iter_rollouts():
        count += 1
        if path in tracked:
            continue
        try:
            size = os.path.getsize(path)
            offset = size if initial_scan else 0
            tracked[path] = offset
            log(f"Tracking rollout: ...{path[-80:]} from offset {offset}")
        except Exception as e:
            log(f"ERROR adding rollout ...{path[-80:]}: {e}")
    if initial_scan:
        prune_tracked_state()
    return count


_METADATA_KEYS = {"outcome", "risk_level", "user_authorization", "rationale"}
USER_MESSAGE_TYPES = {"user_message", "user_input", "user"}
PREVIEW_TRIGGER_WORDS = {"preview", "previews", "voice", "voices", "test", "hear", "try", "play", "sample", "samples"}


def should_skip_text(text):
    try:
        data = json.loads(text)
    except Exception:
        return False
    return isinstance(data, dict) and bool(_METADATA_KEYS.intersection(data.keys()))


def _text_from_content_items(content):
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return None
    parts = []
    for item in content:
        if isinstance(item, dict) and item.get("type") in {"input_text", "text"}:
            parts.append(str(item.get("text", "")))
    text = "".join(parts).strip()
    return text or None


def preview_text_from_record(data):
    try:
        payload = data.get("payload", {})
        if data.get("type") == "event_msg" and payload.get("type") in USER_MESSAGE_TYPES:
            text = payload.get("message", "").strip()
            return text or None
        if data.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
            return _text_from_content_items(payload.get("content"))
    except Exception:
        return None
    return None


def looks_like_preview_command(text):
    lower = (text or "").strip().lower()
    if lower.startswith("__preview_"):
        return True
    words = set(re.findall(r"[a-z0-9_]+", lower))
    return bool(words.intersection(PREVIEW_TRIGGER_WORDS))


def text_from_record(data):
    try:
        if data.get("type") != "event_msg":
            return None
        payload = data.get("payload", {})
        if payload.get("type") != "agent_message":
            return None
        if message_mode() == "final" and payload.get("phase") != "final_answer":
            return None
        text = payload.get("message", "").strip()
        if not text or should_skip_text(text):
            return None
        return text
    except Exception:
        return None


def check_rollout(path):
    try:
        size = os.path.getsize(path)
        offset = tracked.get(path, 0)
        if size < offset:
            offset = 0
        if size == offset:
            return
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            f.seek(offset)
            lines = f.readlines()
            tracked[path] = f.tell()
    except Exception as e:
        log(f"ERROR reading ...{path[-80:]}: {e}")
        return

    now = time.time()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
        except Exception:
            continue
        ts_raw = data.get("timestamp")
        if ts_raw:
            try:
                if isinstance(ts_raw, (int, float)):
                    msg_time = float(ts_raw)
                else:
                    ts_str = str(ts_raw).replace("Z", "+00:00")
                    msg_dt = datetime.fromisoformat(ts_str)
                    if msg_dt.tzinfo is None:
                        msg_dt = msg_dt.replace(tzinfo=timezone.utc)
                    msg_time = msg_dt.timestamp()
                if now - msg_time > MESSAGE_MAX_AGE_SECONDS:
                    log(f"Skipped stale message ({int(now - msg_time)}s old)")
                    continue
            except Exception:
                pass
        preview_text = preview_text_from_record(data)
        # Cheap pre-filter: only shell out to the helper for short messages that
        # could plausibly be a preview command. Skips spawning a subprocess for
        # every (often very long) user message.
        if (preview_text and len(preview_text) <= 120
                and looks_like_preview_command(preview_text)
                and run_preview_command(preview_text)):
            continue
        text = text_from_record(data)
        if not text:
            continue
        if is_enabled():
            log(f"Speaking: {text[:100].replace(chr(10), ' ')}...")
            send_to_kokoro(text)
        else:
            log("TTS disabled; skipped assistant message")



# --- Panel status endpoint (loopback only) ----------------------------------
# The Omnicapable Voice panel (127.0.0.1:59010) polls this to decide whether to
# show a chip for this system, and to route Replay and the reading-mode toggle at it. Bound to
# 127.0.0.1 only, so it is unreachable from the network. If the port is already
# taken the watcher logs it and carries on — status is a convenience, never a
# reason to stop speaking.
STATUS_PORT     = 59012
WATCHER_VERSION = "1.8"
# SYSTEM_NAME and _CONTROL_PREFIXES are defined in the config block at the top.

_last_spoken = {"text": ""}          # last real utterance, for panel replay


def _remember_spoken(text):
    """Record the last genuine utterance so the panel can replay it.

    Control commands and voice-prefixed payloads are not speech, so they must
    not overwrite what Replay would say."""
    try:
        body = text.split("|", 1)[1] if text.startswith("VOICE=") else text
        if body and not body.startswith(_CONTROL_PREFIXES):
            _last_spoken["text"] = body
    except Exception:
        pass


def _status_payload():
    return {
        "system":    SYSTEM_NAME,
        "version":   WATCHER_VERSION,
        "mode":      message_mode(),
        "last_text": _last_spoken["text"][:400],
        "enabled":   is_enabled(),
    }


def _start_status_server():
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        def _cors(self):
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code); self._cors()
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            try:
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"{}")
            except Exception:
                return {}

        def do_OPTIONS(self):
            self.send_response(204); self._cors(); self.end_headers()

        def do_GET(self):
            if self.path.split("?")[0] in ("/state", "/"):
                self._json(_status_payload())
            else:
                self._json({"error": "not found"}, 404)

        def do_POST(self):
            path = self.path.split("?")[0]
            if path == "/replay":
                text = _last_spoken["text"]
                if not text:
                    self._json({"ok": False, "error": "nothing spoken yet"}, 409); return
                threading.Thread(target=send_to_kokoro, args=(text,), daemon=True).start()
                self._json({"ok": True})
            elif path == "/mode":
                mode = str(self._body().get("mode", "")).strip().lower()
                if mode not in ("final", "all"):
                    self._json({"ok": False, "error": "mode must be 'final' or 'all'"}, 400); return
                try:
                    os.makedirs(os.path.dirname(MESSAGE_MODE_FILE), exist_ok=True)
                    with open(MESSAGE_MODE_FILE, "w", encoding="utf-8") as f:
                        f.write(mode)
                    log(f"Panel set message mode to '{mode}'")
                    self._json({"ok": True, "mode": mode})
                except Exception as e:
                    self._json({"ok": False, "error": str(e)}, 500)
            else:
                self._json({"error": "not found"}, 404)

        def log_message(self, *a):        # keep the watcher log readable
            pass

    try:
        srv = ThreadingHTTPServer(("127.0.0.1", STATUS_PORT), Handler)
    except OSError as e:
        log(f"Panel status endpoint unavailable on {STATUS_PORT}: {e}")
        return
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"Panel status endpoint listening on 127.0.0.1:{STATUS_PORT}")

def main():
    global last_scan
    if ENABLE_HOTKEY:
        threading.Thread(target=_hotkey_poller, daemon=True).start()
    else:
        log("Ctrl+Alt+X hotkey poller disabled. Set TTS_ENABLE_GLOBAL_HOTKEY=1 to enable it.")
    _start_status_server()
    log("codex_tts_watcher v1.8 started. Monitoring Claude Code rollout JSONL files.")
    total = add_new_rollouts(initial_scan=True)
    log(f"Initial scan found {total} rollout file(s).")
    last_scan = time.time()
    while True:
        try:
            now = time.time()
            if (now - last_scan) >= SCAN_INTERVAL:
                add_new_rollouts()
                last_scan = now
            for path in list(tracked.keys()):
                check_rollout(path)
        except Exception as e:
            log(f"Loop error: {e}")
        time.sleep(POLL)


if __name__ == "__main__":
    main()

