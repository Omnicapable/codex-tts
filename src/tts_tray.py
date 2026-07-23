# -*- coding: utf-8 -*-
"""
Windows system tray helper for Omnicapable Voice.

Runs quietly in the notification area and gives users a visible place to open
the panel or restart the local TTS server. It is local-only and does not make
any network calls beyond launching the existing localhost panel/server.
"""
import ctypes
import os
import subprocess
import sys
import time

try:
    import pystray
    from PIL import Image, ImageDraw
except Exception as exc:
    log_path = os.path.join(os.path.expanduser("~"), ".claude", "kokoro", "logs", "tts_tray.log")
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Missing tray dependency: {exc}\n")
    except Exception:
        pass
    raise


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(BASE_DIR, "logs", "tts_tray.log")
MUTEX_NAME = "Local\\OmnicapableVoiceTray"
ERROR_ALREADY_EXISTS = 183


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}\n")
    except Exception:
        pass


def hidden_popen(args, cwd=None):
    startupinfo = None
    creationflags = 0
    if os.name == "nt":
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = 0
        creationflags = subprocess.CREATE_NO_WINDOW
    return subprocess.Popen(
        args,
        cwd=cwd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        startupinfo=startupinfo,
        creationflags=creationflags,
    )


def load_icon():
    for name in ("panel.ico", "favicon.ico", "logo.png"):
        path = os.path.join(BASE_DIR, name)
        if os.path.isfile(path):
            try:
                return Image.open(path)
            except Exception as exc:
                log(f"Could not load {name}: {exc}")
    image = Image.new("RGBA", (64, 64), (24, 24, 24, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse((8, 8, 56, 56), fill=(50, 50, 50, 255))
    draw.ellipse((22, 14, 42, 34), fill=(246, 159, 67, 255))
    draw.rectangle((28, 31, 36, 50), fill=(236, 236, 236, 255))
    return image


def open_panel(icon=None, item=None):
    home = os.path.expanduser("~")
    launcher = os.path.join(home, ".claude", "Open-Panel.vbs")
    fallback = os.path.join(home, ".claude", "Open-Panel.bat")
    target = launcher if os.path.isfile(launcher) else fallback
    if not os.path.isfile(target):
        log(f"Open UI failed: launcher not found at {target}")
        return
    try:
        if target.lower().endswith(".vbs"):
            hidden_popen(["wscript.exe", target], cwd=os.path.dirname(target))
        else:
            hidden_popen(["cmd.exe", "/c", "start", "", target], cwd=os.path.dirname(target))
        log("Open UI requested from tray")
    except Exception as exc:
        log(f"Open UI failed: {exc}")


def restart_server(icon=None, item=None):
    script = os.path.join(BASE_DIR, "tts_server.py")
    if not os.path.isfile(script):
        log(f"Restart failed: {script} not found")
        return
    try:
        ps = (
            "Get-CimInstance Win32_Process | "
            "Where-Object { $_.CommandLine -like '*tts_server.py*' } | "
            "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
        )
        hidden_popen(["powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps]).wait(timeout=8)
        hidden_popen(["py", "-3", script], cwd=BASE_DIR)
        log("Restart TTS server requested from tray")
    except Exception as exc:
        log(f"Restart failed: {exc}")


def quit_tray(icon, item=None):
    log("Tray helper quit")
    icon.stop()


def main():
    kernel32 = ctypes.windll.kernel32
    mutex = kernel32.CreateMutexW(None, False, MUTEX_NAME)
    if mutex and kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
        log("Tray helper already running; exiting duplicate")
        return
    menu = pystray.Menu(
        pystray.MenuItem("Open Omnicapable Voice", open_panel, default=True),
        pystray.MenuItem("Restart TTS Server", restart_server),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit Tray Icon", quit_tray),
    )
    icon = pystray.Icon("Omnicapable Voice", load_icon(), "Omnicapable Voice", menu)
    log("Tray helper started")
    try:
        icon.run()
    finally:
        if mutex:
            kernel32.CloseHandle(mutex)


if __name__ == "__main__":
    if os.name != "nt":
        sys.exit(0)
    main()
