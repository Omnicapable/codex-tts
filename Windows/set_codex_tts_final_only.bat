@echo off
if not exist "%USERPROFILE%\.claude\" mkdir "%USERPROFILE%\.claude"
echo final>"%USERPROFILE%\.claude\codex_tts_message_mode.txt"
echo Codex TTS message mode set to final-only.
