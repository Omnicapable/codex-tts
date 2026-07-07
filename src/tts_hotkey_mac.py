# -*- coding: utf-8 -*-
"""
Safe global TTS hotkey daemon (macOS).
Registers Ctrl+Option+X via pynput and sends Kokoro's shared __STOP__ command to
127.0.0.1:59001. Requires Accessibility permission for the launching process
(System Settings > Privacy & Security > Accessibility). Without it the hotkey
silently does nothing — a macOS security requirement, not a bug.
"""
import os
import socket
import time

HOST = "127.0.0.1"
PORT = 59001
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "tts_hotkey.log")


def log(message):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def send_stop():
    try:
        with socket.create_connection((HOST, PORT), timeout=1.0) as sock:
            sock.sendall(b"__STOP__")
        log("Ctrl+Option+X sent __STOP__")
    except Exception as exc:
        log(f"Ctrl+Option+X failed to send __STOP__: {exc}")


def main():
    try:
        from pynput import keyboard
    except Exception as exc:
        log(f"pynput unavailable, hotkey disabled: {exc}")
        return
    log("Hotkey daemon starting (Ctrl+Option+X). Needs Accessibility permission.")
    with keyboard.GlobalHotKeys({"<ctrl>+<alt>+x": send_stop}) as h:
        h.join()


if __name__ == "__main__":
    main()
