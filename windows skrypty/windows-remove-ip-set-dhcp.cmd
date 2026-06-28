@echo off
setlocal

set "IFACE=Wi-Fi"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Uruchamiam ponownie jako administrator...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

netsh interface ip set address name="%IFACE%" source=dhcp
netsh interface ip set dns name="%IFACE%" source=dhcp
ipconfig /release "%IFACE%"
ipconfig /renew "%IFACE%"
ipconfig /flushdns >nul

echo Gotowe: DHCP wlaczone
pause