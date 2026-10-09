# Windows collection and local session memory. Dot-sourcing does not change power settings.
. (Join-Path $PSScriptRoot 'PowerProfileLogic.ps1')

function Read-DetectionOptions {
    param($Json)
    $options = @{
        gameProcesses = @(); excludeProcesses = @(); gameRoots = @()
        backgroundGraceSec = 120; discoverSteam = $true; discoverEpic = $true
    }
    if ($Json) {
        foreach ($key in @('gameProcesses', 'excludeProcesses', 'gameRoots')) {
            $options[$key] = @($Json.$key | Where-Object { $_ -is [string] -and $_.Trim() } | ForEach-Object { $_.Trim() })
        }
        foreach ($key in @('discoverSteam', 'discoverEpic')) {
            if ($Json.$key -is [bool]) { $options[$key] = $Json.$key }
        }
        $grace = $Json.backgroundGraceSec -as [int]
        if ($null -ne $grace -and $grace -ge 0 -and $grace -le 900) { $options.backgroundGraceSec = $grace }
    }
    return $options
}

function Write-AtomicJson {
    param([string]$Path, $Value, [switch]$Pretty)
    $temporary = "$Path.$PID.tmp"
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 10 -Compress:(-not $Pretty)
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding $true))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-InstalledGameRoots {
    param($Options)
    $roots = @()
    foreach ($root in $Options.gameRoots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            $roots += [PSCustomObject]@{ Path = [IO.Path]::GetFullPath($root); Name = 'Custom'; Source = 'ConfiguredRoot' }
        }
    }
    if ($Options.discoverSteam) {
        $steamPaths = @()
        foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
            $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($entry.SteamPath) { $steamPaths += $entry.SteamPath }
            if ($entry.InstallPath) { $steamPaths += $entry.InstallPath }
        }
        $libraries = @($steamPaths)
        foreach ($steamPath in @($steamPaths | Select-Object -Unique)) {
            $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
            if (Test-Path -LiteralPath $vdf) {
                $content = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
                foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                    $libraries += $match.Groups[1].Value.Replace('\\', '\')
                }
            }
        }
        foreach ($library in @($libraries | Select-Object -Unique)) {
            $apps = Join-Path $library 'steamapps'
            foreach ($manifest in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
                try {
                    $content = Get-Content -LiteralPath $manifest.FullName -Raw
                    $directory = [regex]::Match($content, '"installdir"\s+"([^"]+)"').Groups[1].Value
                    $name = [regex]::Match($content, '"name"\s+"([^"]+)"').Groups[1].Value
                    if ($name -match '^(Wallpaper Engine|Lossless Scaling|Steamworks Common Redistributables)$') { continue }
                    $common = Join-Path $apps 'common'
                    if (-not $directory) { continue }
                    $root = [IO.Path]::GetFullPath((Join-Path $common $directory))
                    if ((Test-PathUnderRoot $root $common) -and (Test-Path -LiteralPath $root -PathType Container)) {
                        $roots += [PSCustomObject]@{ Path = $root; Name = $name; Source = 'Steam' }
                    }
                } catch { continue }
            }
        }
    }
    if ($Options.discoverEpic -and $env:ProgramData) {
        $manifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
        foreach ($manifest in @(Get-ChildItem -LiteralPath $manifests -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
            try {
                $item = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
                if ($item.InstallLocation -and $item.LaunchExecutable -and (Test-Path -LiteralPath $item.InstallLocation -PathType Container)) {
                    $roots += [PSCustomObject]@{ Path = [IO.Path]::GetFullPath($item.InstallLocation); Name = $item.DisplayName; Source = 'Epic' }
                }
            } catch { continue }
        }
    }
    return @($roots | Sort-Object Path -Unique)
}

function Test-ExcludedGameProcess {
    param([string]$Name, $Options, [string[]]$NonGameProcesses)
    $normalized = $Name.ToLowerInvariant() -replace '\.exe$', ''
    if (-not $normalized -or $NonGameProcesses -contains $normalized) { return $true }
    # Helpers also live inside game install folders; they must never keep a session alive.
    if ($normalized -match '^(crashreport|crashpad|unitycrash|unrealcef|cefsubprocess|easyanticheat|beservice|battleye|eaclauncher|werfault|wermgr)' -or
        $normalized -match '(launcher|updater|unins\d*)$' -or $normalized -match '^(setup|install|vcredist|dxsetup|redist)' -or
        $normalized -match '^(wallpaper|losslessscaling|leigod|leishensdk|nvidia overlay|gameoverlayui|csrss|svchost|wmiprvse|mscorsvw|system|registry|memory compression)') {
        return $true
    }
    return @($Options.excludeProcesses | ForEach-Object { $_.ToLowerInvariant() -replace '\.exe$', '' }) -contains $normalized
}

function Get-ProcessIdentity {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $path = ''; $started = ''; $cpuSeconds = $null
        try { $path = $process.Path } catch {}
        try { $started = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
        try { $cpuSeconds = $process.TotalProcessorTime.TotalSeconds } catch {}
        # Protected processes can deny module enumeration while allowing a CIM image path.
        if (-not $path -or -not $started) {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
            if (-not $path) { $path = [string]$cim.ExecutablePath }
            if (-not $started -and $cim.CreationDate) { $started = $cim.CreationDate.ToUniversalTime().ToString('o') }
        }
        return @{ Id = $ProcessId; Name = $process.ProcessName; Path = $path; Started = $started; CpuSeconds = $cpuSeconds }
    } catch { return $null }
}

function Get-SessionGameDetection {
    param($Foreground, $Load, $Options, [string[]]$NonGameProcesses, [string]$StateDirectory, [switch]$ReadOnly)
    $sessionPath = Join-Path $StateDirectory 'game_session_state.json'
    $now = [DateTime]::UtcNow
    $session = $null
    try { $session = Get-Content -LiteralPath $sessionPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
    $identities = @()
    $foregroundIdentity = Get-ProcessIdentity -ProcessId $Foreground.Pid
    if ($foregroundIdentity) { $identities += $foregroundIdentity }
    if ($session -and $session.processId -ne $Foreground.Pid) {
        $background = Get-ProcessIdentity -ProcessId $session.processId
        if ($background) { $identities += $background }
    }
    $roots = @(Get-InstalledGameRoots -Options $Options)
    $explicit = @($Options.gameProcesses | ForEach-Object { $_.ToLowerInvariant() -replace '\.exe$', '' })
    $inactiveReason = ''
    foreach ($identity in $identities) {
        $isForeground = $identity.Id -eq $Foreground.Pid
        $sameSession = $session -and $identity.Started -and $session.started -eq $identity.Started -and
            $session.processId -eq $identity.Id -and $session.path -eq $identity.Path
        $age = [double]::PositiveInfinity
        if ($sameSession) {
            try { $age = ($now - [DateTime]::Parse($session.lastForegroundAt).ToUniversalTime()).TotalSeconds } catch { $sameSession = $false }
        }
        $cpu = 0.0
        if ($Load.TopCpuPid -eq $identity.Id) { $cpu = [double]$Load.TopCpuValue }
        # CPU seconds are independent of localized performance-counter names and total core count.
        if ($Load.ProcessCpu -and $Load.ProcessCpu.ContainsKey([int]$identity.Id)) { $cpu = $Load.ProcessCpu[[int]$identity.Id] }
        $gpu = 0.0
        if ($Load.ProcessGpu -and $Load.ProcessGpu.ContainsKey([int]$identity.Id)) { $gpu = $Load.ProcessGpu[[int]$identity.Id] }
        $root = $roots | Where-Object { Test-PathUnderRoot $identity.Path $_.Path } | Select-Object -First 1
        $candidate = @{
            Excluded = Test-ExcludedGameProcess $identity.Name $Options $NonGameProcesses
            SameSession = [bool]$sameSession; Foreground = $isForeground; SecondsSinceForeground = $age
            Cpu = $cpu; Gpu = $gpu; InLibrary = [bool]$root
            ExplicitGame = $explicit -contains $identity.Name.ToLowerInvariant()
            IsD3D = $isForeground -and $Foreground.IsD3D; IsFullscreen = $isForeground -and $Foreground.IsFs
        }
        $signal = Get-GameSignalDecision $candidate $Options.backgroundGraceSec
        if ($signal -eq 'BackgroundInactive') {
            $inactiveReason = "后台游戏已低负载 [$($identity.Name).exe pid=$($identity.Id)] ownCPU=$([int]$cpu)% ownGPU=$([int]$gpu)% 离开前台=$([int]$age)s"
        }
        if (-not (Test-PositiveGameSignal $signal)) { continue }
        $lastForeground = if ($isForeground) { $now.ToString('o') } else { $session.lastForegroundAt }
        if (-not $ReadOnly -and $identity.Started) {
            Write-AtomicJson $sessionPath @{
                processId = $identity.Id; processName = $identity.Name; path = $identity.Path
                started = $identity.Started; lastForegroundAt = $lastForeground; source = $signal
            }
        }
        return @{
            IsGame = $true; Source = $signal; ProcessName = $identity.Name; ProcessId = $identity.Id
            Reason = "$signal [$($identity.Name).exe pid=$($identity.Id)] ownCPU=$([int]$cpu)% ownGPU=$([int]$gpu)% library=$($root.Name); $(Format-LoadSummary $Load)"
        }
    }
    # Keep a living, inactive session for return-to-game; dead/reused PIDs cannot inherit it.
    if ($session -and -not $ReadOnly) {
        $alive = @($identities | Where-Object { $_.Id -eq $session.processId -and $_.Started -and $_.Started -eq $session.started -and $_.Path -eq $session.path }).Count -gt 0
        if (-not $alive) { Remove-Item -LiteralPath $sessionPath -ErrorAction SilentlyContinue }
    }
    if ($inactiveReason) { return @{ IsGame = $false; Source = 'BackgroundInactive'; Reason = $inactiveReason } }
    return @{ IsGame = $false; Source = 'NoGameSignal'; Reason = "无已确认游戏; front=$($Foreground.Proc).exe pid=$($Foreground.Pid); $(Format-LoadSummary $Load)" }
}
