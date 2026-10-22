@echo off
cd /d "%~dp0"
if not exist logs mkdir logs
:loop
echo [%date% %time%] starting backend >> logs\backend.log
py -3.11 app.py >> logs\backend.log 2>&1
echo [%date% %time%] backend stopped, restarting in 10 seconds >> logs\backend.log
ping -n 11 127.0.0.1 >nul
goto loop
