# SwitchLib.ps1 - 화면 전환 (Windows CCD API 전용, MultiMonitorTool 미사용)
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'DispCfg.ps1')

$script:G50 = 'SAM79DF'; $script:DONGLE = 'BBC0104'
# G80SH 는 연결 방식마다 장치 ID 가 다르다: DP = SAM7B0C, HDMI = SAM7B04 (2026-09-25 HDMI 시험에서 확인). 둘 다 G80SH 로 본다.
$script:G80Ids = [string[]]@('SAM7B0C', 'SAM7B04')
$script:AllIds = [string[]]($G80Ids + @($G50, $DONGLE))

function Has-G80($ids) { @($ids | Where-Object { $G80Ids -contains $_ }).Count -gt 0 }
# 지금 켤 수 있는 G80SH ID (없으면 DP ID)
function Get-G80Id { $a = @(Get-Available | Where-Object { $G80Ids -contains $_ }); if ($a.Count) { $a[0] } else { $G80Ids[0] } }

function Get-Layout {
    $parts = ([Ccd2]::Active($AllIds)) -split '\|', 2
    [pscustomobject]@{ Active = @($parts[0] -split ',' | Where-Object { $_ }); Primary = $parts[1] }
}

# 절전 등으로 링크가 끊긴 모니터는 여기에 안 나온다 (그 상태에서 구성을 바꾸면 재인식 루프가 생긴다)
function Get-Available { @(([Ccd2]::Availables($AllIds)) -split ',' | Where-Object { $_ }) }

function Is-RemoteLayout($l) { ($l.Active -contains $DONGLE) -and -not (Has-G80 $l.Active) -and -not ($l.Active -contains $G50) }
function Is-HomeLayout($l)   { (Has-G80 $l.Active) -and ($l.Active -contains $G50) -and -not ($l.Active -contains $DONGLE) -and ($G80Ids -contains $l.Primary) }

function Switch-ToRemote {
    $steps = @()
    for ($try = 1; $try -le 3; $try++) {
        $steps += "t${try}: " + [Ccd2]::Activate([string[]]@($DONGLE), [int[]]@(0), [int[]]@(0))
        Start-Sleep 2
        $l = Get-Layout
        if (Is-RemoteLayout $l) { break }
        Start-Sleep 2
    }
    [pscustomobject]@{ Ok = (Is-RemoteLayout $l); Steps = ($steps -join ' / '); Active = ($l.Active -join ','); Primary = $l.Primary }
}

function Switch-ToHome {
    $steps = @()
    $G80 = Get-G80Id
    for ($try = 1; $try -le 3; $try++) {
        $steps += "t${try}: " + [Ccd2]::Activate([string[]]@($G80, $G50), [int[]]@(0, -2560), [int[]]@(0, 340))
        Start-Sleep 2
        $l = Get-Layout
        if (Is-HomeLayout $l) { break }
        Start-Sleep 2
    }
    [pscustomobject]@{ Ok = (Is-HomeLayout $l); Steps = ($steps -join ' / '); Active = ($l.Active -join ','); Primary = $l.Primary }
}
