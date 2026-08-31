@echo off
REM Honor X50 KSU ko load - step 2 after root_setup.bat
REM Loads kernelsu_h80gt.ko + spawns ksud, enables SELinux enforcing as last step
REM Usage: ksu_setup.bat

setlocal EnableDelayedExpansion

where adb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] adb not in PATH
    exit /b 1
)

adb devices | findstr /R "device$" >nul
if errorlevel 1 (
    echo [ERROR] No device connected
    exit /b 1
)

REM --- Check root is ready ---
for /f "tokens=*" %%i in ('adb shell "cat /sys/module/module/parameters/sig_enforce 2>/dev/null"') do set SIG=%%i
for /f "tokens=*" %%i in ('adb shell "getenforce 2>/dev/null"') do set ENF=%%i
echo [+] State: enforce=!ENF! sig_enforce=!SIG!

if "!SIG!" NEQ "N" (
    echo [ERROR] sig_enforce=!SIG! - run root_setup.bat first to flip it
    exit /b 1
)

REM --- Push KSU files (if not already on device) ---
echo [+] Staging KSU files...
adb shell "ls -la /data/local/tmp/kernelsu.ko /data/local/tmp/ksud /data/local/tmp/load_ko /data/local/tmp/magiskpolicy /data/local/tmp/ksu_rules 2>/dev/null" >nul
for %%f in (kernelsu.ko ksud load_ko magiskpolicy ksu_rules) do (
    adb push "%~dp0%%f" "/data/local/tmp/%%f" >nul
)
adb shell "chmod 755 /data/local/tmp/ksud /data/local/tmp/magiskpolicy /data/local/tmp/load_ko"
echo [+] Pushed.

REM --- Create KSU RUNDIR ---
for /f "tokens=*" %%i in ('adb shell "echo /data/local/tmp/ksu_load_$(date +%%Y%%m%%d_%%H%%M%%S)"') do set RUNDIR=%%i
echo [+] RUNDIR: !RUNDIR!
adb shell "mkdir -p !RUNDIR!"

REM --- Copy ko + helpers into RUNDIR ---
adb push "%~dp0kernelsu_h80gt.ko" "!RUNDIR!/kernelsu.ko" >nul
adb push "%~dp0load_ko" "!RUNDIR!/load_ko" >nul
adb push "%~dp0ksud" "!RUNDIR!/ksud" >nul
adb push "%~dp0magiskpolicy" "!RUNDIR!/magiskpolicy" >nul
adb push "%~dp0ksu_rules" "!RUNDIR!/ksu_rules" >nul
adb shell "chmod 755 !RUNDIR!/load_ko !RUNDIR!/ksud !RUNDIR!/magiskpolicy"

REM --- Build fake kallsyms (prepend commit_creds) ---
echo [+] Building fake kallsyms (prepend commit_creds)...
adb shell "echo 0 > /proc/sys/kernel/kptr_restrict"
adb shell "cat /proc/kallsyms > !RUNDIR!/real_ks.tmp"
adb shell "echo ffffffc0081725ac T commit_creds > !RUNDIR!/kallsyms_add.txt"
adb shell "cat !RUNDIR!/kallsyms_add.txt !RUNDIR!/real_ks.tmp > !RUNDIR!/fake_kallsyms"

REM --- Bind-mount fake kallsyms to /proc/kallsyms (for load_ko) ---
echo [+] Bind-mounting fake kallsyms -> /proc/kallsyms...
adb shell "mount --bind !RUNDIR!/fake_kallsyms /proc/kallsyms"
adb shell "cat /proc/kallsyms | grep 'commit_creds' | head -1"

REM --- Run ksud (it will call load_ko internally) ---
echo [+] Running ksud to load ko + setup KSU...
adb shell "KERNELSU_KO=!RUNDIR!/kernelsu.ko !RUNDIR!/ksud --post-fs-data 2>&1 | tee !RUNDIR!/ksud.log" &
set KSPID=%ERRORLEVEL%
ping -n 30 127.0.0.1 >nul

REM --- Wait for /data/adb/ksu ---
for /L %%i in (1,1,30) do (
    adb shell "test -d /data/adb/ksu && echo OK" | findstr "OK" >nul
    if not errorlevel 1 (
        echo [+] /data/adb/ksu created
        goto :ksu_ready
    )
    ping -n 3 127.0.0.1 >nul
)

echo [-] /data/adb/ksu not created - check ksud.log
adb shell "tail -30 !RUNDIR!/ksud.log"
exit /b 1

:ksu_ready
echo [+] Stage ksud --boot-completed...
adb shell "!RUNDIR!/ksud --boot-completed" 2>&1
ping -n 3 127.0.0.1 >nul

REM --- Verify module loaded ---
echo [+] Check kernel module:
adb shell "cat /proc/modules | grep kernelsu"

REM --- Restore kallsyms bind-mount ---
adb shell "umount /proc/kallsyms" 2>nul

REM --- Final: enforce SELinux ---
echo [+] Final: enabling SELinux enforcing...
adb shell "echo 1 > /sys/fs/selinux/enforce"

echo.
echo ============================================================
echo  KSU LOADED + ENFORCING
echo  Test: adb shell su -c id  (will use KernelSU manager APK)
echo  Or:  adb shell /data/local/tmp/su -c id  (our static su still works)
echo ============================================================