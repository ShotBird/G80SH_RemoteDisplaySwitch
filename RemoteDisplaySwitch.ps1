# RemoteDisplaySwitch.ps1  (rev.8, 2026-09-28)  rev.8: 화면 꺼짐 동안 LHM 정지, 켜지면 재시작 (아래 Stop-Lhm 주석)
# 규칙
#  1. 원격이 아닐 때: 동글(BBC0104) 절대 사용 안 함. G80SH + G50F 평소 구성 유지 (어긋나면 즉시 복원)
#     단, 화면 절전으로 G80SH를 켤 수 없는 동안은 복구하지 않는다 (재인식 루프·장치음 방지, rev.6)
#     rev.7: 화면이 꺼져 있는 동안은 CCD 조회(QueryDisplayConfig)도 하지 않는다.
#            조회만으로도 절전 중인 GPU 를 D3→D0 로 깨우고, 그 재감지에서 G80SH 가 떨어진다
#            (09-28 ETW: GPU D0 전원 IRP 14회 중 11회가 이 프로세스). 화면 꺼짐 판정은 GPU 를 안 건드리는
#            "마지막 입력 후 경과 ≥ VIDEOIDLE" 로 한다. 원격 중이거나 원격 종료 직후 복원 대기 중이면 예외.
#  2. 원격일 때: 동글만 사용, G80SH/G50F 사용 안 함
#  3. 원격이 끝나면: 평소 구성으로 즉시 복원 + 리셋(사람이 PC 앞에서 쓰다가 끝낸 것과 같은 상태로)
#     → 원격 종료 뒤 화면 절전 때 나는 G80SH 재인식 루프 제거 목적
#     리셋 방식: reset_mode.txt (rewake | restartdev | gpureset | off), 기본 rewake
#
# 스크립트 파일(RemoteDisplaySwitch.ps1 / SwitchLib.ps1 / DispCfg.ps1)이 바뀌면 스스로 재시작한다 (수정 시 UAC 불필요).
# 로그: C:\ProgramData\RemoteDisplaySwitch.log

$ErrorActionPreference = 'SilentlyContinue'
$base     = Split-Path -Parent $MyInvocation.MyCommand.Path
$self     = $MyInvocation.MyCommand.Path
$mmt      = Join-Path $base 'MultiMonitorTool.exe'
$modeFile = Join-Path $base 'reset_mode.txt'
$log      = Join-Path $env:ProgramData 'RemoteDisplaySwitch.log'
$g80Dev   = 'DISPLAY\SAM7B0C\7&16B8DDB4&0&UID256'

function Log($m) {
    Add-Content $log ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    $f = Get-Item $log -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 300KB) { Get-Content $log -Tail 400 | Set-Content $log }
}

if (-not (Test-Path $mmt)) { Log 'MISSING MultiMonitorTool.exe - abort'; exit 1 }

$mutex = New-Object System.Threading.Mutex($false, 'Local\RemoteDisplaySwitch')
if (-not $mutex.WaitOne(15000)) { exit 0 }

. (Join-Path $base 'SwitchLib.ps1')

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RdsInput {
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    // 마지막 키보드/마우스 입력 후 경과(초). GPU 를 건드리지 않는다.
    public static double IdleSeconds() {
        var l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref l)) return 0;
        return ((uint)Environment.TickCount - l.dwTime) / 1000.0;
    }
    public static uint Wake() {
        var a = new INPUT[2];
        a[0].type = 0; a[0].u.mi.dx = 1;  a[0].u.mi.dwFlags = 1;
        a[1].type = 0; a[1].u.mi.dx = -1; a[1].u.mi.dwFlags = 1;
        SetThreadExecutionState(0x00000002); // ES_DISPLAY_REQUIRED (1회, 화면 켜기 + 절전 타이머 리셋)
        return SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

function Get-ResetMode { $m = Get-Content $modeFile -ErrorAction SilentlyContinue | Select-Object -First 1; if ($m) { $m.Trim().ToLower() } else { 'rewake' } }

function Do-Reset {
    $mode = Get-ResetMode
    switch ($mode) {
        'rewake'     { $r = "wake=" + [RdsInput]::Wake() }
        'restartdev' { $g80Dev = (Get-PnpDevice -Class Monitor -PresentOnly | Where-Object { $_.InstanceId -match 'SAM7B0C|SAM7B04' } | Select-Object -First 1).InstanceId; $r = ((& pnputil.exe /restart-device $g80Dev 2>&1) -join ' ') -replace '\s+', ' '; Start-Sleep 3; $r += " wake=" + [RdsInput]::Wake() }
        'gpureset'   { $r = "restart-device display adapter: " + (((& pnputil.exe /restart-device (Get-PnpDevice -Class Display | Where-Object { $_.InstanceId -match 'VEN_1002&DEV_7550' } | Select-Object -First 1).InstanceId 2>&1) -join ' ') -replace '\s+', ' '); Start-Sleep 5; $r += " wake=" + [RdsInput]::Wake() }
        default      { $r = 'no action' }
    }
    Log ("RESET mode={0} -> {1}" -f $mode, $r)
}

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
function Get-Remote {
    $e = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='chromoting'; Id=1,2; StartTime=$boot} -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($e) { [pscustomobject]@{ Active = ($e.Id -eq 1); At = $e.TimeCreated } } else { [pscustomobject]@{ Active = $false; At = $boot } }
}

# 화면 꺼짐 시간(VIDEOIDLE, AC) 을 powercfg 로 읽는다. GPU 무관. 10분마다 갱신(설정이 바뀔 수 있음).
function Get-VideoIdleSec {
    $out = & powercfg.exe /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null
    $line = $out | Where-Object { $_ -match 'AC.*0x([0-9A-Fa-f]+)' } | Select-Object -First 1
    if ($line -and $line -match '0x([0-9A-Fa-f]+)') { $v = [Convert]::ToInt32($matches[1], 16); if ($v -gt 0) { return $v } }
    return 300
}
$videoIdle = Get-VideoIdleSec; $videoIdleRead = Get-Date
# 화면이 꺼져 있다고 볼 조건 (둘 중 하나, 모두 GPU 무관):
#  a) 마지막 입력 후 경과가 VIDEOIDLE + 5초 이상 (5초는 전환 여유)
#  b) CaseDisplay 가 기록한 마지막 "display power: on/off" (GUID_CONSOLE_DISPLAY_STATE) 가 off
#     → 잠금(Win+L)·단축키 등 유휴 시간과 무관하게 꺼진 경우를 잡는다. CaseDisplay 가 떠 있을 때만 신뢰(로그가 낡을 수 있음).
#     주의: 잠금 화면(보안 데스크톱)에서는 GetLastInputInfo 가 입력을 못 보므로 (a) 는 잠금 중 화면이 켜져 있어도 참이 될 수 있다.
#     그 경우 조회가 멈추는 것뿐이고(화면 켜짐 = GPU 깨어 있음) 잠금 해제 입력으로 곧 재개된다.
$cdLog = Join-Path $env:ProgramData 'CaseDisplay.log'
function Is-DisplayOff {
    if ([RdsInput]::IdleSeconds() -ge ($videoIdle + 5)) { return $true }
    if (Get-Process CaseDisplay -ErrorAction SilentlyContinue) {
        $line = Get-Content $cdLog -Tail 80 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'display power: (on|off)' } | Select-Object -Last 1
        if ($line) { return ($line -match 'display power: off\s*$') }
    }
    return $false
}

# rev.8 (2026-09-28): 화면 꺼짐 동안 LibreHardwareMonitor 도 멈춘다.
#   09-28 22:49 ETW(wake5): 절전 중 GPU D0 전원 IRP 12/12 가 LHM 의 1초 GPU 센서 폴링. RDS 조회를 멈춘 뒤 남은 상시 깨움 주체.
#   화면 꺼짐 중엔 케이스 LCD·쿨러 LED 도 꺼지므로 센서가 없어도 잃는 것 없음. 화면이 켜지면 작업으로 다시 띄운다.
#   이 스크립트가 멈춘 LHM 만 다시 띄운다(사용자가 직접 끈 LHM 은 건드리지 않음). 작업 이름: LibreHardwareMonitor (Highest).
$lhmStoppedByUs = $false
function Stop-Lhm {
    $p = Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue
    if ($p) {
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        $left = @(Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue).Count
        Log ("LHM stopped (display off) pid={0} left={1}" -f (($p | ForEach-Object Id) -join ','), $left)
        if ($left -eq 0) { $script:lhmStoppedByUs = $true }
    }
}
function Start-Lhm {
    if (-not $script:lhmStoppedByUs) { return }
    $script:lhmStoppedByUs = $false
    if (Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue) { Log 'LHM already running (display on)'; return }
    $o = ((& schtasks.exe /run /tn 'LibreHardwareMonitor' 2>&1) -join ' ') -replace '\s+', ' '
    Log ("LHM start (display on) -> {0}" -f $o)
}

$srcFiles = @($self, (Join-Path $base 'SwitchLib.ps1'), (Join-Path $base 'DispCfg.ps1'))
function Get-Stamp { ($srcFiles | ForEach-Object { (Get-Item $_).LastWriteTimeUtc.Ticks }) -join '|' }
$stamp = Get-Stamp
$movedLogged = $false

Log ("watcher started (rev.8) reset={0} videoidle={1}s" -f (Get-ResetMode), $videoIdle)
$wasRemote = (Get-Remote).Active
$lastTry = [datetime]::MinValue
$pendingReset = $false
$asleepLogged = $false
$offLogged = $false

while ($true) {
    # 자기 갱신
    # 폴더가 옮겨지면(09-24 C:\dev\PC → C:\dev\1_PC_Setup) 옛 경로로 재시작하다 죽는다 -> 파일이 없으면 재시작하지 않고 계속 감시
    if (@($srcFiles | Where-Object { -not (Test-Path $_) }).Count) {
        if (-not $movedLogged) { Log "script files missing at $base (folder moved?) - keep running, no restart"; $movedLogged = $true }
    }
    elseif ((Get-Stamp) -ne $stamp) {
        Log 'script changed - restarting'
        $mutex.ReleaseMutex(); $mutex.Dispose()
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$self`""
        exit 0
    }

    $r = Get-Remote
    if (-not $r.Active -and $wasRemote) {
        # 해제 직후 같은 초 재접속(세션 교체) 무시: 3초 뒤 다시 확인
        Start-Sleep 3
        $r = Get-Remote
        if (-not $r.Active) { $pendingReset = $true; $lastTry = [datetime]::MinValue; Log ("remote ended at {0:HH:mm:ss}" -f $r.At) }
    }
    $wasRemote = $r.Active

    # rev.7: 화면 꺼짐 동안은 CCD 조회를 하지 않는다 (조회가 GPU 를 깨워 G80SH 재감지 폭풍을 만든다)
    if (((Get-Date) - $videoIdleRead).TotalMinutes -ge 10) { $videoIdle = Get-VideoIdleSec; $videoIdleRead = Get-Date }
    if (-not $r.Active -and -not $pendingReset -and (Is-DisplayOff)) {
        if (-not $offLogged) { Log ("display off (idle {0:N0}s >= videoidle {1}s) - pause CCD polling" -f [RdsInput]::IdleSeconds(), $videoIdle); $offLogged = $true }
        Stop-Lhm
        Start-Sleep -Seconds 2
        continue
    }
    if ($offLogged) { Log 'display on (input) - resume CCD polling'; $offLogged = $false; $asleepLogged = $false }
    Start-Lhm

    $l = Get-Layout
    $canTry = ((Get-Date) - $lastTry).TotalSeconds -ge 15

    if ($r.Active) {
        $pendingReset = $false
        if (-not (Is-RemoteLayout $l) -and $canTry) {
            $lastTry = Get-Date
            $s = Switch-ToRemote
            Log ("REMOTE layout -> ok={0} active={1} primary={2} [{3}]" -f $s.Ok, $s.Active, $s.Primary, $s.Steps)
        }
    }
    else {
        # 화면 절전 중에는 G80SH 링크가 끊겨 평소 구성이 어긋나 보인다.
        # 그때 복구를 시도하면 모니터를 다시 붙였다 떼며 재인식 루프와 장치 연결/해제음이 반복된다 -> 깨어난 뒤에 고친다.
        # (원격이 끝난 직후 복원 $pendingReset 은 예외: 리셋이 화면을 깨운다)
        $avail = Get-Available
        $homeAsleep = -not (Has-G80 $avail)
        if ($homeAsleep -and -not $pendingReset) {
            if (-not $asleepLogged) { Log ("home monitor not attachable (asleep) - skip repair [available: {0}]" -f ($avail -join ',')); $asleepLogged = $true }
        }
        else {
            if ($asleepLogged) { Log 'home monitor back - resume repair'; $asleepLogged = $false }
            if (-not (Is-HomeLayout $l) -and $canTry) {
                $lastTry = Get-Date
                $s = Switch-ToHome
                Log ("HOME layout -> ok={0} active={1} primary={2} [{3}]" -f $s.Ok, $s.Active, $s.Primary, $s.Steps)
                $l = Get-Layout
            }
        }
        if ($pendingReset -and (Is-HomeLayout $l)) { $pendingReset = $false; Start-Sleep 2; Do-Reset }
    }
    Start-Sleep -Seconds 2
}
