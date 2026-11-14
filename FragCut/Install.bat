@echo off
rem Opens the FragCut installer window (no console window stays open).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Install.ps1"
