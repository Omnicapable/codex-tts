# Development Log

## 2026-07-20

**What v3.2 adds that v2.6 simply doesn't have:**

**The control panel itself** - an HTTP API on 59010 plus the window. v2.6 had no UI at all; every setting required editing files or running scripts.
**Volume control.** v2.6 has *no* concept of TTS volume - your only option was the system mixer, which affects everything. This is per-TTS gain.
**Live state** - whether it's speaking right now, and which voice is currently auditioning. v2.6 was a black box; nothing could ask it what it was doing.
**Voice auditioning** - preview one, preview all, with each new preview interrupting the last. v2.6 could only preview via a separate helper script.
**Speak arbitrary text / clipboard** on demand.
**Global mute** from the server side.
**Mock mode** - the server runs with no audio hardware or Kokoro model, which is how I've been able to test every endpoint without touching your machine. That's a maintenance win for all future work.
