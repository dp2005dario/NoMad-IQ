@echo off
rem Doble clic: clave ECLIPTA (ver docs\guia-pc.md).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0eclipta.ps1" clave
pause
