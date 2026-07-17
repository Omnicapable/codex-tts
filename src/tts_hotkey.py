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
