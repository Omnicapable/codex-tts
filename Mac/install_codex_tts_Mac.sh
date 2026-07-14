#!/bin/bash
# =============================================================================
# install_codex_tts_Mac.sh  v1.2
# One-shot installer for Codex TTS — watcher-only build using Kokoro ONNX.
# Monitors ~/.codex/sessions rollout files and speaks responses aloud.
# Fully offline after install. No API keys. No data sent to third parties.
#
# Requirements: macOS 12+, Python 3.9+, Claude Code (Codex) installed
# Usage: chmod +x install_codex_tts_Mac.sh && ./install_codex_tts_Mac.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLAUDE_DIR="$HOME/.claude"
KOKORO_DIR="$CLAUDE_DIR/kokoro"
CODEX_TTS_DIR="$HOME/Documents/Codex TTS"
PORT=59001
KOKORO_PLIST_LABEL="com.user.kokoro-tts-server"
KOKORO_PLIST_PATH="$HOME/Library/LaunchAgents/$KOKORO_PLIST_LABEL.plist"
WATCHER_PLIST_LABEL="com.user.codex-tts-watcher"
WATCHER_PLIST_PATH="$HOME/Library/LaunchAgents/$WATCHER_PLIST_LABEL.plist"
VERSION="1.1"

echo ""
echo "============================================"
echo " Codex TTS Installer v$VERSION — Mac"
echo "============================================"
echo ""

# --- 1. Check Python -----------------------------------------------------------
echo "[1/7] Checking Python..."
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 not found."
  echo "Install Python 3.9+ from https://python.org or via Homebrew: brew install python"
  exit 1
fi
PYTHON=$(command -v python3)
echo "      Found: $($PYTHON --version) at $PYTHON"

# --- 2. Install Python packages ------------------------------------------------
echo "[2/7] Installing Python packages..."
$PYTHON -m pip install kokoro-onnx sounddevice numpy --quiet
echo "      Done."

# --- 3. Create folders ---------------------------------------------------------
echo "[3/7] Creating folders..."
mkdir -p "$KOKORO_DIR" "$CODEX_TTS_DIR"
mkdir -p "$HOME/.codex/sessions"
echo "      Done."

# --- 4. Download Kokoro model files (skip if already present) ------------------
echo "[4/7] Checking Kokoro model files (~336 MB total)..."
BASE_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
for FILE in "kokoro-v1.0.onnx" "voices-v1.0.bin"; do
  DEST="$KOKORO_DIR/$FILE"
  if [ -f "$DEST" ]; then
    echo "      Already exists: $FILE"
  else
    echo "      Downloading $FILE..."
    curl -L --progress-bar "$BASE_URL/$FILE" -o "$DEST"
    echo "      Done: $FILE"
  fi
done

# --- 5. Write tts_server.py (shared, skip if already present) ------------------
echo "[5/7] Writing shared Kokoro server..."
if [ -f "$KOKORO_DIR/tts_server.py" ]; then
  echo "      Already present: tts_server.py (shared with other TTS setups)"
else
cat > "$KOKORO_DIR/tts_server.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""
tts_server.py v2.1 - Persistent Kokoro TTS server.
Loads the model once, listens on localhost:59001 for text to speak.
Pipelined: synthesizes sentence-by-sentence so first sentence plays immediately.
Supports: stop, speed change, voice change, per-request voice prefix.
"""
import socket, threading, queue, os, re, time
import numpy as np
import sounddevice as sd

HOST, PORT = "127.0.0.1", 59001
VOICE, SPEED, LANG, MAX_CHARS = "am_onyx", 1.2, "en-us", 5000

base = os.path.dirname(os.path.abspath(__file__))
from kokoro_onnx import Kokoro
kokoro = Kokoro(os.path.join(base, "kokoro-v1.0.onnx"), os.path.join(base, "voices-v1.0.bin"))

sd.play(np.zeros(1, dtype=np.float32), samplerate=24000)
sd.wait()

_speak_lock = threading.Semaphore(1)
_stop_event  = threading.Event()
_last_text  = ""      # last text spoken, for __REPLAY__
_last_voice = None

_last_utterance_ts = 0.0
def _refresh_audio_device():
    # Follow output-device switches (AirPods/headphones/Bluetooth) WITHOUT tearing
    # down PortAudio on every utterance — that was fragile (macOS PaMacCore -50).
    # Only re-scan devices after an idle gap (between bursts, not mid-burst), so a
    # rapid run of replies doesn't thrash the audio backend.
    global _last_utterance_ts
    now = time.time()
    idle = now - _last_utterance_ts
    _last_utterance_ts = now
    if idle > 8.0:
        try:
            sd._terminate(); sd._initialize()
        except Exception:
            pass

def clean_text(text):
    text = re.sub(r'(?m)(\|[^\n]+\|\n?)+', ' attached table. ', text)
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'`[^`]+`', '', text)
    text = re.sub(r'(?m)^#{1,6}\s+', '', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'\1', text)
    text = re.sub(r'__([^_]+)__', r'\1', text)
    text = re.sub(r'\*([^*]+)\*', r'\1', text)
    text = re.sub(r'_([^_]+)_', r'\1', text)
    text = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', text)
    text = re.sub(r'(?m)^\s*[-*+]\s+', '', text)
    text = re.sub(r'(?m)^\s*\d+\.\s+', '', text)
    text = re.sub(r'(?m)^\s*>\s+', '', text)
    text = re.sub(r'\n{2,}', '. ', text)
    text = re.sub(r'\n', ' ', text)
    text = re.sub(r'[→←↑↓⇒⇐]', '', text)
    text = text.replace('‒', ',').replace('–', ',').replace('—', ',').replace('―', ',').replace('−', ',')
    text = re.sub(r'[|\\]', '', text)
    text = re.sub(r'[•·●◦]', '', text)
    text = re.sub(r'https?://\S+', 'link', text)
    text = re.sub(r'\be\.g\.\b', 'for example', text)
    text = re.sub(r'\bi\.e\.\b', 'that is', text)
    text = re.sub(r'\bvs\.\b', 'versus', text)
    text = re.sub(r'\betc\.\b', 'etcetera', text)
    text = re.sub(r'\bapprox\.\b', 'approximately', text)
    text = re.sub(r'(\d),(\d{3})', r'\1\2', text)
    text = re.sub(r'\$(\d)', r'\1 dollars', text)
    text = re.sub(r'(\d)%', r'\1 percent', text)
    text = re.sub(r'(\d+)x\b', r'\1 times', text)
    text = re.sub(r'\s{2,}', ' ', text)
    return text.strip()

def split_sentences(text):
    parts = re.split(r'(?<=[.!?])\s+', text)
    result = []
    for s in parts:
        s = s.strip()
        if not s: continue
        if result and len(result[-1]) < 40:
            result[-1] += ' ' + s
        else:
            result.append(s)
    return result if result else [text]

def synthesize(sentence, voice_override=None):
    v = voice_override if voice_override else VOICE
    samples, rate = kokoro.create(sentence, voice=v, speed=SPEED, lang=LANG)
    return np.array(samples, dtype=np.float32), rate

def speak(text, voice_override=None):
    text = clean_text(text)
    if not text: return
    if len(text) > MAX_CHARS: text = text[:MAX_CHARS] + " ... response truncated."
    sentences = split_sentences(text)
    _stop_event.clear()
    wav_queue = queue.Queue()
    def producer():
        for sentence in sentences:
            if _stop_event.is_set(): break
            try: wav_queue.put(synthesize(sentence, voice_override=voice_override))
            except Exception: pass
        wav_queue.put(None)
    threading.Thread(target=producer, daemon=True).start()
    _refresh_audio_device()
    while True:
        item = wav_queue.get()
        if item is None or _stop_event.is_set():
            while True:
                try: wav_queue.get_nowait()
                except queue.Empty: break
            break
        samples, rate = item
        sd.play(samples, samplerate=rate)
        sd.wait()
        if _stop_event.is_set():
            sd.stop(); break

def handle_client(conn):
    global _last_text, _last_voice
    with conn:
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        text = data.decode("utf-8", errors="ignore").strip()
        if text == "__STOP__":
            _stop_event.set(); sd.stop(); return
        if text.startswith("__SPEED:") and text.endswith("__"):
            global SPEED
            try: SPEED = float(text[8:-2].strip())
            except ValueError: pass
            return
        if text == "__GETSPEED__":
            try: conn.sendall(str(SPEED).encode("utf-8")); conn.shutdown(socket.SHUT_WR)
            except Exception: pass
            return
        if text.startswith("__VOICE:") and text.endswith("__"):
            global VOICE
            VOICE = text[8:-2].strip(); return
        if text == "__GETVOICE__":
            try: conn.sendall(VOICE.encode("utf-8")); conn.shutdown(socket.SHUT_WR)
            except Exception: pass
            return
        if text == "__REPLAY__":
            if _last_text:
                with _speak_lock: speak(_last_text, voice_override=_last_voice)
            return
        if text:
            req_voice = None
            if text.startswith("VOICE=") and "|" in text:
                prefix, text = text.split("|", 1)
                req_voice = prefix[6:].strip()
            if text:
                _last_text, _last_voice = text, req_voice
                with _speak_lock: speak(text, voice_override=req_voice)

def run_server():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT)); srv.listen()
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=handle_client, args=(conn,), daemon=True).start()

while True:
    try: run_server()
    except Exception: time.sleep(3)
PYEOF
fi
echo "      Done."

# tts_preview.py - friendly preview phrase router
cat > "$KOKORO_DIR/tts_preview.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""tts_preview.py - friendly voice-preview command router for Kokoro TTS.

Accepted examples:
  quick preview voices
  preview all voices
  preview voice onyx
  __PREVIEW_QUICK__

Exit codes:
  0 = preview command recognized/handled
  1 = malformed preview command or unknown voice
  2 = not a preview command
"""

import os
import re
import socket
import subprocess
import sys
import time

HOST, PORT = "127.0.0.1", 59001

VOICES = {
    "American male": ["am_onyx", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_santa"],
    "American female": ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky"],
    "British female": ["bf_alice", "bf_emma", "bf_isabella", "bf_lily"],
    "British male": ["bm_daniel", "bm_fable", "bm_george", "bm_lewis"],
}

# One short representative per category for quick preview.
CATEGORY_REPS = {
    "American male": ["am_onyx"],
    "American female": ["af_sky"],
    "British female": ["bf_emma"],
    "British male": ["bm_daniel"],
}

SAMPLE = "Hello! This is how I sound. You can ask to switch to this voice anytime."
QUICK_PHRASES = {
    "quick preview voices",
    "quick voice preview",
    "quick voices preview",
    "quick voices",
    "preview voices",
    "voice preview",
    "voices preview",
    "test voices",
    "try voices",
    "sample voices",
    "voice samples",
    "play voices",
    "hear voices",
    "preview some voices",
}
FULL_PHRASES = {
    "preview all voices",
    "full preview voices",
    "all voices preview",
    "play all voices",
    "test all voices",
    "try all voices",
    "sample all voices",
    "hear all voices",
}
SINGLE_PATTERNS = [
    re.compile(r"^(preview|test|hear|try|play|sample) voice ([a-z0-9_ -]+)$"),
    re.compile(r"^(preview|test|hear|try|play|sample) ([a-z0-9_ -]+) voice$"),
    re.compile(r"^(preview|test|hear|try|play|sample) ([a-z0-9_ -]+)$"),
    re.compile(r"^voice ([a-z0-9_ -]+)$"),
    re.compile(r"^([a-z0-9_ -]+) voice preview$"),
]

ALL_VOICES = [voice for voices in VOICES.values() for voice in voices]
MANUAL_ALIASES = {
    # American male
    "onyx": "am_onyx",
    "onix": "am_onyx",
    "adam": "am_adam",
    "adem": "am_adam",
    "echo": "am_echo",
    "eco": "am_echo",
    "eko": "am_echo",
    "ecko": "am_echo",
    "ekko": "am_echo",
    "echoo": "am_echo",
    "eric": "am_eric",
    "erik": "am_eric",
    "erick": "am_eric",
    "fenrir": "am_fenrir",
    "fenr": "am_fenrir",
    "fenner": "am_fenrir",
    "liam": "am_liam",
    "leam": "am_liam",
    "michael": "am_michael",
    "micheal": "am_michael",
    "mikael": "am_michael",
    "mike": "am_michael",
    "santa": "am_santa",
    "santo": "am_santa",

    # American female
    "alloy": "af_alloy",
    "aloy": "af_alloy",
    "alloi": "af_alloy",
    "aoede": "af_aoede",
    "aode": "af_aoede",
    "aoide": "af_aoede",
    "aodie": "af_aoede",
    "ode": "af_aoede",
    "odie": "af_aoede",
    "bella": "af_bella",
    "bela": "af_bella",
    "heart": "af_heart",
    "hart": "af_heart",
    "jessica": "af_jessica",
    "jessika": "af_jessica",
    "jess": "af_jessica",
    "kore": "af_kore",
    "core": "af_kore",
    "cory": "af_kore",
    "kory": "af_kore",
    "nicole": "af_nicole",
    "nikole": "af_nicole",
    "nicol": "af_nicole",
    "nova": "af_nova",
    "river": "af_river",
    "riva": "af_river",
    "sarah": "af_sarah",
    "sara": "af_sarah",
    "sky": "af_sky",
    "skye": "af_sky",

    # British female
    "alice": "bf_alice",
    "alis": "bf_alice",
    "alyse": "bf_alice",
    "emma": "bf_emma",
    "ema": "bf_emma",
    "isabella": "bf_isabella",
    "isabela": "bf_isabella",
    "izabella": "bf_isabella",
    "lily": "bf_lily",
    "lilly": "bf_lily",
    "lilie": "bf_lily",

    # British male
    "daniel": "bm_daniel",
    "dan": "bm_daniel",
    "danny": "bm_daniel",
    "fable": "bm_fable",
    "fabel": "bm_fable",
    "george": "bm_george",
    "jorge": "bm_george",
    "lewis": "bm_lewis",
    "louis": "bm_lewis",
    "louie": "bm_lewis",
}
ALIASES = {alias: [voice] for alias, voice in MANUAL_ALIASES.items()}
for voice in ALL_VOICES:
    suffix = voice.split("_", 1)[1]
    ALIASES.setdefault(suffix, []).append(voice)
    ALIASES.setdefault(voice, []).append(voice)


def normalize(text):
    text = (text or "").strip().strip('"\'')
    text = text.replace("\u201c", '"').replace("\u201d", '"').replace("\u2018", "'").replace("\u2019", "'")
    text = text.lower()
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def resolve_voice(name):
    key = normalize(name).replace(" ", "_").replace("-", "_")
    if key in ALL_VOICES:
        return key
    matches = list(dict.fromkeys(ALIASES.get(key, [])))
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise ValueError(f"Ambiguous voice alias '{name}': {', '.join(matches)}")
    raise ValueError(f"Unknown voice '{name}'. Try a full voice ID like am_onyx or af_sky.")


def parse_command(raw):
    original = (raw or "").strip()
    text = normalize(original)
    upper = original.upper().strip()

    if upper == "__PREVIEW_QUICK__":
        return ("quick", None)
    if upper == "__PREVIEW_ALL__":
        return ("all", None)
    if upper.startswith("__PREVIEW_VOICE__:"):
        return ("voice", resolve_voice(original.split(":", 1)[1].strip()))

    if text in QUICK_PHRASES:
        return ("quick", None)
    if text in FULL_PHRASES:
        return ("all", None)

    for pattern in SINGLE_PATTERNS:
        match = pattern.fullmatch(text)
        if match:
            return ("voice", resolve_voice(match.group(match.lastindex).strip()))

    # Phrases that look like a preview request but are not whitelisted should fail loudly.
    if text.startswith(("preview", "test", "hear", "try", "play", "sample", "voice")) or text.endswith("voice preview"):
        raise ValueError("Preview command not recognized. Try 'quick voices', 'test voices', 'preview all voices', 'try onyx', or 'play voice echo'.")

    return (None, None)


def display_action(mode, voice=None):
    if mode == "quick":
        return "preview_voices.py --category"
    if mode == "all":
        return "preview_voices.py"
    if mode == "voice":
        return f"preview_voices.py {voice}"
    return "not a preview command"


def send(text, timeout=5):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect((HOST, PORT))
        s.sendall(text.encode("utf-8"))


def send_recv(text, timeout=5):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect((HOST, PORT))
        s.sendall(text.encode("utf-8"))
        s.shutdown(socket.SHUT_WR)
        data = b""
        while True:
            chunk = s.recv(1024)
            if not chunk:
                break
            data += chunk
    return data.decode("utf-8", errors="replace").strip()


def get_current_voice():
    try:
        return send_recv("__GETVOICE__") or "am_onyx"
    except Exception:
        return "am_onyx"


def set_voice(name):
    send(f"__VOICE:{name}__")


def stop_speech():
    try:
        send("__STOP__", timeout=1)
    except Exception:
        pass


def preview_voice(category, name, delay=5.0):
    label = f"{category} - {name.split('_', 1)[1]}"
    print(f"  {label}", flush=True)
    # Carry the voice in the request itself (VOICE=name|text) so each sample is
    # synthesised with its own voice atomically. Setting a shared global and then
    # sending the text separately races: threaded synthesis could read a voice the
    # next sample already overwrote, so a sample plays in the wrong voice.
    send(f"VOICE={name}|{label}. {SAMPLE}")
    time.sleep(delay)


def run_preview(mode, voice=None):
    original = get_current_voice()
    print(f"Starting voice preview. Will restore '{original}' when done.", flush=True)
    try:
        if mode == "voice":
            category = next((cat for cat, names in VOICES.items() if voice in names), "Voice")
            preview_voice(category, voice, delay=6.0)
        elif mode == "quick":
            for category, names in CATEGORY_REPS.items():
                print(f"[{category}]", flush=True)
                for name in names:
                    preview_voice(category, name, delay=6.0)
        elif mode == "all":
            for category, names in VOICES.items():
                print(f"[{category}]", flush=True)
                for name in names:
                    preview_voice(category, name, delay=4.5)
    except KeyboardInterrupt:
        stop_speech()
        print("Stopped.", flush=True)
    finally:
        try:
            set_voice(original)
            time.sleep(0.2)
        except Exception:
            pass
        print("Voice preview done.", flush=True)


def launch_background(mode, voice=None):
    args = [sys.executable, os.path.abspath(__file__), "--run-preview", mode]
    if voice:
        args.append(voice)
    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs)


def main(argv):
    dry_run = False
    args = list(argv)
    if "--run-preview" in args:
        idx = args.index("--run-preview")
        mode = args[idx + 1] if len(args) > idx + 1 else ""
        voice = args[idx + 2] if len(args) > idx + 2 else None
        if mode not in {"quick", "all", "voice"}:
            print("Invalid internal preview mode.", file=sys.stderr)
            return 1
        run_preview(mode, voice)
        return 0

    if "--dry-run" in args:
        dry_run = True
        args.remove("--dry-run")

    raw = " ".join(args).strip()
    if not raw:
        print("No preview command provided.", file=sys.stderr)
        return 2

    try:
        mode, voice = parse_command(raw)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if not mode:
        print("Not a preview command.")
        return 2

    action = display_action(mode, voice)
    if dry_run:
        print(action)
        return 0

    launch_background(mode, voice)
    print(f"Starting: {action}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
PYEOF
chmod +x "$KOKORO_DIR/tts_preview.py"
# --- 6. Write codex_tts_watcher.py (v1.5) --------------------------------------
echo "[6/7] Writing Codex TTS watcher (v1.5)..."
cat > "$CODEX_TTS_DIR/codex_tts_watcher.py" << 'PYEOF'
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
PYEOF
chmod +x "$CODEX_TTS_DIR/codex_tts_watcher.py"
echo "      Done: $CODEX_TTS_DIR/codex_tts_watcher.py"

# --- 7. Set up launchd for Kokoro server + Codex watcher ----------------------
echo "[7/7] Setting up launchd auto-start..."
mkdir -p "$HOME/Library/LaunchAgents"

if [ ! -f "$KOKORO_PLIST_PATH" ]; then
cat > "$KOKORO_PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$KOKORO_PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$KOKORO_DIR/tts_server.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.claude/tts_server.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/tts_server.log</string>
</dict>
</plist>
PLISTEOF
  launchctl bootstrap "gui/$(id -u)" "$KOKORO_PLIST_PATH" 2>/dev/null || true
  echo "      Kokoro server plist installed. Waiting 10s for model load..."
  sleep 10
else
  echo "      Kokoro server plist already present — skipping."
fi

# --- Ctrl+Option+X global stop hotkey (Carbon RegisterEventHotKey; NO permission prompt) ---
HOTKEY_PLIST_LABEL="com.user.kokoro-tts-hotkey"
HOTKEY_PLIST_PATH="$HOME/Library/LaunchAgents/$HOTKEY_PLIST_LABEL.plist"
cat > "$KOKORO_DIR/tts_hotkey.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""
Safe global TTS hotkey daemon (macOS).
Registers Ctrl+Option+X via Carbon's RegisterEventHotKey and sends Kokoro's
shared __STOP__ command to 127.0.0.1:59001. RegisterEventHotKey is NOT gated by
Accessibility or Input Monitoring, so NO permission prompt is ever shown —
unlike a pynput / CGEventTap approach.
"""
import ctypes
import ctypes.util
import os
import socket
import time
import traceback

HOST = "127.0.0.1"
PORT = 59001
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "tts_hotkey.log")

# Carbon modifier masks (these are NOT CGEventFlags values):
CONTROL_KEY = 0x1000
OPTION_KEY  = 0x0800
KEY_X       = 0x07                 # kVK_ANSI_X
KEY_R       = 0x0F                 # kVK_ANSI_R
EVENT_CLASS_KEYBOARD = 0x6B657962  # 'keyb'
EVENT_HOTKEY_PRESSED = 5           # kEventHotKeyPressed
PARAM_DIRECT_OBJECT  = 0x2D2D2D2D  # '----' kEventParamDirectObject
TYPE_HOTKEY_ID       = 0x686B6964  # 'hkid' typeEventHotKeyID
STOP_ID   = 1
REPLAY_ID = 2
kProcessTransformToUIElementApplication = 4


def log(message):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def _send(cmd, label):
    try:
        with socket.create_connection((HOST, PORT), timeout=1.0) as sock:
            sock.sendall(cmd)
        log(f"{label} sent {cmd.decode()}")
    except Exception as exc:
        log(f"{label} failed to send {cmd.decode()}: {exc}")


def send_stop():
    _send(b"__STOP__", "Ctrl+Option+X")


def send_replay():
    _send(b"__REPLAY__", "Ctrl+Option+R")


class EventTypeSpec(ctypes.Structure):
    _fields_ = [("eventClass", ctypes.c_uint32), ("eventKind", ctypes.c_uint32)]


class EventHotKeyID(ctypes.Structure):
    _fields_ = [("signature", ctypes.c_uint32), ("id", ctypes.c_uint32)]


class ProcessSerialNumber(ctypes.Structure):
    _fields_ = [("highLongOfPSN", ctypes.c_uint32), ("lowLongOfPSN", ctypes.c_uint32)]


carbon = None  # set in main()

# OSStatus handler(EventHandlerCallRef, EventRef, void *userData)
HANDLER = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)


def _on_hotkey(_call_ref, event, _user_data):
    hk = EventHotKeyID()
    try:
        carbon.GetEventParameter(event, PARAM_DIRECT_OBJECT, TYPE_HOTKEY_ID, None,
                                 ctypes.sizeof(hk), None, ctypes.byref(hk))
    except Exception:
        pass
    if hk.id == REPLAY_ID:
        send_replay()
    else:
        send_stop()
    return 0


# Keep a reference so the trampoline isn't garbage-collected.
_handler_ref = HANDLER(_on_hotkey)


def _load_carbon():
    # ctypes.util.find_library("Carbon") returns None on macOS 11+ because system
    # frameworks live in the dyld shared cache, not on disk. Load by absolute
    # path first; dyld still resolves it from the cache.
    for path in ("/System/Library/Frameworks/Carbon.framework/Carbon",
                 "/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon",
                 ctypes.util.find_library("Carbon")):
        if not path:
            continue
        try:
            return ctypes.CDLL(path)
        except OSError:
            continue
    return None


def main():
    global carbon
    carbon = _load_carbon()
    if carbon is None:
        log("ERROR: could not load the Carbon framework; hotkey disabled.")
        return
    try:
        carbon.GetApplicationEventTarget.restype = ctypes.c_void_p
        carbon.GetApplicationEventTarget.argtypes = []
        carbon.GetEventParameter.restype = ctypes.c_int32
        carbon.GetEventParameter.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                             ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]
        carbon.InstallEventHandler.restype = ctypes.c_int32
        carbon.InstallEventHandler.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong,
                                               ctypes.POINTER(EventTypeSpec), ctypes.c_void_p, ctypes.c_void_p]
        carbon.RegisterEventHotKey.restype = ctypes.c_int32
        carbon.RegisterEventHotKey.argtypes = [ctypes.c_uint32, ctypes.c_uint32, EventHotKeyID,
                                               ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
        carbon.RunApplicationEventLoop.restype = None
        carbon.RunApplicationEventLoop.argtypes = []

        # Give the faceless launchd process a WindowServer connection so it can
        # receive the hotkey, without showing a Dock icon.
        try:
            psn = ProcessSerialNumber(0, 2)  # {0, kCurrentProcess}
            carbon.TransformProcessType(ctypes.byref(psn),
                                        kProcessTransformToUIElementApplication)
        except Exception as exc:
            log(f"TransformProcessType skipped: {exc}")

        target = carbon.GetApplicationEventTarget()
        spec = EventTypeSpec(EVENT_CLASS_KEYBOARD, EVENT_HOTKEY_PRESSED)
        carbon.InstallEventHandler(target, _handler_ref, 1, ctypes.byref(spec), None, None)

        stop_ref = ctypes.c_void_p()
        status = carbon.RegisterEventHotKey(KEY_X, CONTROL_KEY | OPTION_KEY,
                                            EventHotKeyID(0x54545353, STOP_ID), target, 0,
                                            ctypes.byref(stop_ref))
        if status != 0:
            log(f"RegisterEventHotKey(stop) FAILED (status {status}); Ctrl+Option+X may be taken.")
            return
        replay_ref = ctypes.c_void_p()
        status_r = carbon.RegisterEventHotKey(KEY_R, CONTROL_KEY | OPTION_KEY,
                                              EventHotKeyID(0x54545353, REPLAY_ID), target, 0,
                                              ctypes.byref(replay_ref))
        if status_r != 0:
            log(f"RegisterEventHotKey(replay) FAILED (status {status_r}); Ctrl+Option+R may be taken.")
        log("Registered Ctrl+Option+X (stop) and Ctrl+Option+R (replay) (Carbon, no permission needed).")
        carbon.RunApplicationEventLoop()
    except Exception as exc:
        log("ERROR in hotkey daemon: " + repr(exc))
        log(traceback.format_exc())


if __name__ == "__main__":
    main()
PYEOF
cat > "$HOTKEY_PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HOTKEY_PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$KOKORO_DIR/tts_hotkey.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.claude/tts_hotkey.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/tts_hotkey.log</string>
</dict>
</plist>
PLISTEOF
launchctl bootout "gui/$(id -u)/$HOTKEY_PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOTKEY_PLIST_PATH" 2>/dev/null || true
echo "      Ctrl+Option+X (stop) and Ctrl+Option+R (replay) hotkeys installed (no permission prompt needed)."

cat > "$WATCHER_PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$WATCHER_PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$CODEX_TTS_DIR/codex_tts_watcher.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$CODEX_TTS_DIR/codex_tts_watcher_log.txt</string>
    <key>StandardErrorPath</key>
    <string>$CODEX_TTS_DIR/codex_tts_watcher_log.txt</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$WATCHER_PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$WATCHER_PLIST_PATH" 2>/dev/null || true
echo "      Codex watcher plist installed and launched."

if python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1',$PORT)); s.close()" 2>/dev/null; then
    echo -e "      ${GREEN}Kokoro server: running${NC}"
else
    echo -e "      ${YELLOW}WARNING: Kokoro server not responding. Try: launchctl kickstart gui/$(id -u)/$KOKORO_PLIST_LABEL${NC}"
fi

echo ""
echo "============================================"
echo " Installation complete!"
echo "============================================"
echo ""
echo " Version: v$VERSION  |  Voice: am_onyx  |  Speed: 1.2x"
echo ""
echo " The Codex watcher monitors ~/.codex/sessions and speaks"
echo " assistant messages automatically as they complete."
echo ""
echo " Stop speech:     press Ctrl+Option+X"
echo " Replay answer:   press Ctrl+Option+R"
echo " Preview voices:  say 'quick voices' or 'preview all voices'"
echo ""
echo " Toggle TTS:      echo on > ~/.claude/tts_enabled.txt"
echo "                  echo off > ~/.claude/tts_enabled.txt"
echo " Watcher log:     $CODEX_TTS_DIR/codex_tts_watcher_log.txt"
echo " Restart watcher: launchctl kickstart gui/$(id -u)/$WATCHER_PLIST_LABEL"
echo " Restart server:  launchctl kickstart gui/$(id -u)/$KOKORO_PLIST_LABEL"
echo " Uninstall:       rm -rf \"$CODEX_TTS_DIR\" && launchctl bootout gui/$(id -u)/$WATCHER_PLIST_LABEL"
echo "                  (hotkey) launchctl bootout gui/$(id -u)/com.user.kokoro-tts-hotkey && rm -f \"$HOTKEY_PLIST_PATH\""
echo "============================================"
echo ""


