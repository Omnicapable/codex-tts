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
    text = re.sub(r'[→←↑↓⇒⇐]', '', text)
    text = (text.replace('‒', ',').replace('–', ',').replace('—', ',')
                .replace('―', ',').replace('−', ','))
    text = re.sub(r'[|\\]', '', text)
    text = re.sub(r'[•·●◦]', '', text)
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

    That pack has no watcher process — it speaks through a Stop hook — so the
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
