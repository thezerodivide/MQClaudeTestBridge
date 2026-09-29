@echo off
rem Syntax check, then the Lua tests, then the Python tests. Exit code 0 only if all three pass. Run from anywhere.
rem (Design item 4 of DL-021: one command checks both sides. The Python tests use the standard library only.)
set "ROOT=%~dp0.."
luajit "%ROOT%\test\harness\syntax_check.lua"
if errorlevel 1 exit /b %errorlevel%
luajit "%ROOT%\test\harness\run.lua"
if errorlevel 1 exit /b %errorlevel%
python -m unittest discover -s "%ROOT%\python\tests" -t "%ROOT%\python" -v
exit /b %errorlevel%
