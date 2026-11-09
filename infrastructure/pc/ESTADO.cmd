@echo off
rem Doble clic: estado ECLIPTA (ver docs\guia-pc.md).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0eclipta.ps1" estado
pause
