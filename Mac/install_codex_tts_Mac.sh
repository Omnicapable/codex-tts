#!/bin/bash
# =============================================================================
# install_codex_tts_Mac.sh  v1.2
# One-shot installer for Codex TTS ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â watcher-only build using Kokoro ONNX.
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
echo " Codex TTS Installer v$VERSION ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â Mac"
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
if ! $PYTHON -m pip install kokoro-onnx sounddevice numpy pywebview pyobjc-core pyobjc-framework-Cocoa pyobjc-framework-WebKit --quiet 2>/dev/null; then
    # Homebrew / system Python marks itself "externally managed" (PEP 668) and
    # refuses a global pip install. Retry the way pip's own error recommends.
    echo "      System Python is externally managed (PEP 668); retrying with --break-system-packages..."
    $PYTHON -m pip install kokoro-onnx sounddevice numpy pywebview pyobjc-core pyobjc-framework-Cocoa pyobjc-framework-WebKit --quiet --break-system-packages
fi
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
tts_server.py v3.4 - Persistent Kokoro TTS server + HTTP control panel API.

Lineage: this is canonical v2.6 with the Omnicapable Voice panel layered on top.
v3.0/v3.1 were mistakenly derived from v2.0 and lost v2.1-v2.6 work; everything
below is restored.

v3.4: Per-system voice AND speed. Each TTS system (cowork / codex / claude_code)
      can have its own voice and speed; volume and the master mute stay global
      because there is one output stream and one master switch.

      Settings live in ONE server-owned file, ~/.claude/tts_systems.json, so they
      survive a restart of the server or of any watcher. Watchers store nothing
      and never need to be told about a change - they only tag what they send.

      Wire format extends the v2.1 prefix into a repeatable header, e.g.
          SYS=cowork|text
          VOICE=af_bella|SPEED=1.4|text
          text                              <- untagged, unchanged behaviour
      Resolution per utterance:
          SYS-tagged   : stored panel setting -> wire tag -> global default
          untagged     : wire tag -> global default
      The stored setting deliberately beats a VOICE= tag for a SYS-tagged sender:
      that tag is how a watcher emits its hand-edited WATCHER_VOICE, and a panel
      choice must never be silently overridden by a constant somebody set months
      ago. Senders with no SYS have no stored setting, so "explicit wins" still
      holds for every ad-hoc caller.

      Claude Code has no watcher (it speaks through a Stop hook that sends bare
      text), so untagged input resolves to the claude_code slot whenever that
      hook is installed. This works on every existing install without anyone
      re-running an installer.

      Speed is captured ONCE per utterance, never re-read per chunk, so changing
      it mid-sentence cannot shift tempo between chunks of the same reply.
v3.2: Rebased on v2.6. Restores: above-normal process priority, clause chunking,
      output-device follow, __REPLAY__, voice.txt + speed.txt memory, money/cents
      parsing, working abbreviation expansion, extended emoji blocks, auto-restart
      watchdog. Playback additionally uses ONE continuous sounddevice OutputStream
      per utterance (never sd.play/sd.wait per chunk) so no device stop/start gap
      can appear between chunks. DO NOT reintroduce per-chunk sd.play().
v3.1: Gapless stream + v2.2 ports (superseded by v3.2).
v3.0: HTTP panel API on 59010, per-TTS volume, speaking/previewing state,
      preview-all, speak-text, settings persistence, global mute.

--- inherited v2.6 lineage ---
v2.6: Above-normal process priority so chunk synthesis outpaces playback.
v2.5: Speed memory (speed.txt); abbreviation patterns fixed (they never fired);
      money handles $3.5, $0.99 -> "99 cents", $1.5 million; emoji blocks widened.
v2.4: Gapless playback - long sentences split at clause breaks (<=120 chars).
v2.3: Cents fix - ' point ' runs AFTER the money rule.
v2.2: Voice memory (voice.txt); versions read "point", domains read "dot".
v2.1: Per-request voice prefix VOICE=name|text.

Run with --mock to exercise the HTTP layer without kokoro/sounddevice.
"""
import os, re, sys, json, time, socket, threading, queue, subprocess, webbrowser

MOCK = "--mock" in sys.argv

# v2.6: raise process priority so chunk synthesis keeps outpacing playback while
# the CPU is busy (agent streaming, browser). Best-effort.
try:
    if os.name == "nt":
        import ctypes
        _k32 = ctypes.windll.kernel32
        _k32.GetCurrentProcess.restype = ctypes.c_void_p
        _k32.SetPriorityClass.argtypes = (ctypes.c_void_p, ctypes.c_uint32)
        _k32.SetPriorityClass(_k32.GetCurrentProcess(), 0x00008000)  # ABOVE_NORMAL
    else:
        os.nice(-5)
except Exception:
    pass

HOST, PORT             = "127.0.0.1", 59001      # existing speak/command socket
PANEL_HOST, PANEL_PORT = "127.0.0.1", 59010      # HTTP control panel + API
LANG, MAX_CHARS        = "en-us", 5000
CHUNK_MAX, CHUNK_MIN   = 120, 40                 # v2.4 gapless chunk sizing
VERSION                = "3.4"

BASE          = os.path.dirname(os.path.abspath(__file__))
VOICE_FILE    = os.path.join(BASE, "voice.txt")   # v2.2 voice memory
SPEED_FILE    = os.path.join(BASE, "speed.txt")   # v2.5 speed memory
HOME          = os.path.expanduser("~")
CLAUDE_DIR    = os.path.join(HOME, ".claude")
TOGGLE_FILE   = os.path.join(CLAUDE_DIR, "tts_enabled.txt")
SETTINGS_FILE = os.path.join(CLAUDE_DIR, "tts_panel_settings.json")   # volume (panel)
SYSTEMS_FILE  = os.path.join(CLAUDE_DIR, "tts_systems.json")          # v3.4 per-system voice/speed

# v3.4: the systems that can own a voice/speed. "server" is what the panel calls
# the Claude Code slot, so accept it as an alias rather than making the UI and
# the wire disagree.
SYSTEM_KEYS      = ("cowork", "codex", "claude_code")
_SYSTEM_ALIASES  = {"server": "claude_code", "claude-code": "claude_code",
                    "claudecode": "claude_code", "claude": "claude_code"}

# ---- voice catalogue (panel) ----
VOICES = {
    "American male":   ["am_onyx", "am_adam", "am_echo", "am_eric", "am_fenrir",
                        "am_liam", "am_michael", "am_santa"],
    "American female": ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
                        "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky"],
    "British female":  ["bf_alice", "bf_emma", "bf_isabella", "bf_lily"],
    "British male":    ["bm_daniel", "bm_fable", "bm_george", "bm_lewis"],
}
ALL_VOICES = [v for group in VOICES.values() for v in group]
PREVIEW_TEMPLATE = "Hi, I'm {name}. This is how I sound, set me as your active voice anytime."

def _friendly(vid):
    core = vid.split("_", 1)[1] if "_" in vid else vid
    return core.replace("_", " ").title()

def _title_cat(cat):
    return cat.title()

def voices_friendly():
    out = {}
    for cat, ids in VOICES.items():
        tcat = _title_cat(cat)
        out[tcat] = [{"id": v, "name": _friendly(v),
                      "full": f"{_friendly(v)} ({tcat})"} for v in ids]
    return out

VOICE_FULL = {v: f"{_friendly(v)} ({_title_cat(cat)})"
              for cat, ids in VOICES.items() for v in ids}

def log(msg):
    print(time.strftime("[%H:%M:%S]"), msg, flush=True)

# ---- persistence: voice.txt / speed.txt (v2.x) + volume (panel) ----
def _load_voice():
    try:
        with open(VOICE_FILE, "r", encoding="utf-8") as f:
            v = f.read().strip()
            if v:
                return v
    except Exception:
        pass
    return "am_onyx"

def _save_voice(v):
    try:
        with open(VOICE_FILE, "w", encoding="utf-8") as f:
            f.write(v)
    except Exception:
        pass

def _load_speed():
    try:
        with open(SPEED_FILE, "r", encoding="utf-8") as f:
            return float(f.read().strip())
    except Exception:
        return 1.2

def _save_speed(s):
    try:
        with open(SPEED_FILE, "w", encoding="utf-8") as f:
            f.write(str(s))
    except Exception:
        pass

def _load_volume():
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            return float(json.load(f).get("volume", 1.0))
    except Exception:
        return 1.0

def _save_volume(v):
    try:
        os.makedirs(CLAUDE_DIR, exist_ok=True)
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump({"volume": v}, f)
    except Exception as e:
        log(f"volume save error: {e}")

VOICE  = _load_voice()
SPEED  = _load_speed()
VOLUME = _load_volume()

# ---- v3.4 per-system voice/speed registry (~/.claude/tts_systems.json) ----
# Shape: {"cowork": {"voice": "af_bella", "speed": 1.35}, "codex": {"speed": 1.6}}
# A missing key, or a missing field within a key, means "inherit the global".
# Only what the user explicitly Sets is ever stored, so a fresh install behaves
# exactly like every version before this one.
def normalize_system(name):
    n = (name or "").strip().lower()
    n = _SYSTEM_ALIASES.get(n, n)
    return n if n in SYSTEM_KEYS else None

def _clean_speed(v):
    try:
        return max(0.5, min(2.0, float(v)))
    except (TypeError, ValueError):
        return None

def _load_systems():
    try:
        with open(SYSTEMS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return {}
    out = {}
    for raw_key, val in (data or {}).items():
        key = normalize_system(raw_key)
        if not key or not isinstance(val, dict):
            continue
        entry = {}
        if val.get("voice") in ALL_VOICES:
            entry["voice"] = val["voice"]
        spd = _clean_speed(val.get("speed"))
        if spd is not None:
            entry["speed"] = spd
        if entry:
            out[key] = entry
    return out

def _save_systems():
    try:
        os.makedirs(CLAUDE_DIR, exist_ok=True)
        tmp = SYSTEMS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(SYSTEMS, f, indent=2)
        os.replace(tmp, SYSTEMS_FILE)          # atomic: never a half-written file
    except Exception as e:
        log(f"systems save error: {e}")

SYSTEMS = _load_systems()

def resolve_settings(system, voice_tag=None, speed_tag=None):
    """Decide the voice and speed for ONE utterance.

    SYS-tagged senders: stored panel setting -> wire tag -> global.
    Untagged senders:   wire tag -> global.

    The stored setting outranks the wire tag on purpose - see the v3.4 note at
    the top of this file (WATCHER_VOICE must not silently beat a panel choice).
    """
    entry = SYSTEMS.get(system) or {} if system else {}
    voice = entry.get("voice") or voice_tag or VOICE
    speed = entry.get("speed")
    if speed is None:
        speed = speed_tag if speed_tag is not None else SPEED
    return voice, speed

def resolved_systems():
    """What each system will actually sound like right now (panel display)."""
    out = {}
    for k in SYSTEM_KEYS:
        entry = SYSTEMS.get(k) or {}
        out[k] = {"voice": entry.get("voice") or VOICE,
                  "speed": round(entry.get("speed", SPEED), 2),
                  "voice_pinned": "voice" in entry,
                  "speed_pinned": "speed" in entry}
    return out

def set_system_setting(system, field, value):
    """Pin one field for one system. Returns False for an unknown system."""
    key = normalize_system(system)
    if not key:
        return False
    SYSTEMS.setdefault(key, {})[field] = value
    _save_systems()
    return True

def is_muted():
    try:
        with open(TOGGLE_FILE, "r") as f:
            return f.read().strip().lower() != "on"
    except Exception:
        return False

def set_muted(muted):
    try:
        os.makedirs(CLAUDE_DIR, exist_ok=True)
        with open(TOGGLE_FILE, "w") as f:
            f.write("off" if muted else "on")
    except Exception as e:
        log(f"mute write error: {e}")
    if muted:
        stop_speech()

# ---- shared state ----
_state_lock  = threading.Lock()
_speak_lock  = threading.Semaphore(1)
_stop_event  = threading.Event()
_speaking    = False
_last_text   = ""      # last text spoken, for __REPLAY__ / panel replay
_last_voice  = None
_last_speed  = None    # v3.4: replay must reuse the speed it was spoken at
_last_system = None
_speaking_system = None  # v3.4: which system owns the audio playing right now
_previewing  = None    # voice id currently auditioned (panel highlight)
_cur_stream  = None    # live OutputStream (gapless playback / abort)

# ---- audio backend ----
if not MOCK:
    import numpy as np
    import sounddevice as sd
    from kokoro_onnx import Kokoro
    kokoro = Kokoro(os.path.join(BASE, "kokoro-v1.0.onnx"),
                    os.path.join(BASE, "voices-v1.0.bin"))
    sd.play(np.zeros(1, dtype=np.float32), samplerate=24000); sd.wait()  # pre-warm

_last_utterance_ts = 0.0
def _refresh_audio_device():
    """v2.6: follow output-device switches (AirPods/headphones) WITHOUT tearing
    down PortAudio every utterance - that was fragile (macOS PaMacCore -50).
    Only re-scan after an idle gap so a rapid run of replies doesn't thrash it."""
    global _last_utterance_ts
    if MOCK:
        return
    now = time.time()
    idle = now - _last_utterance_ts
    _last_utterance_ts = now
    if idle > 8.0:
        try:
            sd._terminate(); sd._initialize()
        except Exception:
            pass

# ---- text normalisation (v2.6) ----
def _money(m):
    d, c = m.group(1), m.group(2)
    if c is None:
        return d + ' dollars'
    if len(c) > 2:
        return d + ' point ' + c + ' dollars'
    cents = c + '0' if len(c) == 1 else c
    return (cents + ' cents') if d == '0' else (d + ' dollars and ' + cents + ' cents')

def clean_text(text):
    # --- Tables ---
    text = re.sub(r'(?m)(\|[^\n]+\|\n?)+', ' attached table. ', text)
    # --- Markdown removal ---
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
    # --- Symbols ---
    text = re.sub(r'[ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¹Ã…â€œÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã¢â‚¬Å“ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â]', '', text)
    text = (text.replace('ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢', ',').replace('ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã¢â‚¬Å“', ',').replace('ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â', ',')
                .replace('ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â¢', ',').replace('ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã¢â‚¬Â¹ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢', ','))
    text = re.sub(r'[|\\]', '', text)
    text = re.sub(r'[ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â·ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦]', '', text)
    # --- Emojis (v2.5 widened blocks) ---
    text = re.sub(r'[\U0001F000-\U0001FFFF\U00002600-\U000027BF'
                  r'\U00002B00-\U00002BFF\U00002190-\U000021FF\U0000FE00-\U0000FE0F]+', '', text)
    # --- URLs ---
    text = re.sub(r'https?://\S+', 'link', text)
    # --- Abbreviations (v2.5: no trailing \b - it can never match before a space) ---
    text = re.sub(r'\be\.g\.', 'for example', text)
    text = re.sub(r'\bi\.e\.', 'that is', text)
    text = re.sub(r'\bvs\.', 'versus', text)
    text = re.sub(r'\betc\.', 'etcetera', text)
    text = re.sub(r'\bapprox\.', 'approximately', text)
    # --- Numbers / money ---
    text = re.sub(r'(?<=\d),(?=\d{3}(?:\D|$))', '', text)
    text = re.sub(r'\$(\d+(?:\.\d+)?)\s*(million|billion|trillion|thousand)\b',
                  r'\1 \2 dollars', text, flags=re.IGNORECASE)
    text = re.sub(r'\$(\d+(?:\.\d+)?)([kKmMbB])\b',
                  lambda m: m.group(1) + ' ' + {'k': 'thousand', 'm': 'million',
                                                'b': 'billion'}[m.group(2).lower()] + ' dollars', text)
    text = re.sub(r'\$(\d+)(?:\.(\d+))?', _money, text)
    text = re.sub(r'(\d)%', r'\1 percent', text)
    text = re.sub(r'(\d+)x\b', r'\1 times', text)
    # --- Versions & bare domains (v2.3: MUST stay below the money rule) ---
    text = re.sub(r'(?<=\d)\.(?=\d)', ' point ', text)
    _TLDS = r'com|net|org|edu|gov|io|ai|app|dev|co|us|uk|ca|xyz|info|biz|me|tv|gg|so|sh'
    text = re.sub(r'(?<=[A-Za-z0-9])\.(?=(?:' + _TLDS + r')\b)', ' dot ', text, flags=re.IGNORECASE)
    # --- Whitespace ---
    text = re.sub(r'\s{2,}', ' ', text)
    return text.strip()

def split_sentences(text):
    """v2.4 chunking - this is what keeps playback gapless: a chunk of at most
    CHUNK_MAX chars synthesizes faster than the audio before it plays, so the
    producer stays ahead. Long sentences break at clause punctuation; fragments
    below CHUNK_MIN merge with a neighbour."""
    pieces = []
    for s in re.split(r'(?<=[.!?])\s+', text):
        s = s.strip()
        while len(s) > CHUNK_MAX:
            w = s[:CHUNK_MAX]
            cut = max(w.rfind(','), w.rfind(';'), w.rfind(':'))
            if cut < CHUNK_MIN: cut = w.rfind(' ')
            if cut < CHUNK_MIN: cut = CHUNK_MAX - 1
            pieces.append(s[:cut + 1].strip())
            s = s[cut + 1:].strip()
        if s: pieces.append(s)
    result = []
    for p in pieces:
        if (result and (len(result[-1]) < CHUNK_MIN or len(p) < CHUNK_MIN)
                and len(result[-1]) + len(p) < CHUNK_MAX + CHUNK_MIN):
            result[-1] += ' ' + p
        else:
            result.append(p)
    return result if result else [text]

def synthesize(sentence, voice_override=None, speed=None):
    v = voice_override if voice_override else VOICE
    s = speed if speed is not None else SPEED
    samples, rate = kokoro.create(sentence, voice=v, speed=s, lang=LANG)
    return np.array(samples, dtype=np.float32) * float(VOLUME), rate

def _set_speaking(v, system=None):
    global _speaking, _speaking_system
    with _state_lock:
        _speaking = v
        _speaking_system = system if v else None

def speak(text, voice_override=None, record=True, speed_override=None, system=None):
    """Synthesize and play. Playback uses ONE continuous OutputStream for the
    whole utterance - never sd.play()/sd.wait() per chunk (that restarts the
    audio device between chunks and produces audible gaps).

    v3.4: `speed` is resolved ONCE here and passed down to every chunk. Do not
    read the global SPEED inside the producer - a panel change landing halfway
    through a reply would then shift tempo between chunks of one sentence."""
    global _last_text, _cur_stream
    text = clean_text(text)
    if not text:
        return
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS] + " ... response truncated."
    if record:
        with _state_lock:
            _last_text = text

    spd = speed_override if speed_override is not None else SPEED

    if MOCK:
        _set_speaking(True, system)
        log(f"[mock] speak (sys={system or '-'} voice={voice_override or VOICE} "
            f"speed={spd} vol={VOLUME}): {text[:70]}")
        time.sleep(min(2.0, 0.3 + len(text) * 0.008))
        _set_speaking(False)
        return

    sentences = split_sentences(text)
    _stop_event.clear()
    wav_queue = queue.Queue()

    def producer():
        for sentence in sentences:
            if _stop_event.is_set(): break
            try: wav_queue.put(synthesize(sentence, voice_override=voice_override, speed=spd))
            except Exception: pass
        wav_queue.put(None)

    threading.Thread(target=producer, daemon=True).start()
    _refresh_audio_device()
    _set_speaking(True, system)
    stream = None
    try:
        while True:
            item = wav_queue.get()
            if item is None or _stop_event.is_set():
                while True:
                    try: wav_queue.get_nowait()
                    except queue.Empty: break
                break
            samples, rate = item
            if stream is None:
                stream = sd.OutputStream(samplerate=rate, channels=1, dtype="float32")
                stream.start()
                _cur_stream = stream
            i, n, step = 0, len(samples), 2048
            while i < n:
                if _stop_event.is_set(): break
                stream.write(samples[i:i + step])
                i += step
            if _stop_event.is_set(): break
    finally:
        if stream is not None:
            try:
                if _stop_event.is_set(): stream.abort()
                else: stream.stop()
                stream.close()
            except Exception: pass
        _cur_stream = None
        _set_speaking(False)

def stop_speech():
    _stop_event.set()
    if not MOCK:
        try:
            s = _cur_stream
            if s is not None: s.abort()
        except Exception: pass
        try: sd.stop()
        except Exception: pass

# ---- panel actions ----
def _set_previewing(vid):
    global _previewing
    with _state_lock:
        _previewing = vid

def _preview_line(vid):
    return PREVIEW_TEMPLATE.format(name=_friendly(vid))

def replay_last():
    with _state_lock:
        t, v, s, sysname = _last_text, _last_voice, _last_speed, _last_system
    if not t:
        return False
    def run():
        stop_speech(); _speak_lock.acquire()
        try: speak(t, voice_override=v, record=False, speed_override=s, system=sysname)
        finally: _speak_lock.release()
    threading.Thread(target=run, daemon=True).start()
    return True

def preview_voice(name, speed=None):
    """Interrupts current audio so rapid arrow-stepping feels instant.

    v3.4: the panel passes the speed its dial is currently showing, so an
    audition always matches what you are about to get - including mid-drag, and
    even when that differs from the global default."""
    if name not in ALL_VOICES:
        return False
    def run():
        stop_speech(); _speak_lock.acquire()
        try:
            _set_previewing(name)
            speak(_preview_line(name), voice_override=name, record=False, speed_override=speed)
        finally:
            _set_previewing(None); _speak_lock.release()
    threading.Thread(target=run, daemon=True).start()
    return True

def preview_all(speed=None):
    """Audition every voice in turn; publishes which one is playing."""
    def run():
        stop_speech(); _speak_lock.acquire()
        try:
            _stop_event.clear()
            for vid in ALL_VOICES:
                if _stop_event.is_set() or is_muted(): break
                _set_previewing(vid)
                speak(_preview_line(vid), voice_override=vid, record=False, speed_override=speed)
                if _stop_event.is_set(): break
        finally:
            _set_previewing(None); _speak_lock.release()
    threading.Thread(target=run, daemon=True).start()
    return True

def speak_text(text, system=None):
    """The panel's speak box. It tags itself with the active chip so it is read
    in that system's voice - and so it is never mistaken for the untagged Claude
    Code hook."""
    if not text.strip():
        return False
    if is_muted():
        return False
    voice, speed = resolve_settings(system)
    def run():
        _speak_lock.acquire()
        try: speak(text, voice_override=voice, speed_override=speed, system=system)
        finally: _speak_lock.release()
    threading.Thread(target=run, daemon=True).start()
    return True

# ============================================================
#  TCP protocol on :59001 (v2.6 surface, unchanged)
# ============================================================
# v3.4: repeatable "KEY=value|" header. Deliberately strict - the value may not
# contain spaces or a pipe and is capped at 32 chars - so ordinary prose that
# happens to start with "SYS=" can never be swallowed as a header.
_PREFIX_RE = re.compile(r'^(SYS|VOICE|SPEED)=([A-Za-z0-9_.\-]{1,32})\|')

def parse_prefixes(text):
    """Strip any leading SYS= / VOICE= / SPEED= headers, in any order.

    Returns (system, voice, speed, remaining_text). Unrecognised values are
    dropped rather than passed through - a bogus voice used to reach kokoro and
    fail silently, which sounded like the server was broken."""
    system = voice = speed = None
    while True:
        m = _PREFIX_RE.match(text)
        if not m:
            break
        key, val = m.group(1), m.group(2)
        text = text[m.end():]
        if key == "SYS":
            system = normalize_system(val) or system
        elif key == "VOICE":
            if val in ALL_VOICES:
                voice = val
        else:
            spd = _clean_speed(val)
            if spd is not None:
                speed = spd
    return system, voice, speed, text

def handle_client(conn):
    global _last_text, _last_voice, _last_speed, _last_system, SPEED, VOICE
    with conn:
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        text = data.decode("utf-8", errors="ignore").strip()
        if not text:
            return

        # v3.4: strip headers FIRST, so a tagged control command still reads as a
        # control command. Parsing after these checks would make "SYS=cowork|__STOP__"
        # fall through and get spoken aloud as literal text.
        req_system, req_voice, req_speed, text = parse_prefixes(text)
        if not text:
            return

        if text == "__STOP__":
            stop_speech(); return

        if text.startswith("__SPEED:") and text.endswith("__"):
            try:
                SPEED = float(text[8:-2].strip()); _save_speed(SPEED)
            except ValueError: pass
            return

        if text == "__GETSPEED__":
            try: conn.sendall(str(SPEED).encode("utf-8")); conn.shutdown(socket.SHUT_WR)
            except Exception: pass
            return

        if text.startswith("__VOICE:") and text.endswith("__"):
            VOICE = text[8:-2].strip(); _save_voice(VOICE); return

        if text == "__GETVOICE__":
            try: conn.sendall(VOICE.encode("utf-8")); conn.shutdown(socket.SHUT_WR)
            except Exception: pass
            return

        if text == "__REPLAY__":
            if not is_muted() and _last_text:
                with _speak_lock:
                    speak(_last_text, voice_override=_last_voice, record=False,
                          speed_override=_last_speed, system=_last_system)
            return

        if text.startswith("__PREVIEW_VOICE__:"):
            if not is_muted():
                preview_voice(text.split(":", 1)[1].strip())
            return

        # Claude Code speaks through a Stop hook that sends bare text and cannot
        # tag itself. When that hook is installed, untagged input is Claude Code.
        # This is what lets existing installs get a per-system voice with no
        # installer change; tagging the hook explicitly is a later hardening.
        if req_system is None and claude_code_installed():
            req_system = "claude_code"

        if text:
            if is_muted():
                return
            voice, speed = resolve_settings(req_system, req_voice, req_speed)
            _last_voice, _last_speed, _last_system = voice, speed, req_system
            with _speak_lock:
                speak(text, voice_override=voice, speed_override=speed, system=req_system)

def run_server():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT)); srv.listen()
        log(f"TCP speak server on {HOST}:{PORT}")
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=handle_client, args=(conn,), daemon=True).start()

# ============================================================
#  HTTP control panel + JSON API on :59010
# ============================================================
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EMBEDDED_PANEL = ("<!doctype html><meta charset=utf-8><title>Omnicapable Voice</title>"
                  "<body style='background:#0f1115;color:#e6e9ef;font-family:sans-serif;padding:20px'>"
                  "<h3>Panel asset missing</h3><p>panel.html was not found next to tts_server.py.</p>")

def _panel_html():
    for p in (os.path.join(BASE, "panel.html"),
              os.path.join(BASE, "..", "panel", "panel.html")):
        try:
            with open(p, "r", encoding="utf-8") as f:
                return f.read()
        except Exception:
            continue
    return EMBEDDED_PANEL

def claude_code_installed():
    """True if the Claude Code TTS pack is installed.

    That pack has no watcher process ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â it speaks through a Stop hook ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â so the
    only way to know it is present is the hook script the installer drops into
    ~/.claude (tts_hook.ps1 on Windows, tts_hook.sh on macOS). The panel uses
    this to decide whether to offer a Claude Code chip; without it the chip
    would show on every install, including Cowork-only ones."""
    return any(os.path.exists(os.path.join(CLAUDE_DIR, n))
               for n in ("tts_hook.ps1", "tts_hook.sh"))

def _state_dict():
    with _state_lock:
        return {"voice": VOICE, "speed": round(SPEED, 2), "volume": round(VOLUME, 3),
                "muted": is_muted(), "speaking": _speaking, "last_text": _last_text[:200],
                "previewing": _previewing, "version": VERSION,
                "claude_code": claude_code_installed(),
                # v3.4: what each system resolves to right now, plus which one is
                # actually talking (so the panel can put the live dot on its chip
                # rather than implying it belongs to whichever chip you are viewing).
                "systems": resolved_systems(),
                "speaking_system": _speaking_system}

class PanelHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code); self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def _send_bytes(self, body, ctype):
        self.send_response(200); self._cors()
        self.send_header("Content-Type", ctype)
        # Never cache the panel or its assets. Without this the browser/WebView
        # keeps serving a stale panel.html and UI updates appear to do nothing.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def _body_json(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html", "/panel.html"):
            self._send_bytes(_panel_html().encode("utf-8"), "text/html; charset=utf-8")
        elif path in ("/logo.png", "/logo.svg", "/favicon.svg", "/panel.ico", "/favicon.ico"):
            name  = "panel.ico" if path == "/favicon.ico" else path.lstrip("/")
            ctype = "image/svg+xml" if name.endswith(".svg") else ("image/x-icon" if name.endswith(".ico") else "image/png")
            for p in (os.path.join(BASE, name), os.path.join(BASE, "..", "panel", name)):
                if os.path.isfile(p):
                    with open(p, "rb") as f:
                        self._send_bytes(f.read(), ctype); return
            self._send_json({"error": name + " not found"}, 404)
        elif path == "/state":
            self._send_json(_state_dict())
        elif path == "/voices":
            self._send_json(voices_friendly())
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        global VOICE, SPEED, VOLUME
        path = self.path.split("?", 1)[0]
        b = self._body_json()
        # v3.4: /voice and /speed take an OPTIONAL "system". With it, the choice
        # is pinned to that system only. Without it they set the global default,
        # exactly as every earlier version did - which is also what the panel
        # sends when fewer than two systems are installed, so a single-pack user
        # keeps the old behaviour and stays in step with set_voice.py.
        if path == "/voice":
            name = (b.get("name") or "").strip()
            if name not in ALL_VOICES:
                self._send_json({"ok": False, "error": "unknown voice"}, 400)
            elif b.get("system"):
                if set_system_setting(b.get("system"), "voice", name):
                    self._send_json({"ok": True, "voice": name,
                                     "system": normalize_system(b.get("system"))})
                else:
                    self._send_json({"ok": False, "error": "unknown system"}, 400)
            else:
                with _state_lock: VOICE = name
                _save_voice(name); self._send_json({"ok": True, "voice": name})
        elif path == "/preview":
            self._send_json({"ok": preview_voice((b.get("name") or "").strip(),
                                                 speed=_clean_speed(b.get("speed")))})
        elif path == "/preview_all":
            preview_all(speed=_clean_speed(b.get("speed"))); self._send_json({"ok": True})
        elif path == "/speak":
            ok = speak_text(b.get("text") or "", system=normalize_system(b.get("system")))
            self._send_json({"ok": ok}, 200 if ok else 400)
        elif path == "/speed":
            v = _clean_speed(b.get("value"))
            if v is None:
                self._send_json({"ok": False}, 400)
            elif b.get("system"):
                if set_system_setting(b.get("system"), "speed", v):
                    self._send_json({"ok": True, "speed": v,
                                     "system": normalize_system(b.get("system"))})
                else:
                    self._send_json({"ok": False, "error": "unknown system"}, 400)
            else:
                with _state_lock: SPEED = v
                _save_speed(v); self._send_json({"ok": True, "speed": v})
        elif path == "/volume":
            try:
                v = max(0.0, min(1.0, float(b.get("value"))))
                with _state_lock: VOLUME = v
                _save_volume(v); self._send_json({"ok": True, "volume": v})
            except Exception:
                self._send_json({"ok": False}, 400)
        elif path == "/stop":
            stop_speech(); self._send_json({"ok": True})
        elif path == "/open_github":
            try:
                url = "https://github.com/Omnicapable"
                if os.name == "nt":
                    subprocess.Popen(["cmd", "/c", "start", "", "/MAX", url],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    webbrowser.open_new(url)
                self._send_json({"ok": True})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, 500)
        elif path == "/replay":
            self._send_json({"ok": replay_last()})
        elif path == "/mute":
            set_muted(bool(b.get("muted")))
            self._send_json({"ok": True, "muted": is_muted()})
        else:
            self._send_json({"error": "not found"}, 404)

def run_panel_server():
    try:
        httpd = ThreadingHTTPServer((PANEL_HOST, PANEL_PORT), PanelHandler)
    except OSError as e:
        log(f"panel port {PANEL_PORT} unavailable ({e}) - continuing without panel")
        return
    log(f"HTTP control panel on http://{PANEL_HOST}:{PANEL_PORT}")
    try:
        httpd.serve_forever()
    except Exception as e:
        log(f"panel server stopped: {e}")

# ============================================================
def main():
    log(f"tts_server v{VERSION} starting{' (MOCK)' if MOCK else ''} "
        f"| voice={VOICE} speed={SPEED} volume={VOLUME}")
    threading.Thread(target=run_panel_server, daemon=True).start()
    # v2.x auto-restart watchdog
    while True:
        try:
            run_server()
        except Exception as e:
            log(f"server error: {e}")
            time.sleep(3)

if __name__ == "__main__":
    main()

PYEOF

# --- Control panel assets (Omnicapable Voice UI) ------------------------------
cat > "$KOKORO_DIR/panel.html" << 'PANELEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Omnicapable Voice</title>
<link rel="icon" type="image/svg+xml" href="favicon.svg?v=2026-07-23-corner-labels-typebox-lower">
<link rel="icon" type="image/x-icon" href="panel.ico?v=2026-07-23-corner-labels-typebox-lower">
<link rel="shortcut icon" href="favicon.ico?v=2026-07-23-corner-labels-typebox-lower">
<!-- panel-build: 2026-07-23-corner-labels-typebox-lower -->
<meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<style>
  :root{
    --bg:#0f1115; --surface:#171a21; --surface2:#1B1E26; --border:#2a2f3a;
    --inputbg:#1E222B;
    --border-strong:#3a4150; --text:#e6e9ef; --muted:#9aa3b2; --faint:#6b7280;
    --accent:#cf9273; --accent-dim:#54321f; --hover:#3a2a1f;
    --codex:#6ea8fe; --codex-dim:#1e3a6b;
    --danger:#ff6b6b; --danger-dim:#5c2a2f; --ok:#4ade80; --radius:10px;
    --font:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    --fs:12.5px;      /* base size */
    --fs-lg:15px;     /* large - title, current voice */
    --fs-xs:10px;     /* micro - speaking status, server version only */
  }
  *{box-sizing:border-box}
  html,body{margin:0;background:var(--bg);color:var(--text);font-family:var(--font);
    font-size:var(--fs);-webkit-font-smoothing:antialiased;overflow:hidden}
  /* widget-sized: never stretches, stays centered if the window is wider.
     336px = the 280px build plus 20%. The dial fills the full content width, so
     there is no dead space either side of it. 300px is the hard floor - below
     that the orb row and the voice row start to overflow. */
  body{padding:12px 8px 8px;min-width:300px;max-width:336px;margin:0 auto}
  .sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}
  .row{display:flex;align-items:center;gap:8px}
  .between{justify-content:space-between}

  /* ---- header: centered logo | switch ---- */
  /* +8px: breathing room between the logo and the system chips */
  .header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}
  .brand{position:absolute;left:50%;transform:translateX(-50%);display:block;
    text-decoration:none}
  .header{position:relative}
  .header-spacer{width:52px;height:17px;flex:0 0 auto}
  .brand img{height:21px;width:auto;display:block}
  .brand:hover img{opacity:.8}
  .appname{color:var(--muted);font-weight:600;font-size:var(--fs)}
  .dot{width:8px;height:8px;border-radius:50%;background:var(--faint);flex:0 0 auto;
    transition:background .2s}
  .dot.on{background:var(--ok);animation:pulse 1.1s ease-in-out infinite}
  @keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.45;transform:scale(.8)}}
  .micro{font-size:var(--fs-xs);color:var(--muted)}
  .switch{width:38px;height:17px;border-radius:999px;background:var(--danger-dim);
    border:1px solid var(--border-strong);position:relative;cursor:pointer;transition:.15s;
    flex:0 0 auto}
  .switch.on{background:#1f5133;border-color:var(--ok)}
  .switch .knob{position:absolute;top:1px;left:1px;width:13px;height:13px;border-radius:50%;
    background:#cbd3e1;transition:.15s}
  .switch.on .knob{left:22px;background:#eafff1}
  /* speaker icon indicating what the switch does */
  .muteicon{display:flex;align-items:center;color:var(--muted);cursor:pointer}
  .muteicon.off{color:var(--danger)}

  /* ---- tabs (centered) ---- */
  /* +8px: matching gap between the chips and the SPEED readout below them */
  .chips{display:flex;gap:5px;flex-wrap:wrap;justify-content:center;margin-bottom:23px}
  .chip{padding:5px 12px;border-radius:999px;background:var(--surface);
    border:1px solid var(--border);color:var(--muted);cursor:pointer;
    user-select:none;transition:.15s}
  .chip.active{background:var(--surface);border-color:var(--accent);color:#fff;
    box-shadow:0 0 8px -4px var(--accent)}
  .chip.sys-codex.active{background:var(--surface);border-color:var(--codex);
    box-shadow:0 0 8px -4px var(--codex)}
  /* live dot on whichever system is actually talking - the header dot is global,
     so without this the panel implies the audio belongs to the chip you're viewing */
  .chip.talking::before{content:"";display:inline-block;width:6px;height:6px;
    border-radius:50%;background:var(--ok);margin-right:6px;vertical-align:middle;
    animation:pulse 1.1s ease-in-out infinite}

  /* ---- dial: sliders ARE the circle (speed top arc, volume bottom arc) ---- */
  .dial-head,.dial-foot{display:flex;justify-content:center;gap:8px}
  .dial-head{margin-bottom:2px}
  .dial-foot{margin-top:2px}
  .label{color:var(--muted);text-transform:uppercase;letter-spacing:.6px;text-align:center}
  .slider-val{font-variant-numeric:tabular-nums;color:var(--accent);font-weight:600}
  .dial{position:relative;width:100%;max-width:320px;margin:0 auto;aspect-ratio:1/1;
    touch-action:none}
  .dial > svg{position:absolute;inset:0;width:100%;height:100%;display:block}
  .dial .track{stroke:var(--border-strong);stroke-width:4;fill:none;stroke-linecap:round}
  .dial .fill{stroke:var(--accent);stroke-width:4;fill:none;stroke-linecap:round}
  .dial .grab{stroke:transparent;stroke-width:26;fill:none;cursor:pointer}
  .dial .thumb{fill:var(--accent);stroke:var(--bg);stroke-width:2.5;cursor:grab}
  /* visible keyboard focus (pointer users never see these) */
  .dial .thumb:focus{outline:none}
  .dial .thumb:focus-visible{stroke:#fff;stroke-width:3.5}
  .btn:focus-visible,.dd-btn:focus-visible,.segbtn:focus-visible,.chip:focus-visible,
  input[type=text]:focus-visible,.switch:focus-visible{outline:2px solid var(--accent);
    outline-offset:2px}
  .dd-item:focus{outline:none;background:var(--hover);box-shadow:inset 0 0 0 1px var(--accent)}
  /* inner full circle background - sits inside the arcs with a padding gap */
  .dial-inner{position:absolute;inset:10%;display:flex;flex-direction:column;
    justify-content:center;align-items:center;gap:9px;padding:0 16px;
    background:var(--surface);border:1px solid var(--border);border-radius:50%}
  .dial-inner .row{width:100%}

  /* ---- cards & controls ---- */
  .card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);
    padding:9px 10px;margin-bottom:8px}
  select,button,input{font-family:inherit;font-size:var(--fs);color:var(--text)}
  /* custom voice dropdown - full row width, orange highlight, height-capped */
  .voice-row{position:relative}
  /* --r-inner is the shared radius for every square corner inside the dial:
     the voice dropdown, and the flat edges of the arrow / Preview buttons.
     5px was too subtle to read against the pill curve next to it, so bumped to
     8px - clearly rounded and unified across all of them. */
  :root{--r-inner:8px}
  .dd-btn{flex:1;min-width:0;background:var(--surface2);border:1px solid var(--border-strong);
    border-radius:var(--r-inner);padding:6.5px 24px;cursor:pointer;text-align:center;
    position:relative;transition:.12s;color:#c3cad6;font-size:var(--fs);font-family:inherit}
  .dd-btn:hover{border-color:var(--accent);background:var(--hover)}
  .dd-btn::after{content:"";position:absolute;right:10px;top:50%;margin-top:-2px;
    border-left:4px solid transparent;border-right:4px solid transparent;
    border-top:5px solid var(--faint)}
  .dd-list{position:absolute;left:0;right:0;top:calc(100% + 4px);z-index:50;display:none;
    background:var(--surface2);border:1px solid var(--border-strong);border-radius:8px;
    overflow-y:auto;box-shadow:0 8px 22px rgba(0,0,0,.55);padding:4px}
  .dd-list.open{display:block}

  /* ---- scrollbars ----
     The default scrollbar is bright white against this dark UI. Restyle the two
     things that scroll - the voice dropdown and the speak box - as thin muted
     grays that read as part of the panel.
     Coverage: ::-webkit-scrollbar handles WebView2/Chromium (Windows) and WebKit
     (macOS); scrollbar-width/scrollbar-color is the Gecko fallback. On macOS the
     overlay scrollbar becomes an always-thin gray, which is consistent with the
     rest of the panel. The thumb uses a transparent border + background-clip so
     it looks inset and slim rather than filling the full gutter. */
  .dd-list,#speakInput{scrollbar-width:thin;
    scrollbar-color:var(--border-strong) transparent}
  .dd-list::-webkit-scrollbar,#speakInput::-webkit-scrollbar{width:10px;height:10px}
  .dd-list::-webkit-scrollbar-track,#speakInput::-webkit-scrollbar-track{
    background:transparent}
  .dd-list::-webkit-scrollbar-thumb,#speakInput::-webkit-scrollbar-thumb{
    background:var(--border-strong);border-radius:999px;
    border:2px solid transparent;background-clip:padding-box}
  .dd-list::-webkit-scrollbar-thumb:hover,#speakInput::-webkit-scrollbar-thumb:hover{
    background:var(--faint);border:2px solid transparent;background-clip:padding-box}
  .dd-list::-webkit-scrollbar-corner,#speakInput::-webkit-scrollbar-corner{
    background:transparent}
  .dd-group{color:var(--faint);font-size:var(--fs-xs);text-transform:uppercase;
    letter-spacing:.6px;padding:6px 8px 3px;text-align:center}
  .dd-item{padding:6px 9px;border-radius:6px;cursor:pointer;text-align:center}
  .dd-item:hover{background:var(--hover)}
  .dd-item.sel{background:var(--accent-dim);color:#fff;box-shadow:inset 0 0 0 1px var(--accent)}
  .dd-item.playing{color:var(--accent);font-weight:600}
  .btn{background:var(--surface2);border:1px solid var(--border-strong);border-radius:8px;
    padding:6.5px 12px;cursor:pointer;transition:.12s;white-space:nowrap;color:#c3cad6;
    font-size:var(--fs)}
  .btn:hover{border-color:var(--accent);background:var(--hover)}
  .btn:active{transform:translateY(1px)}
  .btn.wide{flex:1;display:flex;align-items:center;justify-content:center;gap:6px}
  /* Stop keeps an orange outline at rest; hovers red. Replay hovers green. */
  .btn.stop{border-color:var(--accent)}
  .btn.stop:hover{border-color:var(--danger);background:var(--danger-dim);color:#ffd9d9}
  .btn.replay:hover{border-color:var(--ok);background:#1c3a28;color:#d7f7e4}
  .btn.tight{padding:6.5px 9px;flex:0 0 auto}
  .btn.arrow{font-size:0;line-height:1;padding:0;min-width:30px;align-self:stretch;
    display:flex;align-items:center;justify-content:center;flex:0 0 auto}
  .btn.arrow svg{display:block;width:12px;height:12px;stroke:currentColor;
    stroke-width:2.4;fill:none;stroke-linecap:round;stroke-linejoin:round}
  /* left arrow: left side a half circle, right side square. Right arrow mirrors it.
     The flat inner edges now carry --r-inner instead of a hard 0, matching the
     dropdown between them. */
  .btn.a-left {border-radius:999px var(--r-inner) var(--r-inner) 999px}
  .btn.a-right{border-radius:var(--r-inner) 999px 999px var(--r-inner)}
  .btn.pill   {border-radius:999px}

  /* ---- spherical controls ----
     Replay / Stop / Set are pale 3D orbs. The sphere read comes from an
     off-centre radial highlight plus an inset bottom shadow; the outer shadow
     lifts them off the card. Keep them pale - a saturated fill fights the arcs. */
  .orb{border-radius:50%;border:1px solid var(--border-strong);color:#c3cad6;
    background:radial-gradient(circle at 34% 26%, #2c313f 0%, #222733 46%, #171a23 100%);
    box-shadow:inset 0 2px 5px rgba(255,255,255,.055),
               inset 0 -8px 14px rgba(0,0,0,.5),
               0 5px 12px rgba(0,0,0,.45);
    display:flex;flex-direction:column;align-items:center;justify-content:center;
    gap:2px;cursor:pointer;font-family:inherit;transition:.15s;padding:0;flex:0 0 auto}
  .orb:active{transform:translateY(1px)}
  .orb-glyph{font-size:16px;line-height:1}
  .orb-label{font-size:11px;font-weight:600;letter-spacing:.2px;line-height:1}
  /* Playback pair. Sizes and positions taken from the marked-up screenshot:
     ~70 CSS px across, centred at roughly 17% and 82% of the panel width, i.e.
     pushed out toward the edges rather than sitting together in the middle.
     space-between + 14px padding lands them at 58px and 278px in a 336px body.
     They sit on the page directly - no card behind them.

     The volume readout keeps its own centred row directly under the dial, where
     it has always been. The orbs are then pulled UP over that row by a negative
     margin so they tuck into the empty bottom corners either side of it. That
     is safe: the volume arc curves away from those corners (at the orbs' x range
     it sits ~100px higher), so nothing is covered, and the readout is centred
     while the orbs are at the far edges, leaving ~19px clear on each side. */
  /* bottom margin is the buffer between the shortcut hints and the box below.
     The negative top margin is what lifts the orbs beside the volume readout;
     easing it from -46 to -32 drops them ~14px (30% of the original lift). */
  .orbs{position:relative;display:flex;justify-content:space-between;padding:0 14px;margin:-32px 0 18px}
  body.codex-active .orbs{margin-bottom:52px}
    .orbs > .orb-wrap{transform:translateY(14px)}
  body.codex-active .orbs > .orb-wrap{transform:translateY(20px)}
  .orb-wrap{display:flex;flex-direction:column;align-items:center;gap:6px}
  .orb-play{width:58px;height:58px}
  .orb-play .orb-glyph{font-size:12px}
  .orb-play .orb-label{font-size:9.5px}
  /* shortcut hint, centred under its own orb */
  .orb-key{font-size:8.5px;color:var(--faint);line-height:1;letter-spacing:.3px;
    text-align:center}
  .speak-status{position:absolute;left:50%;top:48px;transform:translateX(-50%);
    display:flex;align-items:center;justify-content:center;gap:5px;white-space:nowrap}
  .speak-status .dot{margin-top:0}
  .speak-status .micro{display:block;line-height:8px}
  .orb.replay:hover{border-color:#86efac;color:#d7f7e4;
    box-shadow:inset 0 2px 5px rgba(255,255,255,.07),
               inset 0 -8px 14px rgba(0,0,0,.5),
               0 0 16px -2px rgba(74,222,128,.55),
               0 0 34px -6px rgba(74,222,128,.35),
               0 5px 12px rgba(0,0,0,.45);
    animation:orbpulse 1.6s ease-in-out infinite}
  /* Stop keeps the orange outline at rest, like the old button did */
  .orb.stop{border-color:var(--accent)}
  .orb.stop:hover{border-color:#ff9b9b;color:#ffe2e2;
    box-shadow:inset 0 2px 5px rgba(255,255,255,.07),
               inset 0 -8px 14px rgba(0,0,0,.5),
               0 0 16px -2px rgba(255,107,107,.6),
               0 0 34px -6px rgba(255,107,107,.4),
               0 5px 12px rgba(0,0,0,.45);
    animation:orbpulse 1.6s ease-in-out infinite}
  /* live = something is actually speaking right now (any system) */
  .orb.stop.live{border-color:#ff9b9b;color:#ffe2e2;
    box-shadow:inset 0 2px 5px rgba(255,255,255,.07),
               inset 0 -8px 14px rgba(0,0,0,.5),
               0 0 16px -2px rgba(255,107,107,.6),
               0 0 34px -6px rgba(255,107,107,.4),
               0 5px 12px rgba(0,0,0,.45);
    animation:orbpulse 1.6s ease-in-out infinite}
  @keyframes orbpulse{0%,100%{opacity:1}50%{opacity:.82}}
  /* Set orb, inside the dial */
  .orb-set{width:46px;height:46px}
  .orb-set .orb-label{font-size:10px}
  /* dirty = the chosen voice is not the active one yet, so Set must be pressed */
  .orb-set.dirty{border-color:var(--accent);color:#fff4ec;
    box-shadow:inset 0 2px 5px rgba(255,255,255,.065),
               inset 0 -6px 11px rgba(0,0,0,.5),
               0 0 13px -2px rgba(207,146,115,.7),
               0 0 28px -9px rgba(207,146,115,.62),
               0 4px 9px rgba(0,0,0,.4);
    animation:orbpulse 1.9s ease-in-out infinite}
  input[type=text]{flex:1;min-width:0;background:var(--inputbg);
    border:1px solid var(--border-strong);border-radius:8px;padding:8px 10px}
  input[type=text]::placeholder{color:var(--faint)}
  /* ---- speak box ----
     The text field sits on top with the two buttons in a row BELOW it, not
     overlapping its corner. That is deliberate: while the buttons overlapped the
     field (the old "notch"), the field's scrollbar physically ran the full
     height behind them and the focus glow bled around all four edges - neither
     could be cleanly removed. With the buttons below, the field's scrollbar ends
     exactly at the field's own bottom edge (right above the buttons), and the
     focus glow is only ever around the field, never under or beside the buttons. */
  #speakCard{position:relative;padding:10px 14px 12px;display:flex;flex-direction:column;gap:0;margin:14px 0 -6px;background:transparent;border-color:transparent}
  .speak-field{position:relative;width:100%}
  #speakInput{display:block;width:100%;background:var(--surface);
    border:1px solid var(--border-strong);border-radius:10px;padding:9px 12px 34px 11px;
    color:var(--muted);font-family:inherit;font-size:var(--fs);line-height:1.45;
    height:96px;resize:none;overflow-y:auto;transition:box-shadow .15s,border-color .15s;text-align:left}
  #speakInput::placeholder{color:var(--faint);text-align:left}
  #speakInput:focus,#speakInput:not(:placeholder-shown){text-align:left}
  /* Codex has the extra reading-mode row. Shorten only its speak field so the
     overall panel stays the same height as Cowork / Claude Code and never
     triggers a document scrollbar in the docked native window. */
  body.codex-active #speakInput{height:96px}
  body.codex-active #speakCard{margin:0 0 -10px}
  /* Gentle pale-white glow on focus rather than the hard accent outline the other
     inputs get. It surrounds the field only; there is nothing below or beside it
     to bleed onto now. */
  #speakInput:focus,#speakInput:focus-visible{outline:none;
    border-color:rgba(255,255,255,.5);
    box-shadow:0 0 0 1px rgba(255,255,255,.25),0 0 9px 0 rgba(255,255,255,.15)}
  .speak-actions{position:absolute;right:0;bottom:0;height:auto;display:flex;justify-content:flex-end;align-items:center;gap:0;margin:0;padding:0;z-index:2}
  #speakBtn{min-width:88px;border-radius:10px;padding:5px 16px;margin:0;
    background:linear-gradient(135deg,rgba(26,29,37,.58),rgba(11,13,18,.38));
    border-color:rgba(255,255,255,.16);box-shadow:0 5px 12px rgba(0,0,0,.34),inset 0 1px 0 rgba(255,255,255,.08);
    color:var(--muted);backdrop-filter:blur(4px) saturate(1.08);-webkit-backdrop-filter:blur(4px) saturate(1.08)}
  .speak-field:focus-within #speakBtn{border-color:rgba(255,255,255,.5);
    box-shadow:0 0 0 1px rgba(255,255,255,.25),0 0 9px 0 rgba(255,255,255,.15),
               0 5px 12px rgba(0,0,0,.34),inset 0 1px 0 rgba(255,255,255,.1)}
  #speakBtn:hover{border-color:var(--accent);background:rgba(58,42,31,.58);color:#fff}
  /* current voice - normal case label, voice name on its own line beneath */
  .cur-line{text-align:center;margin-bottom:2px}
  .cur-label{color:var(--faint);display:block;font-size:var(--fs);font-weight:400}
  .cur-voice{font-weight:600;display:block;margin-top:2px}
  /* label above the voice picker - same colour/size as "Current Voice:" */
  .pv-label{color:var(--faint);text-align:center;width:100%;margin-bottom:-4px;
    font-size:var(--fs);font-weight:400}

  /* Codex-only reading-mode bulbs. They sit in the playback-orb lane rather than
     adding a separate row, so switching to Codex cannot introduce page scroll. */
  .seg{position:absolute;left:50%;top:98px;transform:translate(-50%,-50%);
    z-index:2;display:none;gap:18px;margin:0;align-items:flex-start;justify-content:center;
    pointer-events:auto}
  .segbtn{width:42px;padding:0;border:0;background:transparent;cursor:pointer;
    display:flex;flex-direction:column;align-items:center;gap:4px;color:var(--faint);
    font-family:inherit;font-size:8.5px;line-height:1;letter-spacing:.3px;transition:.12s}
  .mode-bulb{width:20px;height:20px;border-radius:50%;border:1px solid var(--border-strong);
    background:radial-gradient(circle at 34% 24%, #343a48 0%, #232936 52%, #151922 100%);
    box-shadow:inset 0 2px 4px rgba(255,255,255,.07),
               inset 0 -6px 10px rgba(0,0,0,.55),
               0 4px 9px rgba(0,0,0,.42);
    transition:.15s}
  .segbtn:hover .mode-bulb{border-color:var(--codex)}
  .segbtn.on{color:var(--faint)}
  .segbtn.on .mode-bulb{border-color:rgba(110,168,254,.78);
    background:radial-gradient(circle at 34% 24%, #c9dcfb 0%, #5f94e8 38%, #244b82 100%);
    box-shadow:inset 0 2px 4px rgba(255,255,255,.22),
               inset 0 -6px 10px rgba(0,0,0,.42),
               0 0 9px -2px rgba(110,168,254,.55),
               0 0 20px -10px rgba(110,168,254,.38),
               0 4px 9px rgba(0,0,0,.38)}
  .mode-text span{display:block;text-align:center}

  .keyhint{display:flex;gap:8px;margin-top:5px}
  .keyhint:last-child{margin-bottom:-4px}   /* match the 5px gap above */
  .keyhint span{flex:1;text-align:center;font-size:8.5px;color:var(--faint);
    line-height:1;letter-spacing:.3px}
  /* clearance between the speak box and the wordmark */
  .footer{margin-top:20px;padding-bottom:16px;display:flex;flex-direction:column;
    align-items:center;gap:7px;text-align:center}
  body.codex-active .footer{margin-top:14px}
  .footer .appname{text-align:center;color:var(--muted);line-height:1.05}
  .footer .open-ui{font-size:8.5px;color:var(--faint);line-height:1.05}
  .version-corners{position:fixed;left:12px;right:12px;bottom:8px;display:flex;
    justify-content:space-between;align-items:center;pointer-events:none;z-index:4}
  .version-corners span{font-size:8.5px;color:#4b5360;line-height:1.05;
    font-variant-numeric:tabular-nums;white-space:nowrap}
  .warn{color:var(--danger)}

  #offline{position:fixed;inset:0;background:var(--bg);display:none;flex-direction:column;
    align-items:center;justify-content:center;text-align:center;padding:24px;gap:10px}
  #offline.show{display:flex}
  #offline .big{font-size:var(--fs-lg);font-weight:600}
  #offline .hint{color:var(--muted);line-height:1.5}
</style>
</head>
<body>
<h2 class="sr-only">Omnicapable text-to-speech control panel: voice, speed, volume, and playback controls.</h2>

<!-- header: speaking dot left, logo centered (-> GitHub), master power right -->
<div class="header">
  <div class="header-spacer" aria-hidden="true"></div>
  <a class="brand" id="githubLogoLink" href="https://github.com/Omnicapable" target="_blank" rel="noopener"
     title="Omnicapable on GitHub">
    <!-- official logo served verbatim: logo.svg preferred (scales cleanly at any
         size, 3.7 KB), logo.png fallback. Assets sit next to panel.html. -->
    <img id="logoImg" src="logo.svg?v=2026-07-23-corner-labels-typebox-lower" alt="Omnicapable"
         onerror="this.style.display='none';">
  </a>
  <div class="row" style="gap:6px">
    <span class="muteicon" id="muteIcon" aria-hidden="true" title="Master on/off - mute all TTS">
      <svg id="icoOn" width="14" height="14" viewBox="0 0 24 24" fill="none">
        <path d="M3 9v6h4l5 5V4L7 9H3z" fill="currentColor"/>
        <path d="M16.5 8.5a5 5 0 0 1 0 7" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
      <svg id="icoOff" width="14" height="14" viewBox="0 0 24 24" fill="none" style="display:none">
        <path d="M3 9v6h4l5 5V4L7 9H3z" fill="currentColor"/>
        <path d="M16 9l6 6M22 9l-6 6" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
    </span>
    <div class="switch on" id="powerBtn" tabindex="0" role="switch" aria-checked="true"
         aria-label="Text to speech enabled" title="Master on/off - mute all TTS"><span class="knob"></span></div>
  </div>
</div>

<!-- centered system tabs -->
<div class="chips" id="chips"></div>

<!-- speed label (top of dial) -->
<div class="dial-head"><span class="label">Speed</span>
  <span class="slider-val" id="speedVal">1.20x</span></div>

<!-- the dial: speed = top arc slider, volume = bottom arc slider, voice inside -->
<div class="dial" id="dial">
  <svg viewBox="0 0 320 320" aria-hidden="true">
    <!-- top arc (speed): 160deg -> 20deg over the top; gaps left/right center -->
    <path class="track" d="M 19.05 108.70 A 150 150 0 0 1 300.95 108.70"/>
    <path class="fill"  id="speedFill" d=""/>
    <path class="grab"  id="speedGrab" d="M 19.05 108.70 A 150 150 0 0 1 300.95 108.70"/>
    <circle class="thumb" id="speedThumb" r="8" cx="160" cy="10"
            tabindex="0" role="slider" aria-label="Speech speed"
            aria-valuemin="0.8" aria-valuemax="2" aria-valuenow="1.2" aria-valuetext="1.20 times"/>
    <!-- bottom arc (volume): 200deg -> 340deg under the bottom -->
    <path class="track" d="M 19.05 211.30 A 150 150 0 0 0 300.95 211.30"/>
    <path class="fill"  id="volFill" d=""/>
    <path class="grab"  id="volGrab" d="M 19.05 211.30 A 150 150 0 0 0 300.95 211.30"/>
    <circle class="thumb" id="volThumb" r="8" cx="160" cy="310"
            tabindex="0" role="slider" aria-label="Speech volume"
            aria-valuemin="0" aria-valuemax="100" aria-valuenow="100" aria-valuetext="100 percent"/>
  </svg>
  <div class="dial-inner">
    <div class="cur-line"><span class="cur-label" id="curLabel">Current Voice:</span><span class="cur-voice" id="curVoice">&mdash;</span></div>
    <div class="pv-label">Voices:</div>
    <div class="row voice-row">
      <button class="btn arrow a-left" id="prevBtn" title="Previous voice - plays a sample (audition only)"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 4 L7 12 L15 20"/></svg></button>
      <button class="dd-btn" id="ddBtn" aria-haspopup="listbox" aria-expanded="false"
              aria-label="Choose voice">&mdash;</button>
      <button class="btn arrow a-right" id="nextBtn" title="Next voice - plays a sample (audition only)"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 4 L17 12 L9 20"/></svg></button>
      <div class="dd-list" id="ddList" role="listbox" aria-label="Voices"></div>
    </div>
    <div class="row">
      <button class="btn wide a-left" id="previewBtn" title="Preview selected voice">&#9654; Preview</button>
      <button class="btn wide a-right" id="previewAllBtn" title="Audition every voice in sequence">Preview all</button>
    </div>
    <div class="row" style="justify-content:center">
      <button class="orb orb-set" id="setVoiceBtn"
              title="Make the selected voice active for this system">
        <span class="orb-label">Set</span>
      </button>
    </div>
  </div>
</div>

<!-- volume label (bottom of dial) - back in its own centred row -->
<div class="dial-foot"><span class="label">Volume</span>
  <span class="slider-val" id="volVal">100%</span></div>

<!-- playback orbs, pulled up either side of the volume readout.
     No card behind them - they sit on the page itself. -->
<div class="orbs">
  <div class="speak-status" id="speakStatus"><span class="dot" id="speakDot" title="ready"></span><span id="speakLbl" class="micro">ready</span></div>
  <div class="orb-wrap">
    <button class="orb orb-play replay" id="replayBtn" title="Repeat the last message">
      <span class="orb-glyph" aria-hidden="true">&#8635;</span>
      <span class="orb-label">Replay</span>
    </button>
    <span class="orb-key" id="kbReplay"></span>
  </div>
  <div class="seg" id="modeSeg" title="Codex reading mode">
    <button class="segbtn" id="modeFinal" title="Read final replies only">
      <span class="mode-bulb" aria-hidden="true"></span>
      <span class="mode-text"><span>Final</span><span>Replies</span></span>
    </button>
    <button class="segbtn" id="modeThink" title="Read final replies and thinking">
      <span class="mode-bulb" aria-hidden="true"></span>
      <span class="mode-text"><span>Final</span><span>+Thinking</span></span>
    </button>
  </div>
  <div class="orb-wrap">
    <button class="orb orb-play stop" id="stopBtn" title="Stop whatever is speaking now">
      <span class="orb-glyph" aria-hidden="true">&#9632;</span>
      <span class="orb-label">Stop</span>
    </button>
    <span class="orb-key" id="kbStop"></span>
  </div>
</div>

<!-- speak box -->
<div class="card" id="speakCard">
  <div class="speak-field">
    <textarea id="speakInput" placeholder="Type any text to hear it..."
              aria-label="Text to speak"></textarea>
    <div class="speak-actions">
      <button class="btn" id="speakBtn" title="Speak this text in the active voice">Speak</button>
    </div>
  </div>
</div>

<div class="footer">
  <span class="appname">Omnicapable Voice</span>
  <span class="open-ui" id="openUiHint"></span>
</div>
<div class="version-corners" aria-label="Version information">
  <span id="uiVerLbl">UI: v...</span>
  <span id="ttsVerLbl">v...</span>
</div>

<div id="offline">
  <div class="big">TTS server not running</div>
  <div class="hint">Start it with your restart script,<br>then reopen this panel.</div>
</div>

<script>
"use strict";
/* ---- config ---- */
var SERVER = "";
var WATCHERS = {
  cowork: "http://127.0.0.1:59011",
  codex:  "http://127.0.0.1:59012"
};
var SYS_LABEL = {cowork:"Cowork", server:"Claude Code", codex:"Codex"};
/* The chip says "Claude Code" because that is the product; the voice line reads
   "Claude's Voice:" because it is talking about whose voice it is. */
var VOICE_LABEL = {cowork:"Cowork", server:"Claude's", codex:"Codex"};
var SYS_ORDER = ["cowork","server","codex"];

var state = {voice:"-", speed:1.2, volume:100, muted:false, speaking:false,
             version:"?", claudeCode:false, systems:{}, speakingSystem:null};
/* The panel calls the Claude Code slot "server"; the server calls it
   "claude_code". Translate at the boundary rather than renaming either side. */
function activeKey(){ return active==="server" ? "claude_code" : active; }
function keyToChip(k){ return k==="claude_code" ? "server" : k; }
var systems = {};
var active = "server";
var voicesLoaded = false;
var ID2FULL = {};

/* ---- helpers ---- */
function $(id){return document.getElementById(id);}
function jget(url){return fetch(url,{cache:"no-store"}).then(function(r){return r.json();});}
function jpost(url,body){return fetch(url,{method:"POST",headers:{"Content-Type":"application/json"},
  body:JSON.stringify(body||{})}).then(function(r){return r.json().catch(function(){return{};});});}
var debounce=function(fn,ms){var t;return function(){var a=arguments,c=this;clearTimeout(t);
  t=setTimeout(function(){fn.apply(c,a);},ms);};};

/* ============================================================
   Arc sliders - speed (top arc) & volume (bottom arc) form the circle.
   Geometry: center (160,160), r=150, viewBox 320x320.
   Top arc:    theta 160deg -> 20deg  (through 90 = top)
   Bottom arc: theta 200deg -> 340deg (through 270 = bottom)
   theta measured math-style: point = (cx + r*cos, cy - r*sin)
   ============================================================ */
var CX=160, CY=160, R=150, SPAN=140;
function arcPoint(deg){
  var a=deg*Math.PI/180;
  return {x:CX+R*Math.cos(a), y:CY-R*Math.sin(a)};
}
function arcPath(fromDeg,toDeg,sweep){
  var p1=arcPoint(fromDeg), p2=arcPoint(toDeg);
  return "M "+p1.x.toFixed(2)+" "+p1.y.toFixed(2)+
         " A "+R+" "+R+" 0 0 "+sweep+" "+p2.x.toFixed(2)+" "+p2.y.toFixed(2);
}
/* frac: 0..1 left->right */
function makeArcSlider(opts){
  var dragging=false, curFrac=0, lastTouch=0;
  /* A commit is asynchronous, but poll() keeps rewriting the dial from server
     state every 2s. Without a grace period a run of keyboard nudges gets
     clobbered mid-sequence and lands on the wrong value. */
  function touched(){ lastTouch=Date.now(); }
  function degForFrac(f){ return opts.top ? 160-SPAN*f : 200+SPAN*f; }
  function setVisual(f){
    f=Math.max(0,Math.min(1,f));
    curFrac=f;
    var d=degForFrac(f), p=arcPoint(d);
    opts.thumb.setAttribute("cx",p.x.toFixed(2));
    opts.thumb.setAttribute("cy",p.y.toFixed(2));
    opts.fill.setAttribute("d", opts.top ? arcPath(160,d,1) : arcPath(200,d,0));
    opts.thumb.setAttribute("aria-valuenow", opts.ariaNow(f));
    opts.thumb.setAttribute("aria-valuetext", opts.ariaText(f));
  }
  /* keyboard: arrows nudge one step, PageUp/Dn a bigger step, Home/End the ends */
  function nudge(f){
    f=Math.max(0,Math.min(1,f));
    touched();
    setVisual(f); opts.onInput(f); opts.onCommit(f);
  }
  opts.thumb.addEventListener("keydown",function(e){
    var k=e.key, s=opts.step, b=opts.bigStep;
    if(k==="ArrowRight"||k==="ArrowUp")        nudge(curFrac+s);
    else if(k==="ArrowLeft"||k==="ArrowDown")  nudge(curFrac-s);
    else if(k==="PageUp")                      nudge(curFrac+b);
    else if(k==="PageDown")                    nudge(curFrac-b);
    else if(k==="Home")                        nudge(0);
    else if(k==="End")                         nudge(1);
    else return;
    e.preventDefault();
  });
  function fracFromEvent(e){
    var rect=$("dial").getBoundingClientRect();
    var sx=320/rect.width, sy=320/rect.height;
    var x=(e.clientX-rect.left)*sx, y=(e.clientY-rect.top)*sy;
    var deg=Math.atan2(CY-y, x-CX)*180/Math.PI;   /* math-style: top=+90 */
    if(opts.top){
      if(deg<0) deg=(deg<-90)?160:20;             /* clamp lower half */
      deg=Math.max(20,Math.min(160,deg));
      return (160-deg)/SPAN;
    }else{
      if(deg>0) deg=(deg>90)?-160:-20;            /* clamp upper half */
      deg=Math.max(-160,Math.min(-20,deg));       /* 200..340 == -160..-20 */
      return (deg+160)/SPAN;
    }
  }
  function onMove(e){ if(!dragging) return; var f=fracFromEvent(e); setVisual(f); opts.onInput(f); }
  function onDown(e){ dragging=true; e.preventDefault(); touched();
    var f=fracFromEvent(e); setVisual(f); opts.onInput(f);
    window.addEventListener("pointermove",onMove);
    window.addEventListener("pointerup",onUp,{once:true});
  }
  function onUp(e){ dragging=false; touched();
    window.removeEventListener("pointermove",onMove);
    opts.onCommit(fracFromEvent(e)); }
  opts.grab.addEventListener("pointerdown",onDown);
  opts.thumb.addEventListener("pointerdown",onDown);
  return {setVisual:setVisual, isDragging:function(){return dragging;},
          frac:function(){return curFrac;},
          /* true while a just-committed local value is still newer than polled state */
          isFresh:function(){return Date.now()-lastTouch < 2500;}};
}

/* Speed range trimmed to 0.8-2.0 (below 0.8 is unused in practice) and stepped
   at 0.01 so fine choices like 1.32 / 1.35 / 1.38 are reachable. */
var SPD_MIN=0.8, SPD_RANGE=1.2;
function spdFromFrac(f){ return Math.round((SPD_MIN+f*SPD_RANGE)*100)/100; }
var speedSlider=makeArcSlider({
  top:true, thumb:$("speedThumb"), fill:$("speedFill"), grab:$("speedGrab"),
  step:0.01/SPD_RANGE, bigStep:0.1/SPD_RANGE,          /* 0.01x and 0.10x per press */
  ariaNow:function(f){ return spdFromFrac(f).toFixed(2); },
  ariaText:function(f){ return spdFromFrac(f).toFixed(2)+"x"; },
  onInput:function(f){ $("speedVal").textContent=spdFromFrac(f).toFixed(2)+"x"; },
  onCommit:function(f){ jpost(SERVER+"/speed", scoped({value:spdFromFrac(f)})); }
});
/* What the dial reads right now - previews are auditioned at THIS speed, even
   mid-drag and even when it differs from the global default, so an audition is
   always what you are about to get. */
function dialSpeed(){ return spdFromFrac(speedSlider.frac()); }
var volSlider=makeArcSlider({
  top:false, thumb:$("volThumb"), fill:$("volFill"), grab:$("volGrab"),
  step:0.01, bigStep:0.1,                               /* 1% and 10% per press */
  ariaNow:function(f){ return Math.round(f*100); },
  ariaText:function(f){ return Math.round(f*100)+" percent"; },
  onInput:function(f){ $("volVal").textContent=Math.round(f*100)+"%"; },
  onCommit:function(f){ jpost(SERVER+"/volume",{value:Math.round(f*100)/100}); }
});

/* ---- voices: custom dropdown (orange highlight, row-width, height-capped) ---- */
var FLAT=[];        // ordered voice ids - arrows follow this exact sequence
var selVoice=null;  // currently selected/auditioned id (committed only via Set)

function loadVoices(){
  jget(SERVER+"/voices").then(function(groups){
    var list=$("ddList"); list.innerHTML=""; ID2FULL={}; FLAT=[];
    Object.keys(groups).forEach(function(cat){
      var g=document.createElement("div"); g.className="dd-group"; g.textContent=cat;
      list.appendChild(g);
      groups[cat].forEach(function(v){
        ID2FULL[v.id]=v.full; FLAT.push(v.id);
        var it=document.createElement("div");
        it.className="dd-item"; it.dataset.id=v.id; it.textContent=v.name;
        it.setAttribute("role","option"); it.setAttribute("tabindex","-1");
        it.setAttribute("aria-selected","false");
        it.onclick=function(){ selVoice=v.id; closeDD(); syncDD();
          jpost(SERVER+"/preview",{name:v.id,speed:dialSpeed()}); };
        it.onkeydown=function(e){
          if(e.key==="Enter"||e.key===" "){ e.preventDefault(); it.onclick(); }
        };
        list.appendChild(it);
      });
    });
    voicesLoaded=true;
    if(!selVoice){ var av=activeVoice(); if(av && av!=="-") selVoice=av; }
    syncDD(); render();
  }).catch(function(){});
}
function syncDD(playing){
  if(!selVoice) return;
  $("ddBtn").textContent=(ID2FULL[selVoice]||selVoice).replace(/ \(.*/,"");
  var items=$("ddList").querySelectorAll(".dd-item");
  for(var i=0;i<items.length;i++){
    var id=items[i].dataset.id;
    items[i].className="dd-item"+(id===selVoice?" sel":"")+(id===playing?" playing":"");
    items[i].setAttribute("aria-selected", id===selVoice ? "true" : "false");
  }
}
function openDD(){
  var list=$("ddList"); list.classList.add("open");
  $("ddBtn").setAttribute("aria-expanded","true");
  /* cap height so the menu never extends past the speak box */
  var limit=$("speakCard").getBoundingClientRect().bottom;
  var top=list.getBoundingClientRect().top;
  list.style.maxHeight=Math.max(120,limit-top-6)+"px";
  var sel=list.querySelector(".dd-item.sel") || list.querySelector(".dd-item");
  if(sel){
    try{ if(sel.scrollIntoView) sel.scrollIntoView({block:"center"}); }catch(_){}
    sel.focus();   /* must still happen even if scrolling is unavailable */
  }
}
function closeDD(refocus){
  $("ddList").classList.remove("open");
  $("ddBtn").setAttribute("aria-expanded","false");
  if(refocus) $("ddBtn").focus();
}
$("ddBtn").onclick=function(e){ e.stopPropagation();
  $("ddList").classList.contains("open")?closeDD():openDD(); };
$("ddBtn").onkeydown=function(e){
  if(e.key==="ArrowDown"||e.key==="ArrowUp"){ e.preventDefault(); openDD(); }
};
/* roving focus through the open list; Esc closes and returns focus to the button */
$("ddList").addEventListener("keydown",function(e){
  var items=[].slice.call($("ddList").querySelectorAll(".dd-item"));
  var i=items.indexOf(document.activeElement);
  if(e.key==="ArrowDown"){ e.preventDefault(); (items[i+1]||items[0]).focus(); }
  else if(e.key==="ArrowUp"){ e.preventDefault(); (items[i-1]||items[items.length-1]).focus(); }
  else if(e.key==="Home"){ e.preventDefault(); items[0].focus(); }
  else if(e.key==="End"){ e.preventDefault(); items[items.length-1].focus(); }
  else if(e.key==="Escape"){ e.preventDefault(); closeDD(true); }
});
document.addEventListener("click",function(e){
  if(!e.target.closest(".voice-row")) closeDD(); });

/* ---- render ---- */
/* Which systems are actually installed?
   - cowork / codex announce themselves on 59011 / 59012 (see `systems`)
   - Claude Code has no watcher - it speaks through a Stop hook - so the server
     reports whether that hook exists (state.claude_code)
   The "server" key is the Claude Code slot; it is no longer assumed present. */
function presentSystems(){
  return SYS_ORDER.filter(function(k){
    return k==="server" ? state.claudeCode : (k in systems);
  });
}
/* ---- scoping ----
   Voice and speed belong to the system on the active chip. Volume and the
   master mute do NOT - there is one output stream and one master switch.

   With fewer than two systems installed there is nothing to switch between, so
   the panel sends no system at all and writes the global default instead. That
   keeps a single-pack install behaving exactly as it did before per-system
   settings existed, and keeps the panel in step with set_voice.py/set_speed.py.  */
function scopedSystem(){
  return presentSystems().length >= 2 ? activeKey() : null;
}
function scoped(body){
  var s=scopedSystem(); if(s) body.system=s;
  return body;
}
function activeVoice(){
  if(!scopedSystem()) return state.voice;
  var s=state.systems[activeKey()];
  return (s && s.voice) || state.voice;
}
function activeSpeed(){
  if(!scopedSystem()) return state.speed;
  var s=state.systems[activeKey()];
  return (s && typeof s.speed==="number") ? s.speed : state.speed;
}
function renderChips(){
  var box=$("chips"), present=presentSystems();
  var talking=(state.speaking && !state.muted && state.speakingSystem)
              ? keyToChip(state.speakingSystem) : null;
  box.innerHTML="";
  /* One system (or none detected) means there is nothing to switch between,
     so the row is just noise - hide it and drive everything from that system. */
  if(present.length<2){
    box.style.display="none";
    active = present.length ? present[0] : "server";
    return;
  }
  box.style.display="flex";
  present.forEach(function(k){
    var c=document.createElement("div");
    c.className="chip sys-"+k+(k===active?" active":"")+(k===talking?" talking":"");
    c.textContent=SYS_LABEL[k];
    c.tabIndex=0;
    /* switching chips retargets the voice picker and the dial at that system -
       full render(), not just the chip row */
    c.onclick=function(){active=k;selVoice=activeVoice();render(true);};
    c.onkeydown=function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();c.onclick();}};
    box.appendChild(c);
  });
}
function renderMode(){
  document.body.classList.toggle("codex-active", active==="codex");
  var seg=$("modeSeg");
  if(active!=="codex"){ seg.style.display="none"; return; }
  seg.style.display="flex";
  var m=(systems.codex&&systems.codex.mode==="all")?"all":"final";
  $("modeFinal").className="segbtn"+(m==="final"?" on":"");
  $("modeThink").className="segbtn"+(m==="all"?" on":"");
}
/* force=true bypasses the just-edited grace period. Switching chips must retarget
   the dials at once, even if you nudged one a moment ago. */
function render(force){
  /* voice + speed are shown for the ACTIVE system; volume and mute stay global */
  var av=activeVoice(), asp=activeSpeed();
  /* name only - the accent/gender is in the picker, not the headline */
  $("curVoice").textContent=(ID2FULL[av]||av).replace(/ \(.*/,"");
  /* say whose voice this is once there is more than one system to confuse it with */
  $("curLabel").textContent=scopedSystem() ? VOICE_LABEL[active]+" Voice:" : "Current Voice:";
  /* Set glows while the chosen voice is not yet the active one - including after
     a preview - so it is obvious the choice still has to be committed.
     Speed and volume are NOT part of this: they apply the moment you release the
     dial, so implying they need committing would be a lie. */
  var dirty = !!(selVoice && selVoice !== av);
  $("setVoiceBtn").className = "orb orb-set" + (dirty ? " dirty" : "");
  $("setVoiceBtn").title = dirty
    ? "Press to make " + ((ID2FULL[selVoice]||selVoice).replace(/ \(.*/,"")) + " the active voice"
    : "Selected voice is already active";
  /* while Preview all runs, follow the voice being auditioned live */
  if(state.previewing){ selVoice=state.previewing; syncDD(state.previewing); }
  else if(voicesLoaded) syncDD();
  if(!speedSlider.isDragging() && (force || !speedSlider.isFresh())){
    speedSlider.setVisual((asp-SPD_MIN)/SPD_RANGE);
    $("speedVal").textContent=(+asp).toFixed(2)+"x";
  }
  if(!volSlider.isDragging() && !volSlider.isFresh()){
    volSlider.setVisual(state.volume/100);
    $("volVal").textContent=Math.round(state.volume)+"%";
  }
  var sp=state.speaking&&!state.muted;
  $("speakDot").className="dot"+(sp?" on":""); $("speakDot").title=sp?"speaking":"ready"; $("speakLbl").textContent=sp?"speaking":"ready";
  /* Stop glows whenever ANY system is speaking - it stops the shared output
     stream, so it is never scoped to the chip you happen to be viewing. */
  $("stopBtn").className="orb orb-play stop"+(sp?" live":"");
  $("stopBtn").title=sp?"Stop what is speaking now":"Nothing is speaking";
  $("powerBtn").className="switch"+(state.muted?"":" on");
  $("powerBtn").title=state.muted?"TTS off - click to enable":"TTS on - click to mute all";
  $("powerBtn").setAttribute("aria-checked", state.muted?"false":"true");
  $("powerBtn").setAttribute("aria-label", state.muted?"Text to speech muted":"Text to speech enabled");
  $("muteIcon").className="muteicon"+(state.muted?" off":"");
  $("icoOn").style.display=state.muted?"none":"block";
  $("icoOff").style.display=state.muted?"block":"none";
    var selectedVersion = active==="server" ? state.version : ((systems[active] && systems[active].version) || "?");
  $("uiVerLbl").textContent="UI: v"+state.version;
  $("ttsVerLbl").textContent="v"+selectedVersion;
  renderChips(); renderMode();
}

/* ---- polling ---- */
function poll(){
  jget(SERVER+"/state").then(function(st){
    $("offline").classList.remove("show");
    state.voice=st.voice; state.speed=st.speed; state.volume=Math.round((st.volume||0)*100);
    state.muted=!!st.muted; state.speaking=!!st.speaking; state.version=st.version||"?";
    state.previewing=st.previewing||null;
    state.claudeCode=!!st.claude_code;
    /* per-system resolved voice/speed (server v3.3+). An older server omits it,
       in which case every helper falls back to the global values. */
    state.systems=st.systems||{};
    state.speakingSystem=st.speaking_system||null;
    if(!voicesLoaded) loadVoices();
    return probeWatchers();
  }).then(function(){render();}).catch(function(){
    $("offline").classList.add("show"); $("uiVerLbl").textContent="UI: offline"; $("ttsVerLbl").textContent="";
  });
}
function probeWatchers(){
  var jobs=Object.keys(WATCHERS).map(function(k){
    return jget(WATCHERS[k]+"/state").then(function(s){systems[k]={mode:s.mode,last_text:s.last_text,version:s.version};})
      .catch(function(){delete systems[k];});
  });
  return Promise.all(jobs).then(function(){
    var present=presentSystems();
    if(present.length && present.indexOf(active)<0) active=present[0];
  });
}

/* ---- actions ---- */
$("powerBtn").onclick=function(){jpost(SERVER+"/mute",{muted:!state.muted}).then(poll);};
$("powerBtn").onkeydown=function(e){
  if(e.key==="Enter"||e.key===" "){ e.preventDefault(); $("powerBtn").onclick(); }
};
$("muteIcon").onclick=$("powerBtn").onclick;
$("githubLogoLink").addEventListener("click",function(e){
  e.preventDefault();
  fetch(SERVER+"/open_github",{method:"POST"}).catch(function(){
    window.open("https://github.com/Omnicapable","_blank","noopener");
  });
});
$("setVoiceBtn").onclick=function(){
  if(!selVoice) return;
  jpost(SERVER+"/voice",scoped({name:selVoice})).then(poll);
};
/* previews carry the dial's current speed - see dialSpeed() */
$("previewBtn").onclick=function(){
  if(selVoice) jpost(SERVER+"/preview",{name:selVoice,speed:dialSpeed()}); };
$("previewAllBtn").onclick=function(){jpost(SERVER+"/preview_all",{speed:dialSpeed()});};
/* arrows: step through FLAT (same order as the dropdown) and play that voice.
   Audition only - the active voice changes when you press Set. */
function stepVoice(dir){
  if(!FLAT.length) return;
  var i=FLAT.indexOf(selVoice); if(i<0) i=0; else i+=dir;
  if(i<0) i=FLAT.length-1; if(i>=FLAT.length) i=0;
  selVoice=FLAT[i]; syncDD();
  jpost(SERVER+"/preview",{name:selVoice,speed:dialSpeed()});
}
$("prevBtn").onclick=function(){stepVoice(-1);};
$("nextBtn").onclick=function(){stepVoice(1);};
function doStop(){jpost(SERVER+"/stop");}
function doReplay(){
  if(active==="server"||!(active in systems)) jpost(SERVER+"/replay");
  else jpost(WATCHERS[active]+"/replay");
}
$("stopBtn").onclick=doStop;
$("replayBtn").onclick=doReplay;

/* ---- keyboard shortcuts (labelled for the host platform) ---- */
var IS_MAC=/Mac|iPhone|iPad/.test(navigator.platform||navigator.userAgent);
/* These are the OS-level hotkeys registered by the TTS Pack hotkey daemon
   (tts_hotkey.py on Windows, tts_hotkey_mac.py on macOS). They work system-wide,
   so the panel only labels them - it must not also handle them, or a single
   press would fire twice. */
$("kbReplay").textContent = IS_MAC ? "Ctrl+Option+R" : "Ctrl+Alt+R";
$("kbStop").textContent   = IS_MAC ? "Ctrl+Option+X" : "Ctrl+Alt+X";
$("openUiHint").textContent = "Open: " + (IS_MAC ? "Ctrl+Option+Space" : "Ctrl+Alt+Space");
$("modeFinal").onclick=function(){jpost(WATCHERS.codex+"/mode",{mode:"final"}).then(poll);};
$("modeThink").onclick=function(){jpost(WATCHERS.codex+"/mode",{mode:"all"}).then(poll);};
/* the speak box reads in the active system's voice - and tagging it also stops
   it being mistaken for the untagged Claude Code hook on the server side */
function doSpeak(){var t=$("speakInput").value;if(t.trim())jpost(SERVER+"/speak",scoped({text:t}));}
$("speakBtn").onclick=doSpeak;
/* now a textarea: Enter speaks, Shift+Enter starts a new line */
$("speakInput").addEventListener("keydown",function(e){
  if(e.key==="Enter" && !e.shiftKey){ e.preventDefault(); doSpeak(); }
});

poll(); setInterval(poll,2000);
</script>
</body>
</html>









PANELEOF

cat > "$KOKORO_DIR/logo.svg" << 'SVGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg id="Layer_1" xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 792.2 686.13">
  <!-- Generator: Adobe Illustrator 30.6.0, SVG Export Plug-In . SVG Version: 2.1.4 Build 109)  -->
  <defs>
    <style>
      .st0 {
        fill: #fff;
      }
    </style>
  </defs>
  <path class="st0" d="M389.23.53c25.09-3.81,48.51,13.47,52.27,38.56,3.77,25.1-13.56,48.48-38.66,52.19-25.04,3.7-48.34-13.56-52.1-38.59-3.75-25.03,13.47-48.37,38.49-52.17h0Z"/>
  <path class="st0" d="M788.51,399.74c-5.74-6.56-32.71-22.71-41.31-28.34l-95.69-62.75c-11.06-7.23-63.94-42.08-81.77-54.62-.09-.06-.17-.11-.25-.17l.23-.61-.24.6c-4.07-2.93-6.72-7.71-6.72-13.11,0-8.91,7.22-16.13,16.13-16.13.55,0,1.09.04,1.63.09.05,0,.11.02.17.02.14.01.28.02.41.05,6.32.74,12.76,2.81,18.92,4.34l30.75,7.67,91.83,22.85c14.19,3.52,28.37,7.21,42.59,10.58,13.51,3.5,20.77-3.51,22.36-16.76,1.3-10.83,4.17-23.09,4.07-34.04-.09-9.11-7.35-13.28-15.57-14.74-15.08-2.68-30.47-4.8-45.7-7.15l-93.84-14.47-118.34-18.26c-17.71-2.73-40.35-7.06-57.74-8.88-12.25-1.52-16.95,7.11-24.34,14.46-9.43,9.42-22.05,14.95-35.36,15.51-1.49.07-3.03.08-4.61.05h0s-.01,0-.02,0c0,0-.01,0-.02,0h0c-1.58.03-3.12.02-4.61-.05-13.31-.56-25.93-6.09-35.36-15.51-7.39-7.35-12.09-15.98-24.34-14.46-17.39,1.82-40.03,6.15-57.74,8.88l-118.34,18.26-93.84,14.47c-15.23,2.35-30.62,4.47-45.7,7.15-8.22,1.46-15.48,5.63-15.57,14.74-.1,10.95,2.77,23.21,4.07,34.04,1.59,13.25,8.85,20.26,22.36,16.76,14.22-3.37,28.4-7.06,42.59-10.58l91.83-22.85,30.75-7.67c6.16-1.53,12.6-3.6,18.92-4.34.13-.03.27-.04.41-.05.06,0,.12-.02.17-.02.54-.05,1.08-.09,1.63-.09,8.91,0,16.13,7.22,16.13,16.13,0,5.4-2.65,10.18-6.72,13.11l-.24-.6.23.61c-.08.06-.16.11-.25.17-17.83,12.54-70.71,47.39-81.77,54.62l-95.69,62.75c-8.6,5.62-35.57,21.78-41.31,28.34-2.67,3.06-4.07,7.67-3.6,11.71.94,8.13,19.64,35.52,26.27,40.61,3.36,2.58,6.63,3.71,10.86,2.95,2.23-.4,4.19-1.32,6.09-2.55,5.2-3.38,10.06-7.73,15.04-11.46l38.15-28.73,114.27-86.79s24.58-18.84,43.34-32.08c.17-.12.33-.23.5-.34.04-.03.08-.06.13-.08,2.09-1.35,4.21-2.12,6.3-2.39.04,0,.09-.01.13-.02.04,0,.08,0,.12-.01,6.24-.89,12.54,1.99,15.8,7.86,1.86,3.34,2.52,7.02,2.03,10.53-.03.59-.14,1.19-.34,1.81-3.06,9.17-10.89,22.91-13.75,28.51l-24.13,47.58-90.16,178.31-20.22,40.11c-2.66,5.24-5.32,10.94-8.24,16.14-13.56,24.17,13.06,28.71,29.03,38.09,24.71,14.52,29.85-3.34,39.14-22.68l18.04-37.49,90.6-190.6,21.67-45.71c3.9-8.29,8.82-20.32,13.97-27.71.07-.1.14-.18.21-.28.23-.39.47-.77.73-1.14,5.17-7.26,15.24-8.96,22.5-3.79,4.07,2.9,6.37,7.34,6.71,11.96.12.68.22,1.37.27,2.09.55,8.84.04,17.8-.19,26.82-.38,15.46-.67,30.91-.88,46.37l-3.27,189.41c-.32,14.88-.56,29.76-.7,44.64-.14,10.03-2.76,24.17,5.98,30.92,1.85,1.46,4.02,2.43,6.34,2.85,3.7.69,13.76.99,23.65.97h.04c9.89.02,19.94-.28,23.65-.97,2.32-.42,4.49-1.39,6.34-2.85,8.74-6.75,6.12-20.89,5.98-30.92-.14-14.88-.38-29.76-.7-44.64l-3.27-189.41c-.21-15.46-.5-30.91-.88-46.37-.23-9.02-.74-17.98-.19-26.82.05-.72.15-1.41.27-2.09.34-4.62,2.64-9.06,6.71-11.96,7.26-5.17,17.33-3.47,22.5,3.79.26.37.5.75.73,1.14.07.1.14.18.21.28,5.15,7.39,10.07,19.42,13.97,27.71l21.67,45.71,90.6,190.6,18.04,37.49c9.29,19.34,14.43,37.2,39.14,22.68,15.97-9.38,42.59-13.92,29.03-38.09-2.92-5.2-5.58-10.9-8.24-16.14l-20.22-40.11-90.16-178.31-24.13-47.58c-2.86-5.6-10.69-19.34-13.75-28.51-.2-.62-.31-1.22-.34-1.81-.49-3.51.17-7.19,2.03-10.53,3.26-5.87,9.56-8.75,15.8-7.86.04.01.08.01.12.01.04,0,.09.02.13.02,2.09.27,4.21,1.04,6.3,2.39.05.02.09.05.13.08.17.11.33.22.5.34,18.76,13.24,43.34,32.08,43.34,32.08l114.27,86.79,38.15,28.73c4.98,3.73,9.84,8.08,15.04,11.46,1.9,1.23,3.86,2.15,6.09,2.55,4.23.76,7.5-.37,10.86-2.95,6.63-5.09,25.33-32.48,26.27-40.61.47-4.04-.93-8.65-3.6-11.71Z"/>
</svg>
SVGEOF

cat > "$KOKORO_DIR/favicon.svg" << 'FAVSVGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg id="Layer_1" xmlns="http://www.w3.org/2000/svg" version="1.1" viewBox="0 0 792.2 686.13">
  <!-- Generator: Adobe Illustrator 30.6.0, SVG Export Plug-In . SVG Version: 2.1.4 Build 109)  -->
  <defs>
    <style>
      .st0 {
        fill: #fff;
      }
    </style>
  </defs>
  <path class="st0" d="M389.23.53c25.09-3.81,48.51,13.47,52.27,38.56,3.77,25.1-13.56,48.48-38.66,52.19-25.04,3.7-48.34-13.56-52.1-38.59-3.75-25.03,13.47-48.37,38.49-52.17h0Z"/>
  <path class="st0" d="M788.51,399.74c-5.74-6.56-32.71-22.71-41.31-28.34l-95.69-62.75c-11.06-7.23-63.94-42.08-81.77-54.62-.09-.06-.17-.11-.25-.17l.23-.61-.24.6c-4.07-2.93-6.72-7.71-6.72-13.11,0-8.91,7.22-16.13,16.13-16.13.55,0,1.09.04,1.63.09.05,0,.11.02.17.02.14.01.28.02.41.05,6.32.74,12.76,2.81,18.92,4.34l30.75,7.67,91.83,22.85c14.19,3.52,28.37,7.21,42.59,10.58,13.51,3.5,20.77-3.51,22.36-16.76,1.3-10.83,4.17-23.09,4.07-34.04-.09-9.11-7.35-13.28-15.57-14.74-15.08-2.68-30.47-4.8-45.7-7.15l-93.84-14.47-118.34-18.26c-17.71-2.73-40.35-7.06-57.74-8.88-12.25-1.52-16.95,7.11-24.34,14.46-9.43,9.42-22.05,14.95-35.36,15.51-1.49.07-3.03.08-4.61.05h0s-.01,0-.02,0c0,0-.01,0-.02,0h0c-1.58.03-3.12.02-4.61-.05-13.31-.56-25.93-6.09-35.36-15.51-7.39-7.35-12.09-15.98-24.34-14.46-17.39,1.82-40.03,6.15-57.74,8.88l-118.34,18.26-93.84,14.47c-15.23,2.35-30.62,4.47-45.7,7.15-8.22,1.46-15.48,5.63-15.57,14.74-.1,10.95,2.77,23.21,4.07,34.04,1.59,13.25,8.85,20.26,22.36,16.76,14.22-3.37,28.4-7.06,42.59-10.58l91.83-22.85,30.75-7.67c6.16-1.53,12.6-3.6,18.92-4.34.13-.03.27-.04.41-.05.06,0,.12-.02.17-.02.54-.05,1.08-.09,1.63-.09,8.91,0,16.13,7.22,16.13,16.13,0,5.4-2.65,10.18-6.72,13.11l-.24-.6.23.61c-.08.06-.16.11-.25.17-17.83,12.54-70.71,47.39-81.77,54.62l-95.69,62.75c-8.6,5.62-35.57,21.78-41.31,28.34-2.67,3.06-4.07,7.67-3.6,11.71.94,8.13,19.64,35.52,26.27,40.61,3.36,2.58,6.63,3.71,10.86,2.95,2.23-.4,4.19-1.32,6.09-2.55,5.2-3.38,10.06-7.73,15.04-11.46l38.15-28.73,114.27-86.79s24.58-18.84,43.34-32.08c.17-.12.33-.23.5-.34.04-.03.08-.06.13-.08,2.09-1.35,4.21-2.12,6.3-2.39.04,0,.09-.01.13-.02.04,0,.08,0,.12-.01,6.24-.89,12.54,1.99,15.8,7.86,1.86,3.34,2.52,7.02,2.03,10.53-.03.59-.14,1.19-.34,1.81-3.06,9.17-10.89,22.91-13.75,28.51l-24.13,47.58-90.16,178.31-20.22,40.11c-2.66,5.24-5.32,10.94-8.24,16.14-13.56,24.17,13.06,28.71,29.03,38.09,24.71,14.52,29.85-3.34,39.14-22.68l18.04-37.49,90.6-190.6,21.67-45.71c3.9-8.29,8.82-20.32,13.97-27.71.07-.1.14-.18.21-.28.23-.39.47-.77.73-1.14,5.17-7.26,15.24-8.96,22.5-3.79,4.07,2.9,6.37,7.34,6.71,11.96.12.68.22,1.37.27,2.09.55,8.84.04,17.8-.19,26.82-.38,15.46-.67,30.91-.88,46.37l-3.27,189.41c-.32,14.88-.56,29.76-.7,44.64-.14,10.03-2.76,24.17,5.98,30.92,1.85,1.46,4.02,2.43,6.34,2.85,3.7.69,13.76.99,23.65.97h.04c9.89.02,19.94-.28,23.65-.97,2.32-.42,4.49-1.39,6.34-2.85,8.74-6.75,6.12-20.89,5.98-30.92-.14-14.88-.38-29.76-.7-44.64l-3.27-189.41c-.21-15.46-.5-30.91-.88-46.37-.23-9.02-.74-17.98-.19-26.82.05-.72.15-1.41.27-2.09.34-4.62,2.64-9.06,6.71-11.96,7.26-5.17,17.33-3.47,22.5,3.79.26.37.5.75.73,1.14.07.1.14.18.21.28,5.15,7.39,10.07,19.42,13.97,27.71l21.67,45.71,90.6,190.6,18.04,37.49c9.29,19.34,14.43,37.2,39.14,22.68,15.97-9.38,42.59-13.92,29.03-38.09-2.92-5.2-5.58-10.9-8.24-16.14l-20.22-40.11-90.16-178.31-24.13-47.58c-2.86-5.6-10.69-19.34-13.75-28.51-.2-.62-.31-1.22-.34-1.81-.49-3.51.17-7.19,2.03-10.53,3.26-5.87,9.56-8.75,15.8-7.86.04.01.08.01.12.01.04,0,.09.02.13.02,2.09.27,4.21,1.04,6.3,2.39.05.02.09.05.13.08.17.11.33.22.5.34,18.76,13.24,43.34,32.08,43.34,32.08l114.27,86.79,38.15,28.73c4.98,3.73,9.84,8.08,15.04,11.46,1.9,1.23,3.86,2.15,6.09,2.55,4.23.76,7.5-.37,10.86-2.95,6.63-5.09,25.33-32.48,26.27-40.61.47-4.04-.93-8.65-3.6-11.71Z"/>
</svg>
FAVSVGEOF

cat > "$KOKORO_DIR/panel.ico.b64" << 'ICOB64EOF'
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
ICOB64EOF
if base64 --decode "$KOKORO_DIR/panel.ico.b64" > "$KOKORO_DIR/panel.ico" 2>/dev/null; then
    :
else
    base64 -D -i "$KOKORO_DIR/panel.ico.b64" -o "$KOKORO_DIR/panel.ico"
fi
rm -f "$KOKORO_DIR/panel.ico.b64"

cat > "$KOKORO_DIR/favicon.ico.b64" << 'FAVICOB64EOF'
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
FAVICOB64EOF
if base64 --decode "$KOKORO_DIR/favicon.ico.b64" > "$KOKORO_DIR/favicon.ico" 2>/dev/null; then
    :
else
    base64 -D -i "$KOKORO_DIR/favicon.ico.b64" -o "$KOKORO_DIR/favicon.ico"
fi
rm -f "$KOKORO_DIR/favicon.ico.b64"

cat > "$KOKORO_DIR/panel_app.py" << 'APPEOF'
# -*- coding: utf-8 -*-
"""
panel_app.py - opens the Omnicapable Voice panel as a real desktop mini-app
window instead of a browser tab.

Uses pywebview, which wraps the system web engine (WebView2 on Windows, WebKit
on macOS) in a native window: no tabs, no address bar, no browser UI at all.

    pip install pywebview
    pythonw panel_app.py          # normal window
    pythonw panel_app.py --top    # floats above other windows ("pinned")

Flags:
    --top           keep the window floating above all other windows
    --frameless     hide the title bar entirely (drag the panel body to move)

Sizing and placement are decided BEFORE the window is created, then confirmed
on the native window handle while the window is still hidden. That is deliberate:
the old build opened at a default spot and then corrected itself once the page
had loaded, which read as a visible jump. A fixed window that never twitches
looks far more finished.

WIDTH/HEIGHT are the native outer window size. The width preserves the 336px
body, while the height is trimmed to remove empty footer slack below TTS v3.4.
"""
import os
import sys
import time

import webview

if sys.platform == "win32":
    try:
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Omnicapable.Voice.Panel")
    except Exception:
        pass

URL = "http://127.0.0.1:59010"

# NOTE: pywebview's width/height are the OUTER window, not the web viewport.
# The native frame costs about 16x38 around the page; the 736px viewport target
# keeps the footer visible while cutting the old empty space below TTS v3.4.
FRAME_W, FRAME_H = 16, 38
WIDTH, HEIGHT = 336 + FRAME_W, 736 + FRAME_H
MIN_WIDTH     = 300          # panel.html starts to overflow below this
MIN_HEIGHT    = 520
CORNER_MARGIN = 14           # small buffer from the bottom-right corner so the
                             # window sits in the corner without touching the
                             # very edge and never spills off-screen

on_top    = "--top" in sys.argv
frameless = "--frameless" in sys.argv


def _work_area():
    """(left, top, width, height) of the usable desktop, excluding the Windows
    taskbar / macOS menu bar and Dock. Returns None if it cannot be determined,
    in which case pywebview centres the window as before."""
    # Windows: SPI_GETWORKAREA is the only call that accounts for the taskbar.
    if sys.platform == "win32":
        # Deliberately do NOT call SetProcessDpiAwareness here. Doing so flips the
        # process into physical pixels (e.g. 2560x1528 instead of 1707x1019 on a
        # 150% display), and pywebview's width/height/x/y are logical pixels - the
        # window would come out about two thirds of its intended size.
        try:
            import ctypes
            from ctypes import wintypes
            r = wintypes.RECT()
            if ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(r), 0):
                return r.left, r.top, r.right - r.left, r.bottom - r.top
        except Exception:
            pass
    # macOS: visibleFrame already excludes the menu bar and Dock. Cocoa's origin
    # is bottom-left, so flip it into the top-left coordinates pywebview wants.
    elif sys.platform == "darwin":
        try:
            from AppKit import NSScreen
            scr = NSScreen.mainScreen()
            vf, full = scr.visibleFrame(), scr.frame()
            top = full.size.height - (vf.origin.y + vf.size.height)
            return int(vf.origin.x), int(top), int(vf.size.width), int(vf.size.height)
        except Exception:
            pass
    # Anything else: pywebview's own screen list.
    try:
        s = webview.screens[0]
        return 0, 0, int(s.width), int(s.height)
    except Exception:
        return None


def _placement():
    """Dock to the BOTTOM-right corner of the work area, with a small buffer, and
    clamp so no edge ever leaves the screen (if the window is taller than the work
    area it pins to the top-left rather than hanging off)."""
    area = _work_area()
    if not area:
        return {}
    left, top, width, height = area
    x = left + width - WIDTH - CORNER_MARGIN
    y = top + height - HEIGHT - CORNER_MARGIN
    return {"x": max(left, x), "y": max(top, y)}

def _find_window_handle(timeout=1.0):
    """Return this process's native Windows panel handle, if it exists."""
    if sys.platform != "win32":
        return None
    try:
        import ctypes
        from ctypes import wintypes
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        user32.FindWindowW.restype = ctypes.c_void_p
        user32.EnumWindows.argtypes = (ctypes.c_void_p, ctypes.c_void_p)
        user32.GetWindowThreadProcessId.argtypes = (ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD))
        user32.GetParent.argtypes = (ctypes.c_void_p,)
        user32.GetParent.restype = ctypes.c_void_p
        current_pid = kernel32.GetCurrentProcessId()

        def locate():
            hwnd = user32.FindWindowW(None, "Omnicapable Voice")
            if hwnd:
                return hwnd
            found = []

            @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
            def enum_proc(candidate, _lparam):
                pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(candidate, ctypes.byref(pid))
                if pid.value == current_pid and not user32.GetParent(candidate):
                    found.append(candidate)
                    return False
                return True

            user32.EnumWindows(enum_proc, None)
            return found[0] if found else None

        deadline = time.time() + timeout
        while time.time() <= deadline:
            hwnd = locate()
            if hwnd:
                return hwnd
            time.sleep(0.025)
    except Exception:
        return None
    return None
def _force_position(win=None):
    """Dock to the actual monitor work area without mixing coordinate systems.

    pywebview still owns the logical size, but Windows multi-monitor/DPI setups
    can report a different physical rectangle for the native handle. So the
    final Windows pass measures the real window rectangle and docks that same
    rectangle inside its nearest monitor's work area. That keeps the panel
    visible even on scaled or offset displays.
    """
    place = _placement()
    try:
        if win is not None:
            try:
                win.resize(WIDTH, HEIGHT)
            except Exception:
                pass
            if place:
                try:
                    win.move(int(place["x"]), int(place["y"]))
                except Exception:
                    pass
    except Exception:
        pass
    if sys.platform != "win32":
        return
    try:
        import ctypes
        from ctypes import wintypes
        hwnd = _find_window_handle(timeout=1.0)
        if not hwnd:
            return

        user32 = ctypes.windll.user32

        class RECT(ctypes.Structure):
            _fields_ = [
                ("left", ctypes.c_long),
                ("top", ctypes.c_long),
                ("right", ctypes.c_long),
                ("bottom", ctypes.c_long),
            ]

        class MONITORINFO(ctypes.Structure):
            _fields_ = [
                ("cbSize", ctypes.c_ulong),
                ("rcMonitor", RECT),
                ("rcWork", RECT),
                ("dwFlags", ctypes.c_ulong),
            ]

        user32.GetWindowRect.argtypes = (ctypes.c_void_p, ctypes.POINTER(RECT))
        user32.MonitorFromWindow.argtypes = (ctypes.c_void_p, ctypes.c_uint)
        user32.MonitorFromWindow.restype = ctypes.c_void_p
        user32.GetMonitorInfoW.argtypes = (ctypes.c_void_p, ctypes.POINTER(MONITORINFO))
        user32.SetWindowPos.argtypes = (
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, ctypes.c_int, ctypes.c_uint
        )

        rect = RECT()
        if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            return
        mon = user32.MonitorFromWindow(hwnd, 0x00000002)  # MONITOR_DEFAULTTONEAREST
        if not mon:
            return
        info = MONITORINFO()
        info.cbSize = ctypes.sizeof(MONITORINFO)
        if not user32.GetMonitorInfoW(mon, ctypes.byref(info)):
            return

        actual_w = max(1, rect.right - rect.left)
        actual_h = max(1, rect.bottom - rect.top)
        margin = CORNER_MARGIN
        x = info.rcWork.right - actual_w - margin
        y = info.rcWork.bottom - actual_h - margin
        x = max(info.rcWork.left + margin, x)
        y = max(info.rcWork.top + margin, y)

        SWP_NOSIZE = 0x0001
        SWP_NOZORDER = 0x0004
        SWP_NOACTIVATE = 0x0010
        user32.SetWindowPos(
            hwnd, None, int(x), int(y),
            0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        )
    except Exception:
        pass

def _on_start(win):
    """Runs once the GUI loop is up. Dock and brand the window while it is still
    hidden, then show it so it appears already at its final size, position and
    icon, with none of the open-then-jump the old build had."""
    _force_position(win)
    _apply_icon()
    try:
        win.show()
    except Exception:
        pass
    _force_position(win)
    _apply_icon()
def _apply_icon(_window=None):
    """Put the Omnicapable mark on the window and its taskbar button.

    pywebview has no cross-platform icon option for the Windows backend, so the
    icon is pushed onto the native window handle with WM_SETICON - the same
    panel.ico the desktop shortcut uses, so the two match. Without this the
    window shows pywebview's default mark, which is off-brand.

    macOS takes its icon from the application bundle, not the window, so a
    plain `python panel_app.py` will still show the Python rocket there; that
    needs a packaged .app rather than a runtime call.
    """
    if sys.platform != "win32":
        return
    ico = os.path.join(os.path.dirname(os.path.abspath(__file__)), "panel.ico")
    if not os.path.isfile(ico):
        return
    try:
        import ctypes
        user32 = ctypes.windll.user32
        user32.FindWindowW.restype = ctypes.c_void_p
        user32.LoadImageW.restype = ctypes.c_void_p
        user32.SendMessageW.argtypes = (ctypes.c_void_p, ctypes.c_uint,
                                        ctypes.c_uint, ctypes.c_void_p)
        # the window may not exist for a beat after start(); poll briefly
        hwnd = None
        for _ in range(40):
            hwnd = user32.FindWindowW(None, "Omnicapable Voice")
            if hwnd:
                break
            time.sleep(0.1)
        if not hwnd:
            return
        IMAGE_ICON, LR_LOADFROMFILE = 1, 0x0010
        WM_SETICON, ICON_SMALL, ICON_BIG = 0x0080, 0, 1
        icon_requests = ((16, ICON_SMALL), (24, ICON_SMALL), (32, ICON_BIG), (48, ICON_BIG))
        for size, which in icon_requests:
            h = user32.LoadImageW(None, ico, IMAGE_ICON, size, size, LR_LOADFROMFILE)
            if h:
                user32.SendMessageW(hwnd, WM_SETICON, which, h)
    except Exception:
        pass          # branding is a nicety - never let it stop the app opening


window = webview.create_window(
    "Omnicapable Voice",
    URL,
    width=WIDTH,
    height=HEIGHT,
    min_size=(MIN_WIDTH, MIN_HEIGHT),
    resizable=True,
    on_top=on_top,
    frameless=frameless,
    easy_drag=frameless,
    background_color="#0f1115",
    # Created hidden and shown by _on_start once positioned/branded, so it never
    # flashes at a default spot before settling into the corner.
    hidden=True,
    **_placement()
)

webview.start(_on_start, window)

APPEOF

cat > "$CLAUDE_DIR/open_panel.sh" << 'OPENEOF'
#!/bin/bash
# Opens the Omnicapable Voice control panel.
#   ./open_panel.sh            normal window
#   ./open_panel.sh --pinned   floats above other windows
URL="http://127.0.0.1:59010"
APP="$HOME/.claude/kokoro/panel_app.py"
PINNED=""
[ "${1:-}" = "--pinned" ] && PINNED="--top"
PY="$(command -v python3 || command -v python)"
if [ -n "$PY" ] && "$PY" -c "import webview" >/dev/null 2>&1 && [ -f "$APP" ]; then
    pkill -f "$APP" >/dev/null 2>&1 || true
    nohup "$PY" "$APP" $PINNED >/dev/null 2>&1 &
    exit 0
fi
for A in "Google Chrome" "Microsoft Edge" "Brave Browser" "Chromium"; do
    if [ -d "/Applications/$A.app" ]; then
        open -na "$A" --args --app="$URL" --window-size=380,700
        exit 0
    fi
done
open "$URL"
OPENEOF
chmod +x "$CLAUDE_DIR/open_panel.sh"

# Double-clickable launcher on the Desktop (drag to the Dock to keep it handy)
cat > "$HOME/Desktop/Omnicapable Voice.command" << 'CMDEOF'
#!/bin/bash
exec "$HOME/.claude/open_panel.sh"
CMDEOF
chmod +x "$HOME/Desktop/Omnicapable Voice.command"

# Finder / app-menu Services entry. Users can assign a keyboard shortcut in
# System Settings -> Keyboard -> Keyboard Shortcuts -> Services.
SERVICES_DIR="$HOME/Library/Services/Omnicapable Voice.workflow/Contents"
mkdir -p "$SERVICES_DIR"
cat > "$SERVICES_DIR/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Omnicapable Voice</string>
    <key>CFBundleIdentifier</key>
    <string>com.omnicapable.voice.service</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Omnicapable Voice</string></dict>
            <key>NSMessage</key>
            <string>runWorkflowAsService</string>
            <key>NSSendTypes</key>
            <array/>
        </dict>
    </array>
</dict>
</plist>
PLISTEOF
cat > "$SERVICES_DIR/document.wflow" << 'WFEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key>
    <string>521</string>
    <key>AMApplicationVersion</key>
    <string>2.10</string>
    <key>AMDocumentVersion</key>
    <string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key><string>List</string>
                    <key>Optional</key><true/>
                    <key>Types</key><array><string>com.apple.cocoa.string</string></array>
                </dict>
                <key>AMActionVersion</key><string>2.0.3</string>
                <key>AMApplication</key><array><string>Automator</string></array>
                <key>AMParameterProperties</key>
                <dict>
                    <key>COMMAND_STRING</key><dict/>
                    <key>CheckedForUserDefaultShell</key><dict/>
                    <key>inputMethod</key><dict/>
                    <key>shell</key><dict/>
                    <key>source</key><dict/>
                </dict>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key><string>List</string>
                    <key>Types</key><array><string>com.apple.cocoa.string</string></array>
                </dict>
                <key>ActionBundlePath</key>
                <string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key><string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key><string>"$HOME/.claude/open_panel.sh"</string>
                    <key>CheckedForUserDefaultShell</key><true/>
                    <key>inputMethod</key><integer>0</integer>
                    <key>shell</key><string>/bin/bash</string>
                    <key>source</key><string></string>
                </dict>
                <key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key><string>2.0.3</string>
            </dict>
            <key>isViewVisible</key><integer>1</integer>
        </dict>
    </array>
    <key>connectors</key><dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>serviceApplicationBundleID</key><string>com.apple.finder</string>
        <key>serviceApplicationPath</key><string>/System/Library/CoreServices/Finder.app</string>
        <key>serviceInputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        <key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        <key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
WFEOF
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
# codex_tts_watcher.py v1.6 - Automatic TTS for Claude Code (Codex) rollout JSONL sessions.
# Monitors ~/.codex/sessions and speaks completed assistant messages via Kokoro on port 59001.
# Shares the Kokoro server and TTS toggle with Claude Code TTS / Claude Cowork TTS.
#
# v1.6: Panel status endpoint on 127.0.0.1:59012 (GET /state, POST /replay, POST /mode)
#        so the Omnicapable Voice panel can show a Codex chip, replay this system, and
#        switch between Final Replies and Final + Thinking.
# v1.5: Hook removed ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â watcher-only. The Stop hook added double-speaking of the final
#        reply (watcher + hook both caught the same message). Watcher coverage is complete;
#        the hook provided no additional reliability benefit. Matches Cowork TTS design.
# v1.4: Per-request voice prefix ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â set WATCHER_VOICE = "voice_name".
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
    print("codex_tts_watcher: another instance is already running ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â exiting.")
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
# taken the watcher logs it and carries on ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â status is a convenience, never a
# reason to stop speaking.
STATUS_PORT     = 59012
WATCHER_VERSION = "1.6"
SYSTEM_NAME     = "codex"

_last_spoken = {"text": ""}          # last real utterance, for panel replay
_CONTROL_PREFIXES = ("__STOP__", "__REPLAY__", "__PREVIEW", "__SET_", "__GET_", "__SPEAK__")


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
    log("codex_tts_watcher v1.6 started. Monitoring Claude Code rollout JSONL files.")
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
  echo "      Kokoro server plist already present ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â skipping."
fi

# --- Ctrl+Option+X/R/Space global hotkeys (Carbon RegisterEventHotKey; NO permission prompt) ---
HOTKEY_PLIST_LABEL="com.user.kokoro-tts-hotkey"
HOTKEY_PLIST_PATH="$HOME/Library/LaunchAgents/$HOTKEY_PLIST_LABEL.plist"
cat > "$KOKORO_DIR/tts_hotkey.py" << 'PYEOF'
# -*- coding: utf-8 -*-
"""
Safe global TTS hotkey daemon (macOS).
Registers Ctrl+Option+X (stop), Ctrl+Option+R (replay), and Ctrl+Option+Space
(open panel) via Carbon's RegisterEventHotKey. RegisterEventHotKey is NOT gated
by Accessibility or Input Monitoring, so no extra permission prompt is needed.
"""
import ctypes
import ctypes.util
import os
import socket
import subprocess
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
KEY_SPACE   = 0x31                 # kVK_Space
EVENT_CLASS_KEYBOARD = 0x6B657962  # 'keyb'
EVENT_HOTKEY_PRESSED = 5           # kEventHotKeyPressed
PARAM_DIRECT_OBJECT  = 0x2D2D2D2D  # '----' kEventParamDirectObject
TYPE_HOTKEY_ID       = 0x686B6964  # 'hkid' typeEventHotKeyID
STOP_ID   = 1
REPLAY_ID = 2
PANEL_ID  = 3
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


def open_panel():
    panel = os.path.join(os.path.expanduser("~"), ".claude", "open_panel.sh")
    if not os.path.isfile(panel):
        log(f"Ctrl+Option+Space failed: {panel} not found")
        return
    try:
        subprocess.Popen(["/bin/bash", panel],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("Ctrl+Option+Space opened Omnicapable Voice panel")
    except Exception as exc:
        log(f"Ctrl+Option+Space failed to open panel: {exc}")


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
    if hk.id == PANEL_ID:
        open_panel()
    elif hk.id == REPLAY_ID:
        send_replay()
    else:
        send_stop()
    return 0


# Keep a reference so the trampoline isn't garbage-collected.
_handler_ref = HANDLER(_on_hotkey)


def _load_carbon():
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
        panel_ref = ctypes.c_void_p()
        status_p = carbon.RegisterEventHotKey(KEY_SPACE, CONTROL_KEY | OPTION_KEY,
                                              EventHotKeyID(0x54545353, PANEL_ID), target, 0,
                                              ctypes.byref(panel_ref))
        if status_p != 0:
            log(f"RegisterEventHotKey(open panel) FAILED (status {status_p}); Ctrl+Option+Space may be taken.")
        log("Registered Ctrl+Option+X (stop), Ctrl+Option+R (replay), and Ctrl+Option+Space (open panel) (Carbon, no permission needed).")
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
echo "      Ctrl+Option+X (stop), Ctrl+Option+R (replay), and Ctrl+Option+Space (open panel) hotkeys installed (no permission prompt needed)."

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
echo "      Opening Omnicapable Voice panel..."
if [ -x "$HOME/.claude/open_panel.sh" ]; then
    nohup "$HOME/.claude/open_panel.sh" >/dev/null 2>&1 &
else
    echo "      Panel launcher not found at ~/.claude/open_panel.sh"
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
echo " Open panel:      press Ctrl+Option+Space"
echo " Desktop launcher: ~/Desktop/Omnicapable Voice.command"
echo " Services:        Omnicapable Voice (macOS Services / Quick Actions)"
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


