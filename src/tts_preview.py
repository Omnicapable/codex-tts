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
    set_voice(name)
    time.sleep(0.2)
    send(f"{label}. {SAMPLE}")
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