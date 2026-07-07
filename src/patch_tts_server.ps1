# patch_tts_server.ps1
# Copies tts_server.py v2.1 into the live Kokoro install at %USERPROFILE%\.claude\kokoro# Run once after updating TTS Pack to get per-request voice prefix support.
$src  = Join-Path $PSScriptRoot 'tts_server.py'
$dest = Join-Path $env:USERPROFILE '.claude\kokoro	ts_server.py'
Copy-Item -Path $src -Destination $dest -Force
Write-Host 'tts_server.py updated. Restart the Kokoro server to apply.' -ForegroundColor Green
