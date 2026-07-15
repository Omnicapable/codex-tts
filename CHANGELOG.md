# Changelog — Codex TTS

## Packaging — 2026-07-14
- **Mac stop hotkey needs no permission now.** The macOS stop hotkey (Ctrl+Option+X) was rewritten from `pynput` to Carbon `RegisterEventHotKey`, which is not gated by Accessibility / Input Monitoring, so there is no first-use permission prompt. `pynput` was dropped from the Mac dependencies, and the stale "grant Accessibility permission" instructions were removed from the README.
- **Fixed the Mac hotkey failing to start.** On macOS 11+, `ctypes.util.find_library("Carbon")` returns `None` (system frameworks live in the dyld shared cache), so the daemon crashed before registering. It now loads Carbon by absolute path and logs any startup error to `~/.claude/tts_hotkey.log`.
- **Replay the last answer.** New global hotkey — Ctrl+Alt+R (Windows) / Ctrl+Option+R (macOS) — re-speaks the last reply. The server stores the last text and handles a new `__REPLAY__` command.
- **Audio follows your output device.** The server refreshes the audio device before each utterance, so switching output (e.g. connecting AirPods or headphones) is picked up without restarting the server.
- **Clearer install docs.** The README manual-install steps now include the full `git clone` + `cd` sequence (with a ZIP fallback), and the Controls list documents stop, replay, speed, voice change, and voice previews.
- **Audio-device follow made non-fragile.** The output-device refresh no longer tears down and re-initialises PortAudio before every utterance (which caused macOS `PaMacCore -50` errors); it only re-scans after an idle gap, so it still follows AirPods/headphone switches without thrashing the audio backend mid-burst.
- **Voice preview: fixed samples playing in the wrong voice.** The preview announced each voice by mutating a shared global (`__VOICE:name__`) and sent the sample as a separate message — but synthesis runs on a background thread, so a fast preview could synthesise a sample *after* the next voice-switch had overwritten the global, playing it in the wrong voice (mismatched label/gender). Each sample now carries its own voice atomically via the per-request `VOICE=name|text` prefix, correct regardless of timing.
- **Install no longer blocked by Homebrew Python (PEP 668).** On macOS with Homebrew's Python, a global `pip install` is refused (externally-managed environment), which aborted setup at the package step. The installer now retries with `--break-system-packages` when it hits this, so it completes.

## Packaging — 2026-06-30
- **Codex message-mode toggle added; final-only is the default.** Codex rollout logs contain both interim `agent_message` commentary/status updates and final replies. The watcher now filters by the rollout `phase` field and defaults to speaking only `phase: "final_answer"` messages, matching the quieter Claude TTS behavior. Users can opt back into hearing all assistant updates by writing `all` to `~/.claude/codex_tts_message_mode.txt`, or return to final-only by writing `final`. Windows helper scripts are included in the package as `Windows\set_codex_tts_all_messages.bat` and `Windows\set_codex_tts_final_only.bat`.
- **Voice alias coverage expanded.** Preview voice aliases now cover common misspellings and phonetic variants across the bundled Kokoro voices, including `onix`, `erik`, `micheal`, `skye`, `sara`, `lilly`, `jorge`, `louis`, and Echo variants such as `eco`/`eko`.
- **Voice alias tolerance improved.** Echo now accepts common misspellings/phonetic aliases: `echo`, `eco`, `eko`, `ecko`, `ekko`, and `echoo` all resolve to `am_echo`.
- **Friendly voice preview helper.** Installers now write bundled `tts_preview.py` beside the Kokoro server so Codex can trigger exact preview requests such as `quick preview voices`, `preview all voices`, and `preview voice onyx`. The Codex watcher also detects exact user preview phrases in rollout JSONL, then routes them through the helper. It supports short aliases, strict command matching, non-blocking previews, and `--dry-run` tests.
- **Timestamp parsing hardened.** The watcher now preserves explicit ISO-8601 timezone offsets
  when applying the 3-minute stale-message filter; naive timestamps still default to UTC.
- **Windows installer cleanup.** Removed the old low-level keyboard listener from the embedded
  Kokoro server. The packaged `tts_hotkey.py` `RegisterHotKey` daemon is now the only Windows
  global stop-hotkey path. Windows installer bumped to v1.4; Mac installer bumped to v1.2.
- **Ctrl+Alt+X stop hotkey now installed.** Installers previously advertised it but shipped it
  disabled. The Windows installer now installs the shared `tts_hotkey.py` `RegisterHotKey` daemon;
  the Mac installer a `pynput` launchd agent (Ctrl+Option+X). Both auto-start, are single-instance,
  and send `__STOP__` to the shared server (macOS needs Accessibility permission; the installer
  prints how). `pynput` added to the Mac dependency install. Codex's own `restart`/`stop` bats were
  audited and already target `codex_tts_watcher.py` specifically — no cross-kill, no change needed.
- **Mojibake repair.** A follow-up pass found the encoding cleanup had replaced non-ASCII glyphs with
  literal `?` in several places — most seriously inside the embedded server's `clean_text()`
  (`[→←↑↓⇒⇐]`, the five dash variants, and `[•·●◦]` became `?`), which would have flattened every
  `?` to a comma and read arrows/bullets aloud. Also affected this CHANGELOG, the README, and
  installer comments/echoes. Restored the correct characters (Windows BOM preserved); both installers
  re-verified — PowerShell/bash parse clean and the embedded server compiles.

## v1.5 — 2026-06-30
- **Watcher-only** — Stop hook (`codex_tts_hook.ps1` / `.sh`) removed from the setup.
  The hook fired at end-of-turn with `last_assistant_message`, but the watcher already
  reads the same text from the rollout JSONL file, causing the final reply to be spoken
  twice. The watcher provides complete coverage (it polls every 0.1 s and catches every
  `agent_message` event as it lands); the hook solved a near-theoretical miss scenario
  while introducing a reliable duplication problem. This aligns Codex TTS with the
  Cowork TTS design, which has always been watcher-only.
- **Installers updated** — Windows installer bumped to v1.3, Mac installer to v1.1 (later v1.4 / v1.2 — see Packaging, 2026-06-30).
  Hook writing and `settings.json` registration steps removed. Step count reduced from
  9 → 8 (Windows) and 9 → 7 (Mac).
- **`settings.json` migration** — `remove_codex_hook.ps1` provided in the live setup
  folder for users upgrading from v1.4. Removes the `codex_tts_hook` entry from
  `~/.claude/settings.json`. Run once after upgrading.

## Audit — 2026-06-29
- **Age-filter cross-check (no code change).** A field-name bug was found and fixed in the Claude
  Cowork TTS watcher, where the age filter read a non-existent `ts` field instead of the ISO-8601
  `timestamp` field and so never ran. The Codex watcher was audited against this: it already reads
  `data.get("timestamp")` and parses both ISO-8601 strings and numeric epochs (see `age filter`,
  v1.3). Confirmed against a real `rollout-*.jsonl` file — Codex records use `timestamp`
  (e.g. `"2026-06-04T15:55:45.076Z"`). The 180 s stale-content guard works as intended; no change required.

## v1.4 — 2026-06-29
- **Per-watcher voice** — `WATCHER_VOICE = None` constant added to `codex_tts_watcher.py`.
  Set it to any Kokoro voice name (e.g. `"am_adam"`) to give Codex TTS its own distinct voice,
  independent of the Cowork or Claude Code TTS voice. Uses the `VOICE=name|text` per-request
  prefix protocol introduced in `tts_server.py v2.1` — the voice travels with each request so
  there are no race conditions when multiple watchers are active simultaneously.
- **Robust Python launcher (Windows)** — `install_codex_tts_Windows.ps1` (now v1.2) launches Python through the Windows `py -3` launcher instead of bare `python` for the package install and every Kokoro-server / watcher launch (auto-start VBS, scheduled-task watchdog, and immediate launch). `py -3` is PATH-order independent, so the server and watcher always start under Python 3.x on machines with multiple Python installs. **Mac unaffected** — already resolves `python3` once.

## v1.3 — 2026-06-29
- **Faster poll**: `POLL` reduced from `0.5 s` to `0.1 s` — 5× faster response to new messages,
  matching the Claude Cowork TTS watcher.
- **Message age filter**: `MESSAGE_MAX_AGE_SECONDS = 180` — any message whose timestamp is older
  than 3 minutes is silently skipped, preventing stale content from being spoken on watcher
  startup or after a rescan.
- **State pruning**: `STATE_MAX_AGE_DAYS = 7` — tracked rollout file entries older than 7 days
  are pruned on initial scan, keeping memory footprint bounded over long-running sessions.
- **Mac installer**: `install_codex_tts_Mac.sh v1.0` added — installs shared Kokoro server,
  embeds watcher v1.3 with `pynput` hotkey support, registers Stop hook, sets up launchd
  auto-start for both the Kokoro server and the Codex watcher.
- **Windows installer**: bumped to `v1.1` with updated embedded watcher (v1.3) and BOM fix
  (UTF-8 with BOM to ensure correct PowerShell 5.1 parsing).

## v1.2 — 2026-06-28
- **Single-instance lock**: on startup the watcher binds a UDP socket to
  `127.0.0.1:59003`. Any duplicate process (watchdog + restart race, etc.) exits
  immediately. The OS releases the binding on process exit — no stale lock files.
  Port 59003 is used (not 59002) so this watcher coexists with Claude Cowork TTS.

## v1.1 — 2026-06-28
- **Log rotation**: `codex_tts_watcher_log.txt` is capped at 1 MB. On overflow the
  current log is renamed to `.prev` and a fresh file starts.

## v1.0 — 2026-06-27
- Initial release. Polls `~/.codex/sessions/rollout-*.jsonl` for `agent_message`
  events. Existing files start at EOF on watcher startup (no replay). New rollout
  files discovered after startup are read from offset 0. Shares Kokoro server on
  `localhost:59001` and toggle file at `~/.claude/tts_enabled.txt` with other TTS setups.




