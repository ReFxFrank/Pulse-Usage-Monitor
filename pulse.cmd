@echo off
REM Pulse - launcher (Windows). Forwards all args to server.js.
REM Usage: pulse.cmd [--port N] [--inspect-schema]
node "%~dp0server.js" %*
