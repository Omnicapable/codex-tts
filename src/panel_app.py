# -*- coding: utf-8 -*-
"""
panel_app.py - opens the Omnicapable Voice panel as a real desktop mini-app
window instead of a browser tab.

Uses pywebview, which wraps the system web engine (WebView2 on Windows, WebKit
on macOS) in a native window: no tabs, no address bar, no browser UI at all.

    pip install pywebview
    pythonw panel_app.py          # normal window
    pythonw panel_app.py --top    # floats above other windows ("pinned")

Flags:
    --top           keep the window floating above all other windows
    --frameless     hide the title bar entirely (drag the panel body to move)

Sizing and placement are decided BEFORE the window is created, then confirmed
on the native window handle while the window is still hidden. That is deliberate:
the old build opened at a default spot and then corrected itself once the page
had loaded, which read as a visible jump. A fixed window that never twitches
looks far more finished.

WIDTH/HEIGHT are the native outer window size. The width preserves the 336px
body, while the height is trimmed to remove empty footer slack below TTS v3.4.
"""
import os
import sys
import time

import webview

if sys.platform == "win32":
    try:
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Omnicapable.Voice.Panel")
    except Exception:
        pass

URL = "http://127.0.0.1:59010"

# NOTE: pywebview's width/height are the OUTER window, not the web viewport.
# The native frame costs about 16x38 around the page; the 736px viewport target
# keeps the footer visible while cutting the old empty space below TTS v3.4.
FRAME_W, FRAME_H = 16, 38
WIDTH, HEIGHT = 336 + FRAME_W, 736 + FRAME_H
MIN_WIDTH     = 300          # panel.html starts to overflow below this
MIN_HEIGHT    = 520
CORNER_MARGIN = 14           # small buffer from the bottom-right corner so the
                             # window sits in the corner without touching the
                             # very edge and never spills off-screen

on_top    = "--top" in sys.argv
frameless = "--frameless" in sys.argv


def _work_area():
    """(left, top, width, height) of the usable desktop, excluding the Windows
    taskbar / macOS menu bar and Dock. Returns None if it cannot be determined,
    in which case pywebview centres the window as before."""
    # Windows: SPI_GETWORKAREA is the only call that accounts for the taskbar.
    if sys.platform == "win32":
        # Deliberately do NOT call SetProcessDpiAwareness here. Doing so flips the
        # process into physical pixels (e.g. 2560x1528 instead of 1707x1019 on a
        # 150% display), and pywebview's width/height/x/y are logical pixels - the
        # window would come out about two thirds of its intended size.
        try:
            import ctypes
            from ctypes import wintypes
            r = wintypes.RECT()
            if ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(r), 0):
                return r.left, r.top, r.right - r.left, r.bottom - r.top
        except Exception:
            pass
    # macOS: visibleFrame already excludes the menu bar and Dock. Cocoa's origin
    # is bottom-left, so flip it into the top-left coordinates pywebview wants.
    elif sys.platform == "darwin":
        try:
            from AppKit import NSScreen
            scr = NSScreen.mainScreen()
            vf, full = scr.visibleFrame(), scr.frame()
            top = full.size.height - (vf.origin.y + vf.size.height)
            return int(vf.origin.x), int(top), int(vf.size.width), int(vf.size.height)
        except Exception:
            pass
    # Anything else: pywebview's own screen list.
    try:
        s = webview.screens[0]
        return 0, 0, int(s.width), int(s.height)
    except Exception:
        return None


def _placement():
    """Dock to the BOTTOM-right corner of the work area, with a small buffer, and
    clamp so no edge ever leaves the screen (if the window is taller than the work
    area it pins to the top-left rather than hanging off)."""
    area = _work_area()
    if not area:
        return {}
    left, top, width, height = area
    x = left + width - WIDTH - CORNER_MARGIN
    y = top + height - HEIGHT - CORNER_MARGIN
    return {"x": max(left, x), "y": max(top, y)}

def _find_window_handle(timeout=1.0):
    """Return this process's native Windows panel handle, if it exists."""
    if sys.platform != "win32":
        return None
    try:
        import ctypes
        from ctypes import wintypes
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        user32.FindWindowW.restype = ctypes.c_void_p
        user32.EnumWindows.argtypes = (ctypes.c_void_p, ctypes.c_void_p)
        user32.GetWindowThreadProcessId.argtypes = (ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD))
        user32.GetParent.argtypes = (ctypes.c_void_p,)
        user32.GetParent.restype = ctypes.c_void_p
        current_pid = kernel32.GetCurrentProcessId()

        def locate():
            hwnd = user32.FindWindowW(None, "Omnicapable Voice")
            if hwnd:
                return hwnd
            found = []

            @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
            def enum_proc(candidate, _lparam):
                pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(candidate, ctypes.byref(pid))
                if pid.value == current_pid and not user32.GetParent(candidate):
                    found.append(candidate)
                    return False
                return True

            user32.EnumWindows(enum_proc, None)
            return found[0] if found else None

        deadline = time.time() + timeout
        while time.time() <= deadline:
            hwnd = locate()
            if hwnd:
                return hwnd
            time.sleep(0.025)
    except Exception:
        return None
    return None
def _force_position(win=None):
    """Dock to the actual monitor work area without mixing coordinate systems.

    pywebview still owns the logical size, but Windows multi-monitor/DPI setups
    can report a different physical rectangle for the native handle. So the
    final Windows pass measures the real window rectangle and docks that same
    rectangle inside its nearest monitor's work area. That keeps the panel
    visible even on scaled or offset displays.
    """
    place = _placement()
    try:
        if win is not None:
            try:
                win.resize(WIDTH, HEIGHT)
            except Exception:
                pass
            if place:
                try:
                    win.move(int(place["x"]), int(place["y"]))
                except Exception:
                    pass
    except Exception:
        pass
    if sys.platform != "win32":
        return
    try:
        import ctypes
        from ctypes import wintypes
        hwnd = _find_window_handle(timeout=1.0)
        if not hwnd:
            return

        user32 = ctypes.windll.user32

        class RECT(ctypes.Structure):
            _fields_ = [
                ("left", ctypes.c_long),
                ("top", ctypes.c_long),
                ("right", ctypes.c_long),
                ("bottom", ctypes.c_long),
            ]

        class MONITORINFO(ctypes.Structure):
            _fields_ = [
                ("cbSize", ctypes.c_ulong),
                ("rcMonitor", RECT),
                ("rcWork", RECT),
                ("dwFlags", ctypes.c_ulong),
            ]

        user32.GetWindowRect.argtypes = (ctypes.c_void_p, ctypes.POINTER(RECT))
        user32.MonitorFromWindow.argtypes = (ctypes.c_void_p, ctypes.c_uint)
        user32.MonitorFromWindow.restype = ctypes.c_void_p
        user32.GetMonitorInfoW.argtypes = (ctypes.c_void_p, ctypes.POINTER(MONITORINFO))
        user32.SetWindowPos.argtypes = (
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, ctypes.c_int, ctypes.c_uint
        )

        rect = RECT()
        if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            return
        mon = user32.MonitorFromWindow(hwnd, 0x00000002)  # MONITOR_DEFAULTTONEAREST
        if not mon:
            return
        info = MONITORINFO()
        info.cbSize = ctypes.sizeof(MONITORINFO)
        if not user32.GetMonitorInfoW(mon, ctypes.byref(info)):
            return

        actual_w = max(1, rect.right - rect.left)
        actual_h = max(1, rect.bottom - rect.top)
        margin = CORNER_MARGIN
        x = info.rcWork.right - actual_w - margin
        y = info.rcWork.bottom - actual_h - margin
        x = max(info.rcWork.left + margin, x)
        y = max(info.rcWork.top + margin, y)

        SWP_NOSIZE = 0x0001
        SWP_NOZORDER = 0x0004
        SWP_NOACTIVATE = 0x0010
        user32.SetWindowPos(
            hwnd, None, int(x), int(y),
            0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        )
    except Exception:
        pass

def _on_start(win):
    """Runs once the GUI loop is up. Dock and brand the window while it is still
    hidden, then show it so it appears already at its final size, position and
    icon, with none of the open-then-jump the old build had."""
    _force_position(win)
    _apply_icon()
    try:
        win.show()
    except Exception:
        pass
    _force_position(win)
    _apply_icon()
def _apply_icon(_window=None):
    """Put the Omnicapable mark on the window and its taskbar button.

    pywebview has no cross-platform icon option for the Windows backend, so the
    icon is pushed onto the native window handle with WM_SETICON - the same
    panel.ico the desktop shortcut uses, so the two match. Without this the
    window shows pywebview's default mark, which is off-brand.

    macOS takes its icon from the application bundle, not the window, so a
    plain `python panel_app.py` will still show the Python rocket there; that
    needs a packaged .app rather than a runtime call.
    """
    if sys.platform != "win32":
        return
    ico = os.path.join(os.path.dirname(os.path.abspath(__file__)), "panel.ico")
    if not os.path.isfile(ico):
        return
    try:
        import ctypes
        user32 = ctypes.windll.user32
        user32.FindWindowW.restype = ctypes.c_void_p
        user32.LoadImageW.restype = ctypes.c_void_p
        user32.SendMessageW.argtypes = (ctypes.c_void_p, ctypes.c_uint,
                                        ctypes.c_uint, ctypes.c_void_p)
        # the window may not exist for a beat after start(); poll briefly
        hwnd = None
        for _ in range(40):
            hwnd = user32.FindWindowW(None, "Omnicapable Voice")
            if hwnd:
                break
            time.sleep(0.1)
        if not hwnd:
            return
        IMAGE_ICON, LR_LOADFROMFILE = 1, 0x0010
        WM_SETICON, ICON_SMALL, ICON_BIG = 0x0080, 0, 1
        icon_requests = ((16, ICON_SMALL), (24, ICON_SMALL), (32, ICON_BIG), (48, ICON_BIG))
        for size, which in icon_requests:
            h = user32.LoadImageW(None, ico, IMAGE_ICON, size, size, LR_LOADFROMFILE)
            if h:
                user32.SendMessageW(hwnd, WM_SETICON, which, h)
    except Exception:
        pass          # branding is a nicety - never let it stop the app opening


window = webview.create_window(
    "Omnicapable Voice",
    URL,
    width=WIDTH,
    height=HEIGHT,
    min_size=(MIN_WIDTH, MIN_HEIGHT),
    resizable=True,
    on_top=on_top,
    frameless=frameless,
    easy_drag=frameless,
    background_color="#0f1115",
    # Created hidden and shown by _on_start once positioned/branded, so it never
    # flashes at a default spot before settling into the corner.
    hidden=True,
    **_placement()
)

webview.start(_on_start, window)
