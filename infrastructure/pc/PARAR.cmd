@echo off
rem Doble clic: parar ECLIPTA (ver docs\guia-pc.md).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0eclipta.ps1" parar
pause
