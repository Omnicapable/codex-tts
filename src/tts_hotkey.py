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
HOTKEY_ID = 0x545453
MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
VK_X = 0x58
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


def send_stop():
    try:
        with socket.create_connection((HOST, PORT), timeout=1.0) as sock:
            sock.sendall(b"__STOP__")
        log("Ctrl+Alt+X sent __STOP__")
    except Exception as exc:
        log(f"Ctrl+Alt+X failed to send __STOP__: {exc}")


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
    log("Registered Ctrl+Alt+X hotkey.")
    msg = ctypes.wintypes.MSG()
    try:
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == WM_HOTKEY and msg.wParam == HOTKEY_ID:
                send_stop()
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
    finally:
        user32.UnregisterHotKey(None, HOTKEY_ID)
        if mutex:
            kernel32.CloseHandle(mutex)
        log("Hotkey daemon stopped.")


if __name__ == "__main__":
    main()
