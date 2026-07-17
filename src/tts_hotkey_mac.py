# -*- coding: utf-8 -*-
"""
Safe global TTS hotkey daemon (macOS).
Registers Ctrl+Option+X via Carbon's RegisterEventHotKey and sends Kokoro's
shared __STOP__ command to 127.0.0.1:59001. RegisterEventHotKey is NOT gated by
Accessibility or Input Monitoring, so NO permission prompt is ever shown —
unlike a pynput / CGEventTap approach.
"""
import ctypes
import ctypes.util
import os
import socket
import time
import traceback

HOST = "127.0.0.1"
PORT = 59001
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "tts_hotkey.log")

# Carbon modifier masks (these are NOT CGEventFlags values):
CONTROL_KEY = 0x1000
OPTION_KEY  = 0x0800
KEY_X       = 0x07                 # kVK_ANSI_X
KEY_R       = 0x0F                 # kVK_ANSI_R
EVENT_CLASS_KEYBOARD = 0x6B657962  # 'keyb'
EVENT_HOTKEY_PRESSED = 5           # kEventHotKeyPressed
PARAM_DIRECT_OBJECT  = 0x2D2D2D2D  # '----' kEventParamDirectObject
TYPE_HOTKEY_ID       = 0x686B6964  # 'hkid' typeEventHotKeyID
STOP_ID   = 1
REPLAY_ID = 2
kProcessTransformToUIElementApplication = 4


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
    _send(b"__STOP__", "Ctrl+Option+X")


def send_replay():
    _send(b"__REPLAY__", "Ctrl+Option+R")


class EventTypeSpec(ctypes.Structure):
    _fields_ = [("eventClass", ctypes.c_uint32), ("eventKind", ctypes.c_uint32)]


class EventHotKeyID(ctypes.Structure):
    _fields_ = [("signature", ctypes.c_uint32), ("id", ctypes.c_uint32)]


class ProcessSerialNumber(ctypes.Structure):
    _fields_ = [("highLongOfPSN", ctypes.c_uint32), ("lowLongOfPSN", ctypes.c_uint32)]


carbon = None  # set in main()

# OSStatus handler(EventHandlerCallRef, EventRef, void *userData)
HANDLER = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)


def _on_hotkey(_call_ref, event, _user_data):
    hk = EventHotKeyID()
    try:
        carbon.GetEventParameter(event, PARAM_DIRECT_OBJECT, TYPE_HOTKEY_ID, None,
                                 ctypes.sizeof(hk), None, ctypes.byref(hk))
    except Exception:
        pass
    if hk.id == REPLAY_ID:
        send_replay()
    else:
        send_stop()
    return 0


# Keep a reference so the trampoline isn't garbage-collected.
_handler_ref = HANDLER(_on_hotkey)


def _load_carbon():
    # ctypes.util.find_library("Carbon") returns None on macOS 11+ because system
    # frameworks live in the dyld shared cache, not on disk. Load by absolute
    # path first; dyld still resolves it from the cache.
    for path in ("/System/Library/Frameworks/Carbon.framework/Carbon",
                 "/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon",
                 ctypes.util.find_library("Carbon")):
        if not path:
            continue
        try:
            return ctypes.CDLL(path)
        except OSError:
            continue
    return None


def main():
    global carbon
    carbon = _load_carbon()
    if carbon is None:
        log("ERROR: could not load the Carbon framework; hotkey disabled.")
        return
    try:
        carbon.GetApplicationEventTarget.restype = ctypes.c_void_p
        carbon.GetApplicationEventTarget.argtypes = []
        carbon.GetEventParameter.restype = ctypes.c_int32
        carbon.GetEventParameter.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                             ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p]
        carbon.InstallEventHandler.restype = ctypes.c_int32
        carbon.InstallEventHandler.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong,
                                               ctypes.POINTER(EventTypeSpec), ctypes.c_void_p, ctypes.c_void_p]
        carbon.RegisterEventHotKey.restype = ctypes.c_int32
        carbon.RegisterEventHotKey.argtypes = [ctypes.c_uint32, ctypes.c_uint32, EventHotKeyID,
                                               ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
        carbon.RunApplicationEventLoop.restype = None
        carbon.RunApplicationEventLoop.argtypes = []

        # Give the faceless launchd process a WindowServer connection so it can
        # receive the hotkey, without showing a Dock icon.
        try:
            psn = ProcessSerialNumber(0, 2)  # {0, kCurrentProcess}
            carbon.TransformProcessType(ctypes.byref(psn),
                                        kProcessTransformToUIElementApplication)
        except Exception as exc:
            log(f"TransformProcessType skipped: {exc}")

        target = carbon.GetApplicationEventTarget()
        spec = EventTypeSpec(EVENT_CLASS_KEYBOARD, EVENT_HOTKEY_PRESSED)
        carbon.InstallEventHandler(target, _handler_ref, 1, ctypes.byref(spec), None, None)

        stop_ref = ctypes.c_void_p()
        status = carbon.RegisterEventHotKey(KEY_X, CONTROL_KEY | OPTION_KEY,
                                            EventHotKeyID(0x54545353, STOP_ID), target, 0,
                                            ctypes.byref(stop_ref))
        if status != 0:
            log(f"RegisterEventHotKey(stop) FAILED (status {status}); Ctrl+Option+X may be taken.")
            return
        replay_ref = ctypes.c_void_p()
        status_r = carbon.RegisterEventHotKey(KEY_R, CONTROL_KEY | OPTION_KEY,
                                              EventHotKeyID(0x54545353, REPLAY_ID), target, 0,
                                              ctypes.byref(replay_ref))
        if status_r != 0:
            log(f"RegisterEventHotKey(replay) FAILED (status {status_r}); Ctrl+Option+R may be taken.")
        log("Registered Ctrl+Option+X (stop) and Ctrl+Option+R (replay) (Carbon, no permission needed).")
        carbon.RunApplicationEventLoop()
    except Exception as exc:
        log("ERROR in hotkey daemon: " + repr(exc))
        log(traceback.format_exc())


if __name__ == "__main__":
    main()
