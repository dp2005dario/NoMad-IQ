@echo off
rem Doble clic: arrancar ECLIPTA (ver docs\guia-pc.md).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0eclipta.ps1" arrancar
pause
