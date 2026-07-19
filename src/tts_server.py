# -*- coding: utf-8 -*-
"""
tts_server.py v2.6 - Persistent Kokoro TTS server.
Loads the model once, listens on localhost:59001 for text to speak.
Pipelined: synthesizes sentence-by-sentence so first sentence plays immediately.
Supports: stop, replay, speed change, voice change, voice & speed memory,
          pronunciation cleanup, per-request voice prefix (VOICE=name|text),
          output-device follow, auto-restart watchdog.
v2.6: Above-normal process priority - raised at startup (Windows:
      SetPriorityClass ABOVE_NORMAL; Mac/Linux: best-effort os.nice) so
      chunk synthesis keeps outpacing playback while the CPU is busy.
      Fixes audible gaps between sentences under load.
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

# v2.6: Raise our process priority so chunk synthesis keeps outpacing playback
# while the CPU is busy (agent streaming, browser). Best-effort: on Mac/Linux
# os.nice needs privileges and silently stays at normal priority without them.
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
