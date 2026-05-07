@echo off
:: Verifie les droits admin, les demande si necessaire
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
:: Lancement du script avec le chemin complet (resout le pb de $PSCommandPath vide)
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0NetSwitchPro.ps1"
