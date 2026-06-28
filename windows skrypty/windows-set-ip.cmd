@echo off
setlocal

set "IFACE=Wi-Fi"
set "IP=192.168.1.15"
set "MASK=255.255.255.0"
set "GATEWAY=192.168.1.1"
set "DNS=192.168.1.1"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Uruchamiam ponownie jako administrator...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

netsh interface ip set address name="%IFACE%" static %IP% %MASK% %GATEWAY% 1
netsh interface ip set dns name="%IFACE%" static %DNS% primary
ipconfig /flushdns >nul

echo Gotowe: statyczne IP %IP%
pause