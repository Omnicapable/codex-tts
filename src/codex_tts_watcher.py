# -*- coding: utf-8 -*-
# codex_tts_watcher.py v1.5 - Automatic TTS for Claude Code (Codex) rollout JSONL sessions.
# Monitors ~/.codex/sessions and speaks completed assistant messages via Kokoro on port 59001.
# Shares the Kokoro server and TTS toggle with Claude Code TTS / Claude Cowork TTS.
#
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
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(5)
            s.connect((HOST, PORT))
            s.sendall(payload.encode("utf-8"))
        log(f"Spoke {len(text)} chars")
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


def main():
    global last_scan
    if ENABLE_HOTKEY:
        threading.Thread(target=_hotkey_poller, daemon=True).start()
    else:
        log("Ctrl+Alt+X hotkey poller disabled. Set TTS_ENABLE_GLOBAL_HOTKEY=1 to enable it.")
    log("codex_tts_watcher v1.5 started. Monitoring Claude Code rollout JSONL files.")
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

