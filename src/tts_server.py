# -*- coding: utf-8 -*-
"""
tts_server.py v2.3 - Persistent Kokoro TTS server.
Loads the model once, listens on localhost:59001 for text to speak.
Pipelined: synthesizes sentence-by-sentence so first sentence plays immediately.
Supports: stop, replay, speed change, voice change, voice memory, pronunciation
          cleanup, per-request voice prefix (VOICE=name|text), output-device
          follow, auto-restart watchdog.
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
    text = re.sub(r'[\U0001F000-\U0001FFFF\U00002600-\U000027BF\U0000FE00-\U0000FE0F]+', '', text)
    # --- URLs ---
    text = re.sub(r'https?://\S+', 'link', text)
    # --- Abbreviations ---
    text = re.sub(r'\be\.g\.\b', 'for example', text)
    text = re.sub(r'\bi\.e\.\b', 'that is', text)
    text = re.sub(r'\bvs\.\b', 'versus', text)
    text = re.sub(r'\betc\.\b', 'etcetera', text)
    text = re.sub(r'\bapprox\.\b', 'approximately', text)
    # --- Numbers ---
    text = re.sub(r'(?<=\d),(?=\d{3}(?:\D|$))', '', text)
    text = re.sub(r'\$(\d+)(?:\.(\d{2})(?!\d))?', lambda m: (m.group(1)+' dollars and '+m.group(2)+' cents') if m.group(2) else (m.group(1)+' dollars'), text)
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
            try: SPEED = float(text[8:-2].strip())
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
