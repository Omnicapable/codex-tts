# Changelog — Codex TTS

## Shared server v2.5

**Improved speech**

- **Speed survives a restart too.** The chosen speed is saved to `speed.txt` beside the
  server (mirroring voice memory in `voice.txt`) and reloaded on start, so it no longer
  resets to the default after a reboot.
- **Abbreviations are finally spoken.** `e.g.`, `i.e.`, `vs.`, `etc.`, `approx.` were never
  expanded — their patterns ended in a word boundary that cannot match before a space, so the
  rules existed but never fired. They now read "for example", "that is", "versus",
  "etcetera", "approximately".
- **Money reads naturally in more shapes.** `$3.5` reads "3 dollars and 50 cents" (the
  ".5" used to be left dangling after "3 dollars"), `$0.99` reads "99 cents", `$1.5 million`
  and `$1.5M` read "1 point 5 million dollars" (scale words thousand/million/billion/trillion
  plus attached suffixes k/M/B), and odd precision like `$12.345` falls back to
  "12 point 345 dollars". `$3.50` and `$1,234.56` read exactly as before.
- **More emoji and symbols stripped.** The star/symbol and arrow blocks (U+2B00-2BFF,
  U+2190-21FF — e.g. star and left-right-arrow glyphs) no longer reach the voice.

**Cleanup**

- **Dead fallback removed.** The Claude Code and Cowork installers wrote `tts_speak.py` and
  set an unused `$ttsScript`/`TTS_SCRIPT` variable pointing at it; nothing ever invoked
  either. Both are gone. The persistent server remains the only audio path, unchanged.
  Existing installs keep an inert `tts_speak.py` on disk; it is harmless.

All six embedded servers and the three `src/` copies remain byte-identical (v2.5).

---

## Shared server v2.4

**Fixed**

- **Mid-reply silence.** Long sentences became single oversized chunks (200+ chars); when
  one followed a short chunk, playback caught up with synthesis and speech stalled for a
  couple of seconds. Sentences now split at clause breaks (commas, semicolons) into chunks
  of at most ~120 characters, and fragments under ~40 merge with a neighbour. Synthesis on
  CPU runs about 4x realtime, so with uniform chunks the synthesizer always finishes the
  next chunk before the current one ends. Measured on a real reply: zero gaps.
- **Speech starts sooner.** A short opening sentence is no longer glued onto a following
  long one, so the first chunk stays small. Measured time-to-first-audio on a typical
  reply: 1.5s, down from 3.6s.

Chunking only: the control protocol, stop/replay hotkeys, queue, and audio path are
untouched. All six embedded servers and the three `src/` copies remain byte-identical
(v2.4).

---

## Shared server v2.3

**New**

- **Your voice now survives a restart.** The chosen voice is saved to `voice.txt` next to the
  server and reloaded on start, so it no longer resets to the default after a reboot or a
  server restart.
- **Version numbers and bare domains are read properly.** `3.11` is spoken "3 point 11",
  `2.3.1` as "2 point 3 point 1", and `claude.ai` as "claude dot ai" (known TLDs only).
  Money is unaffected — `$3.50` still reads "3 dollars and 50 cents". The pronunciation rule
  is deliberately ordered **after** the money rule: a ` point ` substitution applied first
  eats the decimal and produces "3 dollars point 50". That ordering is load-bearing and is
  pinned by a comment in `clean_text()`; do not move it above the money rule.

**Fixed / consolidated**

- **All installers now ship one identical Kokoro server.** Every installer writes the *same*
  file (`~/.claude/kokoro/tts_server.py`, port 59001), but the six embedded copies had drifted
  (six copies ranging from 170 to 192 lines), so **install order silently decided which server
  you ended up with** — installing a second product could silently replace a newer server with
  an older, smaller one (the Codex Mac copy, for example, lacked emoji stripping). All six are now
  byte-identical to a single canonical **v2.3**, so any install order gives the same result.
- **Version header corrected.** The embedded servers advertised `v2.0` / `v2.1` in their
  docstring while actually shipping replay, output-device follow and the money/decimal fixes.
  The header now matches the code and is stamped v2.3.
- **`src/` resynced (was stale).** The published `src/tts_server.py`, `src/tts_hotkey.py` and
  `src/tts_hotkey_mac.py` still held older code: no `__REPLAY__`, a stop-only `Ctrl+Alt+X`
  hotkey daemon, and the previous `pynput` Mac hotkey. The installers shipped the replay
  hotkey while the published source folder did not contain it. `src/` now matches byte-for-byte
  what the installers write.
- **Claude Code Mac reached parity.** Its embedded server was missing voice memory (so the
  chosen voice was lost on restart) and the version/domain pronunciation block. Both added.
- **Cowork gained emoji stripping.** Its server lacked the emoji strip the other products had,
  so emoji could be read aloud. Added to the Windows and Mac servers.
- **Note — `tts_speak.py` is vestigial.** The installers still write it and still set
  `$ttsScript` / `TTS_SCRIPT` to it, but nothing invokes it: the variable is assigned once and
  never used. The "exactly one audio path" guarantee holds. The dead file and variable are
  safe to remove in a later pass.

**Known issue (not fixed here)**

- **Occasional silence mid-reply.** Synthesis and playback already overlap (a producer thread
  synthesizes ahead of the playback loop), so this is *not* a serialization problem. Two real
  causes remain: playback calls `sd.play()`/`sd.wait()` per chunk, which opens and closes an
  output stream for every chunk; and there is no buffer-ahead, so playback starts the instant
  chunk 1 is ready and any slower chunk becomes an audible gap. The synthesis queue is also
  unbounded. Being addressed separately — it touches stop-hotkey semantics and interacts with
  `_refresh_audio_device()`, so it is deliberately not bundled with this release.

---

## v1.7
- **Mac stop hotkey needs no permission now.** The macOS stop hotkey (Ctrl+Option+X) was rewritten from `pynput` to Carbon `RegisterEventHotKey`, which is not gated by Accessibility / Input Monitoring, so there is no first-use permission prompt. `pynput` was dropped from the Mac dependencies, and the stale "grant Accessibility permission" instructions were removed from the README.
- **Fixed the Mac hotkey failing to start.** On macOS 11+, `ctypes.util.find_library("Carbon")` returns `None` (system frameworks live in the dyld shared cache), so the daemon crashed before registering. It now loads Carbon by absolute path and logs any startup error to `~/.claude/tts_hotkey.log`.
- **Replay the last answer.** New global hotkey — Ctrl+Alt+R (Windows) / Ctrl+Option+R (macOS) — re-speaks the last reply. The server stores the last text and handles a new `__REPLAY__` command.
- **Audio follows your output device.** The server refreshes the audio device before each utterance, so switching output (e.g. connecting AirPods or headphones) is picked up without restarting the server.
- **Clearer install docs.** The README manual-install steps now include the full `git clone` + `cd` sequence (with a ZIP fallback), and the Controls list documents stop, replay, speed, voice change, and voice previews.
- **Audio-device follow made non-fragile.** The output-device refresh no longer tears down and re-initialises PortAudio before every utterance (which caused macOS `PaMacCore -50` errors); it only re-scans after an idle gap, so it still follows AirPods/headphone switches without thrashing the audio backend mid-burst.
- **Voice preview: fixed samples playing in the wrong voice.** The preview announced each voice by mutating a shared global (`__VOICE:name__`) and sent the sample as a separate message — but synthesis runs on a background thread, so a fast preview could synthesise a sample *after* the next voice-switch had overwritten the global, playing it in the wrong voice (mismatched label/gender). Each sample now carries its own voice atomically via the per-request `VOICE=name|text` prefix, correct regardless of timing.
- **Install no longer blocked by Homebrew Python (PEP 668).** On macOS with Homebrew's Python, a global `pip install` is refused (externally-managed environment), which aborted setup at the package step. The installer now retries with `--break-system-packages` when it hits this, so it completes.
- **Money and large numbers now read correctly.** The `$` cleaner only handled a single digit and the thousands-comma strip only removed one comma per number, so `$50` was spoken "5 dollars zero" and `1,000,000` became "one thousand, zero zero zero". Both now parse the whole value: `$50` → "50 dollars", `$3.50` → "3 dollars and 50 cents", `1,000,000` → "1000000", `$1,234.56` → "1234 dollars and 56 cents". Plain decimals (`3.14`) and percentages were already correct and are unaffected.

## v1.6
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

## v1.5
- **Watcher-only** — Stop hook (`codex_tts_hook.ps1` / `.sh`) removed from the setup.
  The hook fired at end-of-turn with `last_assistant_message`, but the watcher already
  reads the same text from the rollout JSONL file, causing the final reply to be spoken
  twice. The watcher provides complete coverage (it polls every 0.1 s and catches every
  `agent_message` event as it lands); the hook solved a near-theoretical miss scenario
  while introducing a reliable duplication problem. This aligns Codex TTS with the
  Cowork TTS design, which has always been watcher-only.
- **Installers updated** — Windows installer bumped to v1.3, Mac installer to v1.1 (later v1.4 / v1.2 — see v1.6).
  Hook writing and `settings.json` registration steps removed. Step count reduced from
  9 → 8 (Windows) and 9 → 7 (Mac).
- **`settings.json` migration** — `remove_codex_hook.ps1` provided in the live setup
  folder for users upgrading from v1.4. Removes the `codex_tts_hook` entry from
  `~/.claude/settings.json`. Run once after upgrading.

## Audit
- **Age-filter cross-check (no code change).** A field-name bug was found and fixed in the Claude
  Cowork TTS watcher, where the age filter read a non-existent `ts` field instead of the ISO-8601
  `timestamp` field and so never ran. The Codex watcher was audited against this: it already reads
  `data.get("timestamp")` and parses both ISO-8601 strings and numeric epochs (see `age filter`,
  v1.3). Confirmed against a real `rollout-*.jsonl` file — Codex records use `timestamp`
  (e.g. `"2026-06-04T15:55:45.076Z"`). The 180 s stale-content guard works as intended; no change required.

## v1.4
- **Per-watcher voice** — `WATCHER_VOICE = None` constant added to `codex_tts_watcher.py`.
  Set it to any Kokoro voice name (e.g. `"am_adam"`) to give Codex TTS its own distinct voice,
  independent of the Cowork or Claude Code TTS voice. Uses the `VOICE=name|text` per-request
  prefix protocol introduced in `tts_server.py v2.1` — the voice travels with each request so
  there are no race conditions when multiple watchers are active simultaneously.
- **Robust Python launcher (Windows)** — `install_codex_tts_Windows.ps1` (now v1.2) launches Python through the Windows `py -3` launcher instead of bare `python` for the package install and every Kokoro-server / watcher launch (auto-start VBS, scheduled-task watchdog, and immediate launch). `py -3` is PATH-order independent, so the server and watcher always start under Python 3.x on machines with multiple Python installs. **Mac unaffected** — already resolves `python3` once.

## v1.3
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

## v1.2
- **Single-instance lock**: on startup the watcher binds a UDP socket to
  `127.0.0.1:59003`. Any duplicate process (watchdog + restart race, etc.) exits
  immediately. The OS releases the binding on process exit — no stale lock files.
  Port 59003 is used (not 59002) so this watcher coexists with Claude Cowork TTS.

## v1.1
- **Log rotation**: `codex_tts_watcher_log.txt` is capped at 1 MB. On overflow the
  current log is renamed to `.prev` and a fresh file starts.

## v1.0
- Initial release. Polls `~/.codex/sessions/rollout-*.jsonl` for `agent_message`
  events. Existing files start at EOF on watcher startup (no replay). New rollout
  files discovered after startup are read from offset 0. Shares Kokoro server on
  `localhost:59001` and toggle file at `~/.claude/tts_enabled.txt` with other TTS setups.




