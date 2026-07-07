# -*- coding: utf-8 -*-
"""
tts_server.py v2.1 - Persistent Kokoro TTS server.
Loads the model once, listens on localhost:59001 for text to speak.
Pipelined: synthesizes sentence-by-sentence so first sentence plays immediately.
Supports: stop, speed change, voice change, per-request voice prefix, auto-restart.

v2.1: Per-request voice prefix — send "VOICE=af_sky|your text" to use a specific
      voice for that request only, without changing the global default. Used by
      watchers that set WATCHER_VOICE to give each TTS setup its own distinct voice.
v2.0: Initial pipelined release with sentence splitting and speed/voice controls.
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

        if text:
            # Per-request voice prefix: "VOICE=af_sky|actual text"
            req_voice = None
            if text.startswith("VOICE=") and "|" in text:
                prefix, text = text.split("|", 1)
                req_voice = prefix[6:].strip()
            if text:
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
