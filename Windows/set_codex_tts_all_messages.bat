@echo off
if not exist "%USERPROFILE%\.claude\" mkdir "%USERPROFILE%\.claude"
echo all>"%USERPROFILE%\.claude\codex_tts_message_mode.txt"
echo Codex TTS message mode set to all assistant messages.
