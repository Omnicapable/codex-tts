# =============================================================================
# install_codex_tts_Windows.ps1  v1.4
# One-shot installer for Codex TTS — watcher-only build using Kokoro ONNX.
# Monitors ~/.codex/sessions rollout files and speaks responses aloud.
# Fully offline after install. No API keys required.
#
# Requirements: Windows 10/11, Python 3.9+, Codex writing rollout files under ~/.codex/sessions
# Usage: Right-click -> Run with PowerShell  (no admin needed)
# =============================================================================

$ErrorActionPreference = "Stop"
$claude   = "$env:USERPROFILE\.claude"
$kokoro   = "$claude\kokoro"
$codex    = "$env:USERPROFILE\.codex"
$ttsDir   = "$codex\tts"
$port     = 59001
$version  = "1.4"

Write-Host ""
Write-Host "============================================"
Write-Host " Codex TTS (Watcher) v$version"
Write-Host "============================================"
Write-Host ""

# --- 1. Check Python --------------------------------------------------------
Write-Host "[1/8] Checking Python..."
try {
    $pyver = py -3 --version 2>&1
    Write-Host "      Found: $pyver"
} catch {
    Write-Host "ERROR: Python 3 / 'py' launcher not found. Install Python 3.9+ from https://python.org (the python.org installer includes the 'py' launcher), then re-run."
    exit 1
}

# --- 2. Install Python packages ---------------------------------------------
Write-Host "[2/8] Installing Python packages..."
py -3 -m pip install kokoro-onnx sounddevice numpy --quiet
Write-Host "      Done."

# --- 3. Create folders ------------------------------------------------------
Write-Host "[3/8] Creating folders..."
New-Item -ItemType Directory -Force -Path $kokoro  | Out-Null
New-Item -ItemType Directory -Force -Path $ttsDir  | Out-Null
Write-Host "      Done."

# --- 4. Download model files ------------------------------------------------
Write-Host "[4/8] Downloading Kokoro model files (approx 336 MB)..."
$baseUrl = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
$files = @{
    "kokoro-v1.0.onnx" = "$baseUrl/kokoro-v1.0.onnx"
    "voices-v1.0.bin"  = "$baseUrl/voices-v1.0.bin"
}
foreach ($name in $files.Keys) {
    $dest = "$kokoro\$name"
    if (Test-Path $dest) {
        Write-Host "      Already exists: $name"
    } else {
        Write-Host "      Downloading $name..."
        Invoke-WebRequest -Uri $files[$name] -OutFile $dest -UseBasicParsing
        Write-Host "      Done: $name"
    }
}

# --- 5. Write tts_server.py -------------------------------------------------
Write-Host "[5/8] Writing TTS server..."
Set-Content -Path "$kokoro\tts_server.py" -Encoding UTF8 -Value @'
# -*- coding: utf-8 -*-
"""
tts_server.py v2.5 - Persistent Kokoro TTS server.
Loads the model once, listens on localhost:59001 for text to speak.
Pipelined: synthesizes sentence-by-sentence so first sentence plays immediately.
Supports: stop, replay, speed change, voice change, voice & speed memory,
          pronunciation cleanup, per-request voice prefix (VOICE=name|text),
          output-device follow, auto-restart watchdog.
v2.5: Speed memory - the chosen speed is saved to speed.txt beside the
      server (mirroring voice memory) and reloaded on start.
      Speech polish - abbreviations (e.g., i.e., vs., etc., approx.) now
      actually expand (their old patterns ended in a word boundary that cannot
      match before a space, so they never fired). Money handles one-decimal
      amounts ($3.5), sub-dollar amounts ($0.99 reads "99 cents") and scale
      words ($1.5 million reads "1 point 5 million dollars"). Emoji stripping
      covers the stars/arrows/symbols blocks (U+2190-21FF, U+2B00-2BFF).
v2.4: Gapless playback - long sentences now split at clause breaks into
      chunks of at most ~120 chars (min ~40), so synthesis (about 4x realtime
      on CPU) always finishes the next chunk before the current one ends.
      Short opening chunks keep time-to-first-audio low. Chunking only; the
      audio path, queue, stop/replay semantics are untouched.
v2.3: Cents fix - the ' point ' rule now runs AFTER the money rule, so "$3.50"
      reads "3 dollars and 50 cents" again rather than "3 dollars point 50".
      Header corrected to match shipped behaviour. Consolidates the replay
      lineage (__REPLAY__, output-device follow, emoji strip, money/decimal
      parsing) with the voice-memory + pronunciation work. Single source of truth.
v2.2: Voice memory (saves chosen voice to voice.txt; reloads on restart).
      Pronunciation: version numbers read as "point", bare domains as "dot".
v2.1: Per-request voice prefix -- VOICE=name|text overrides global voice for
      that request only. Zero race conditions; global voice unchanged.
v2.0: Initial pipelined release with sentence splitting and speed/voice controls.
"""
import socket, threading, queue, os, re, time
import numpy as np
import sounddevice as sd

HOST, PORT = "127.0.0.1", 59001
VOICE, SPEED, LANG, MAX_CHARS = "am_onyx", 1.2, "en-us", 5000
CHUNK_MAX, CHUNK_MIN = 120, 40
VOICE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice.txt")
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
VOICE = _load_voice()
SPEED_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "speed.txt")
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
SPEED = _load_speed()

base = os.path.dirname(os.path.abspath(__file__))
from kokoro_onnx import Kokoro
kokoro = Kokoro(os.path.join(base, "kokoro-v1.0.onnx"), os.path.join(base, "voices-v1.0.bin"))

# Pre-warm audio device so first sentence has no driver init delay
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

def _money(m):
    d, c = m.group(1), m.group(2)
    if c is None:
        return d + ' dollars'
    if len(c) > 2:
        return d + ' point ' + c + ' dollars'
    cents = c + '0' if len(c) == 1 else c
    return (cents + ' cents') if d == '0' else (d + ' dollars and ' + cents + ' cents')

def clean_text(text):
    # --- Tables --- replace markdown tables with a brief label
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
    text = re.sub(r'[→←↑↓⇒⇐]', '', text)
    text = text.replace('\u2012', ',').replace('\u2013', ',').replace('\u2014', ',').replace('\u2015', ',').replace('\u2212', ',')
    text = re.sub(r'[|\\]', '', text)
    text = re.sub(r'[•·●◦]', '', text)
    # --- Emojis ---
    text = re.sub(r'[\U0001F000-\U0001FFFF\U00002600-\U000027BF\U00002B00-\U00002BFF\U00002190-\U000021FF\U0000FE00-\U0000FE0F]+', '', text)
    # --- URLs ---
    text = re.sub(r'https?://\S+', 'link', text)
    # --- Abbreviations ---
    text = re.sub(r'\be\.g\.', 'for example', text)
    text = re.sub(r'\bi\.e\.', 'that is', text)
    text = re.sub(r'\bvs\.', 'versus', text)
    text = re.sub(r'\betc\.', 'etcetera', text)
    text = re.sub(r'\bapprox\.', 'approximately', text)
    # --- Numbers ---
    text = re.sub(r'(?<=\d),(?=\d{3}(?:\D|$))', '', text)
    text = re.sub(r'\$(\d+(?:\.\d+)?)\s*(million|billion|trillion|thousand)\b', r'\1 \2 dollars', text, flags=re.IGNORECASE)
    text = re.sub(r'\$(\d+(?:\.\d+)?)([kKmMbB])\b', lambda m: m.group(1) + ' ' + {'k': 'thousand', 'm': 'million', 'b': 'billion'}[m.group(2).lower()] + ' dollars', text)
    text = re.sub(r'\$(\d+)(?:\.(\d+))?', _money, text)
    text = re.sub(r'(\d)%', r'\1 percent', text)
    text = re.sub(r'(\d+)x\b', r'\1 times', text)
    # --- Versions & bare domains ---
    # Must stay BELOW the money rule: this ' point ' substitution would otherwise
    # consume the decimal in "$3.50" and produce "3 dollars point 50".
    text = re.sub(r'(?<=\d)\.(?=\d)', ' point ', text)
    _TLDS = r'com|net|org|edu|gov|io|ai|app|dev|co|us|uk|ca|xyz|info|biz|me|tv|gg|so|sh'
    text = re.sub(r'(?<=[A-Za-z0-9])\.(?=(?:' + _TLDS + r')\b)', ' dot ', text, flags=re.IGNORECASE)
    # --- Whitespace cleanup ---
    text = re.sub(r'\s{2,}', ' ', text)
    return text.strip()

def split_sentences(text):
    # Chunk sizing is what keeps playback gapless: a chunk of at most CHUNK_MAX
    # chars synthesizes faster than the CHUNK_MIN chars of audio before it play,
    # so the producer always stays ahead. Long sentences break at clause
    # punctuation; fragments below CHUNK_MIN merge with a neighbour.
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
            sd.stop()
            break

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
            try: SPEED = float(text[8:-2].strip()); _save_speed(SPEED)
            except ValueError: pass
            return

        if text == "__GETSPEED__":
            try: conn.sendall(str(SPEED).encode("utf-8")); conn.shutdown(socket.SHUT_WR)
            except Exception: pass
            return

        if text.startswith("__VOICE:") and text.endswith("__"):
            global VOICE
            VOICE = text[8:-2].strip(); _save_voice(VOICE); return

        if text == "__GETVOICE__":
            try: conn.sendall(VOICE.encode("utf-8")); conn.shutdown(socket.SHUT_WR)
            except Exception: pass
            return

        if text == "__REPLAY__":
            if _last_text:
                with _speak_lock: speak(_last_text, voice_override=_last_voice)
            return
        if text:
            # Per-request voice prefix: "VOICE=af_sky|actual text"
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

# Auto-restart watchdog
while True:
    try: run_server()
    except Exception: time.sleep(3)
'@
Write-Host "      Done."

# tts_preview.py - friendly preview phrase router
Set-Content -Path "$kokoro\tts_preview.py" -Encoding UTF8 -Value @'
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
'@
# --- 6. Write codex_tts_watcher.py ------------------------------------------
Write-Host "[6/8] Writing Codex TTS watcher..."
Set-Content -Path "$ttsDir\codex_tts_watcher.py" -Encoding UTF8 -Value @'
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
'@
Write-Host "      Done."

# --- 7. Set up auto-start and watchdog --------------------------------------
Write-Host "[7/8] Setting up auto-start..."

$startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
Set-Content -Path "$startupFolder\kokoro_tts_server.vbs" -Value @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "py -3 $kokoro\tts_server.py", 0, False
"@
Set-Content -Path "$startupFolder\codex_tts_watcher.vbs" -Value @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "py -3 $ttsDir\codex_tts_watcher.py", 0, False
"@

# --- Ctrl+Alt+X global stop hotkey: safe RegisterHotKey daemon (no low-level keyboard hook) ---
# Shared, single-instance (mutex). Installs alongside the shared Kokoro server so Codex users
# get a working stop hotkey even if they never install the Cowork/Claude Code products.
Set-Content -Path "$kokoro\tts_hotkey.py" -Encoding UTF8 -Value @'
# -*- coding: utf-8 -*-
"""
Safe global TTS hotkey daemon (Windows).
Registers Ctrl+Alt+X (RegisterHotKey) and sends Kokoro's shared __STOP__ command
to 127.0.0.1:59001. Uses RegisterHotKey, NOT a low-level keyboard hook, so normal
typing is never intercepted. A named mutex enforces a single instance, so installing
more than one TTS product (each launches this daemon) is harmless.
"""
import ctypes
import ctypes.wintypes
import os
import socket
import time

HOST = "127.0.0.1"
PORT = 59001
HOTKEY_ID = 0x545453          # stop   (Ctrl+Alt+X)
HOTKEY_ID_REPLAY = 0x545454   # replay (Ctrl+Alt+R)
MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
VK_X = 0x58
VK_R = 0x52
WM_HOTKEY = 0x0312
ERROR_ALREADY_EXISTS = 183

LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "tts_hotkey.log")


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
    _send(b"__STOP__", "Ctrl+Alt+X")


def send_replay():
    _send(b"__REPLAY__", "Ctrl+Alt+R")


def main():
    kernel32 = ctypes.windll.kernel32
    user32 = ctypes.windll.user32
    mutex = kernel32.CreateMutexW(None, False, "Local\\KokoroTtsCtrlAltXHotkey")
    if mutex and kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
        log("Hotkey daemon already running; exiting duplicate.")
        return
    if not user32.RegisterHotKey(None, HOTKEY_ID, MOD_CONTROL | MOD_ALT, VK_X):
        log("RegisterHotKey failed. Ctrl+Alt+X may already be registered by another app.")
        return
    if not user32.RegisterHotKey(None, HOTKEY_ID_REPLAY, MOD_CONTROL | MOD_ALT, VK_R):
        log("RegisterHotKey(replay) failed. Ctrl+Alt+R may already be registered by another app.")
    log("Registered Ctrl+Alt+X (stop) and Ctrl+Alt+R (replay) hotkeys.")
    msg = ctypes.wintypes.MSG()
    try:
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == WM_HOTKEY:
                if msg.wParam == HOTKEY_ID_REPLAY:
                    send_replay()
                elif msg.wParam == HOTKEY_ID:
                    send_stop()
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
    finally:
        user32.UnregisterHotKey(None, HOTKEY_ID)
        user32.UnregisterHotKey(None, HOTKEY_ID_REPLAY)
        if mutex:
            kernel32.CloseHandle(mutex)
        log("Hotkey daemon stopped.")


if __name__ == "__main__":
    main()
'@
Set-Content -Path "$startupFolder\kokoro_tts_hotkey.vbs" -Value @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "py -3 $kokoro\tts_hotkey.py", 0, False
"@
Start-Process py -ArgumentList "-3", "$kokoro\tts_hotkey.py" -WindowStyle Hidden

$watchdogScript = "$ttsDir\watchdog.ps1"
Set-Content -Path $watchdogScript -Encoding UTF8 -Value @"
# watchdog.ps1 — Restarts Kokoro TTS server and Codex watcher if not running.
`$log = "$ttsDir\codex_tts_watcher_log.txt"
function Log(`$m) { Add-Content `$log -Value ("[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] WATCHDOG: " + `$m) }

`$server  = Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -like "*tts_server*" }
`$watcher = Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -like "*codex_tts_watcher*" }

if (-not `$server)  { Start-Process py -ArgumentList "-3", "$kokoro\tts_server.py" -WindowStyle Hidden; Log "Restarted Kokoro server" }
if (-not `$watcher) { Start-Process py -ArgumentList "-3", "$ttsDir\codex_tts_watcher.py" -WindowStyle Hidden; Log "Restarted Codex watcher" }
"@

try {
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogScript`""
    $trigger1 = New-ScheduledTaskTrigger -AtLogOn
    $trigger2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskName "Codex TTS Watchdog" -Action $action -Trigger @($trigger1, $trigger2) -Settings $settings -Description "Keeps the Kokoro TTS server and Codex watcher running." -Force -ErrorAction Stop | Out-Null
    Write-Host "      Watchdog scheduled task installed."
} catch {
    Write-Host "      Could not install scheduled task: $($_.Exception.Message)"
    Write-Host "      Auto-start VBS shortcuts installed in Startup folder instead."
}

# Enable TTS toggle
"on" | Set-Content "$claude\tts_enabled.txt"
Write-Host "      Done."

# --- 8. Launch server and watcher -------------------------------------------
Write-Host "[8/8] Launching TTS server and watcher..."
Start-Process py -ArgumentList "-3", "$kokoro\tts_server.py" -WindowStyle Hidden
Write-Host "      Waiting for server to load model (~10 seconds)..."
Start-Sleep 10
Start-Process py -ArgumentList "-3", "$ttsDir\codex_tts_watcher.py" -WindowStyle Hidden
Start-Sleep 2

$serverRunning = $false
try {
    $t = New-Object System.Net.Sockets.TcpClient; $t.Connect("127.0.0.1", $port); $t.Close(); $serverRunning = $true
} catch { }

if ($serverRunning) {
    Write-Host "      TTS server running."
} else {
    Write-Host "      WARNING: Server did not respond. Try running 'py -3 $kokoro\tts_server.py' manually."
}

Write-Host ""
Write-Host "============================================"
Write-Host " Setup complete!"
Write-Host "============================================"
Write-Host ""
Write-Host " Voice:  am_onyx (default)  |  Speed: 1.2x"
Write-Host " Stop:   Ctrl+Alt+X"
Write-Host " Replay: Ctrl+Alt+R"
Write-Host " Preview: say 'quick voices' or 'preview all voices'"
Write-Host ""
Write-Host " Toggle TTS on/off:"
Write-Host "   echo on > `"$claude\tts_enabled.txt`""
Write-Host "   echo off > `"$claude\tts_enabled.txt`""
Write-Host ""
Write-Host " Log file: $ttsDir\codex_tts_watcher_log.txt"
Write-Host " Uninstall: delete $ttsDir and remove the 'Codex TTS Watchdog' scheduled task."
Write-Host ""


