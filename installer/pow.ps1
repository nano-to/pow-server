<#
Nano.to PoW Windows one-click installer.

Recommended install:
	iwr https://raw.githubusercontent.com/nano-to/pow-server/main/installer/pow.ps1 -UseB | iex

Pass the API key with one of:
	$env:WORK_API_KEY = "WORK-KEY-..."
	$env:NANO_POW_API_KEY = "WORK-KEY-..."
#>

[CmdletBinding()]
param(
	[string]$ApiKey = $(if ($env:NANO_POW_API_KEY) { $env:NANO_POW_API_KEY } elseif ($env:WORK_API_KEY) { $env:WORK_API_KEY } else { $env:API_KEY }),
	[string]$RpcApiBase = $(if ($env:RPC_API_BASE) { $env:RPC_API_BASE } else { 'https://rpc.nano.to' }),
	[int]$LocalPort = $(if ($env:NANO_POW_LOCAL_PORT) { [int]$env:NANO_POW_LOCAL_PORT } else { 7077 }),
	[string]$InstallRoot = $(if ($env:NANO_POW_HOME) { $env:NANO_POW_HOME } else { Join-Path $env:LOCALAPPDATA 'NanoPow' }),
	[string]$WorkerArchiveUrl = $(if ($env:NANO_POW_WORKER_ARCHIVE_URL) { $env:NANO_POW_WORKER_ARCHIVE_URL } else { 'https://repo.nano.org/pow-server/nano_pow_server-latest-win64.tar.gz' }),
	[string]$FrpVersion = $(if ($env:NANO_POW_FRP_VERSION) { $env:NANO_POW_FRP_VERSION } else { '' }),
	[string]$WorkerName = $(if ($env:NANO_POW_WORKER_NAME) { $env:NANO_POW_WORKER_NAME } else { $env:COMPUTERNAME }),
	[string]$Gpu = $(if ($env:NANO_POW_GPU) { $env:NANO_POW_GPU } else { '0:0' }),
	[switch]$NoStart,
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$Message) { Write-Host "[nano-pow] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[nano-pow] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[nano-pow] WARNING: $Message" -ForegroundColor Yellow }
function Fail([string]$Message) { throw "[nano-pow] $Message" }

function Test-DefenderBlocked($ErrorRecord) {
	$message = [string]$ErrorRecord.Exception.Message
	if ($ErrorRecord.Exception.InnerException) {
		$message += ' ' + [string]$ErrorRecord.Exception.InnerException.Message
	}
	return $message -match 'virus|potentially unwanted|0x800700E1|Operation did not complete successfully'
}

function Fail-DefenderBlocked([string]$Component, [string]$Path, [string]$Url) {
	$details = @(
		"Windows Security blocked $Component while installing nano-pow.",
		"Path: $Path",
		"Source: $Url",
		"",
		"This is usually Microsoft Defender classifying the tunnel client as potentially unwanted software because it creates outbound tunnels.",
		"Open Windows Security -> Virus & threat protection -> Protection history, review the blocked item, and choose Allow on device if you trust this install.",
		"Then rerun the PowerShell install command.",
		"",
		"We do not disable antivirus automatically. If you do not want to allow the tunnel client on Windows, run the worker from Linux/macOS instead."
	) -join "`n"
	Fail $details
}

function Invoke-IfLive([scriptblock]$Block, [string]$DryRunMessage) {
	if ($DryRun) {
		Write-Step "DRY-RUN: $DryRunMessage"
		return $null
	}
	& $Block
}

function Assert-WindowsAmd64 {
	if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
		Fail 'This installer is for native Windows PowerShell. Use installer/pow.sh on Linux/macOS.'
	}
	if (-not [Environment]::Is64BitOperatingSystem) {
		Fail 'Only 64-bit Windows is supported.'
	}
}

function Get-GpuInfo {
	$controllers = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
	$names = @($controllers | ForEach-Object { $_.Name } | Where-Object { $_ })
	$joined = ($names -join '; ')
	$vendor = 'none'
	if ($joined -match 'NVIDIA') { $vendor = 'nvidia' }
	elseif ($joined -match 'AMD|Radeon|Advanced Micro Devices') { $vendor = 'amd' }
	elseif ($joined -match 'Intel') { $vendor = 'intel' }

	[pscustomobject]@{
		Vendor = $vendor
		Names = $names
		Summary = $(if ($joined) { $joined } else { 'No display adapter reported by Windows' })
	}
}

function Assert-GpuReady($GpuInfo) {
	Write-Step "Detected GPU: $($GpuInfo.Summary)"
	if ($GpuInfo.Vendor -eq 'none' -or $GpuInfo.Vendor -eq 'intel') {
		Write-Warn 'No AMD/NVIDIA GPU detected. The worker may fall back to CPU or fail to use GPU acceleration.'
		return
	}

	if ($GpuInfo.Vendor -eq 'nvidia') {
		$nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
		if (-not $nvidiaSmi) {
			Write-Warn 'NVIDIA GPU detected but nvidia-smi.exe is not on PATH. Install/update NVIDIA drivers if worker startup fails.'
		} else {
			& $nvidiaSmi.Source | Out-Null
			Write-Ok 'NVIDIA driver command is available'
		}
	}

	if ($GpuInfo.Vendor -eq 'amd') {
		Write-Ok 'AMD GPU detected. Ensure AMD Adrenalin/OpenCL runtime is installed if worker startup fails.'
	}
}

function New-InstallDirs {
	$dirs = @(
		$InstallRoot,
		(Join-Path $InstallRoot 'bin'),
		(Join-Path $InstallRoot 'config'),
		(Join-Path $InstallRoot 'logs'),
		(Join-Path $InstallRoot 'run'),
		(Join-Path $InstallRoot 'scripts'),
		(Join-Path $InstallRoot 'tmp')
	)
	foreach ($dir in $dirs) {
		Invoke-IfLive { New-Item -ItemType Directory -Force -Path $dir | Out-Null } "create $dir" | Out-Null
	}
}

function Download-File([string]$Url, [string]$Path) {
	Write-Step "Downloading $Url"
	Invoke-IfLive {
		try {
			Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
		} catch {
			if (Test-DefenderBlocked $_) {
				Fail-DefenderBlocked 'downloaded file' $Path $Url
			}
			throw
		}
	} "download $Url to $Path" | Out-Null
}

function Install-Worker {
	$binDir = Join-Path $InstallRoot 'bin'
	$archivePath = Join-Path (Join-Path $InstallRoot 'tmp') 'nano_pow_server-win64.tar.gz'
	$extractDir = Join-Path (Join-Path $InstallRoot 'tmp') 'worker'
	$target = Join-Path $binDir 'nano_pow_server.exe'

	if ((Test-Path $target) -and -not $DryRun) {
		Write-Ok "Worker already installed: $target"
		return $target
	}

	Download-File $WorkerArchiveUrl $archivePath
	Invoke-IfLive {
		try {
			Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
			New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
			tar.exe -xzf $archivePath -C $extractDir
			$exe = Get-ChildItem -Path $extractDir -Recurse -Filter 'nano_pow_server.exe' | Select-Object -First 1
			if (-not $exe) { Fail 'Worker archive did not contain nano_pow_server.exe' }
			Copy-Item -Force $exe.FullName $target
		} catch {
			if (Test-DefenderBlocked $_) {
				Fail-DefenderBlocked 'nano_pow_server.exe' $target $WorkerArchiveUrl
			}
			throw
		}
	} "extract worker archive and install nano_pow_server.exe" | Out-Null

	return $target
}

function Get-FrpReleaseVersion {
	if ($FrpVersion) { return $FrpVersion.TrimStart('v') }
	$latest = Invoke-RestMethod -Uri 'https://api.github.com/repos/fatedier/frp/releases/latest' -Headers @{ 'User-Agent' = 'nano-pow-windows-installer' }
	if (-not $latest.tag_name) { Fail 'Unable to resolve latest frp release' }
	return ([string]$latest.tag_name).TrimStart('v')
}

function Install-Frpc {
	$binDir = Join-Path $InstallRoot 'bin'
	$target = Join-Path $binDir 'frpc.exe'
	if ((Test-Path $target) -and -not $DryRun) {
		Write-Ok "frpc already installed: $target"
		return $target
	}

	$version = Get-FrpReleaseVersion
	$zipName = "frp_${version}_windows_amd64.zip"
	$url = "https://github.com/fatedier/frp/releases/download/v${version}/${zipName}"
	$zipPath = Join-Path (Join-Path $InstallRoot 'tmp') $zipName
	$extractDir = Join-Path (Join-Path $InstallRoot 'tmp') 'frp'

	Download-File $url $zipPath
	Invoke-IfLive {
		try {
			Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
			Expand-Archive -Force -Path $zipPath -DestinationPath $extractDir
			$exe = Get-ChildItem -Path $extractDir -Recurse -Filter 'frpc.exe' | Select-Object -First 1
			if (-not $exe) { Fail 'FRP archive did not contain frpc.exe' }
			Copy-Item -Force $exe.FullName $target
		} catch {
			if (Test-DefenderBlocked $_) {
				Fail-DefenderBlocked 'frpc.exe tunnel client' $target $url
			}
			throw
		}
	} "extract frpc.exe" | Out-Null

	return $target
}

function Invoke-BootstrapTunnel([string]$Key) {
	if (-not $Key) { Fail 'Missing Work API key. Set WORK_API_KEY or pass -ApiKey.' }
	$body = @{
		workerName = $WorkerName
		localPort = $LocalPort
		transport = 'frp'
		allowedActions = @('work_generate')
		allowedMethods = @('POST')
	} | ConvertTo-Json -Depth 5

	Write-Step 'Requesting tunnel config from rpc.nano.to'
	$result = Invoke-RestMethod -Method Post -Uri "$RpcApiBase/api/account/work-servers/bootstrap-tunnel" -Headers @{ Authorization = "Bearer $Key" } -ContentType 'application/json' -Body $body
	if ($result.response -and $result.response.data) { return $result.response.data }
	if ($result.data) { return $result.data }
	return $result
}

function Write-FrpcConfig($Bundle) {
	$configPath = Join-Path (Join-Path $InstallRoot 'config') 'frpc.toml'
	$tunnel = $Bundle.tunnel
	foreach ($field in @('host', 'remotePort', 'frpToken', 'frpSubdomain')) {
		if (-not $tunnel.$field) { Fail "Bootstrap payload missing tunnel.$field" }
	}

	$name = ($WorkerName -replace '[^A-Za-z0-9_-]', '-')
	$content = @"
serverAddr = "$($tunnel.host)"
serverPort = $($tunnel.remotePort)

auth.method = "token"
auth.token = "$($tunnel.frpToken)"

transport.tls.enable = true

[[proxies]]
name = "$name-$($tunnel.frpSubdomain)"
type = "http"
localIP = "127.0.0.1"
localPort = $LocalPort
subdomain = "$($tunnel.frpSubdomain)"
"@

	Invoke-IfLive { Set-Content -Path $configPath -Value $content -Encoding ASCII } "write $configPath" | Out-Null
	return $configPath
}

function Write-WorkerConfig($GpuInfo) {
	$configPath = Join-Path (Join-Path $InstallRoot 'config') 'config-nano-pow-server.toml'
	$deviceType = if ($GpuInfo.Vendor -in @('nvidia', 'amd')) { 'gpu' } else { 'cpu' }
	$content = @"
[server]
bind = "127.0.0.1"
port = $LocalPort
log_to_stderr = true

[device]
type = "$deviceType"
platform = 0
device = 0
"@
	Invoke-IfLive { Set-Content -Path $configPath -Value $content -Encoding ASCII } "write $configPath" | Out-Null
	return $configPath
}

function Write-StateConfig($Bundle, $GpuInfo, [string]$WorkerPath, [string]$FrpcPath, [string]$WorkerConfigPath, [string]$FrpcConfigPath) {
	$configPath = Join-Path (Join-Path $InstallRoot 'config') 'config.json'
	$config = [ordered]@{
		apiKey = $ApiKey
		workerName = $WorkerName
		localPort = $LocalPort
		os = 'windows'
		arch = 'amd64'
		gpuVendor = $GpuInfo.Vendor
		gpuSummary = $GpuInfo.Summary
		worker = @{ binary = $WorkerPath; config = $WorkerConfigPath }
		frp = @{ binary = $FrpcPath; config = $FrpcConfigPath }
		tunnel = $Bundle.tunnel
		createdAt = (Get-Date).ToUniversalTime().ToString('o')
	}
	Invoke-IfLive { $config | ConvertTo-Json -Depth 8 | Set-Content -Path $configPath -Encoding UTF8 } "write $configPath" | Out-Null
	return $configPath
}

function Write-RunnerScripts([string]$WorkerPath, [string]$WorkerConfigPath, [string]$FrpcPath, [string]$FrpcConfigPath) {
	$scriptsDir = Join-Path $InstallRoot 'scripts'
	$workerScript = Join-Path $scriptsDir 'run-worker.ps1'
	$tunnelScript = Join-Path $scriptsDir 'run-tunnel.ps1'
	$doctorScript = Join-Path $scriptsDir 'doctor.ps1'
	$logsDir = Join-Path $InstallRoot 'logs'

	$workerContent = @"
`$ErrorActionPreference = 'Stop'
& '$WorkerPath' --config_path '$WorkerConfigPath' 1>>'$logsDir\worker.out.log' 2>>'$logsDir\worker.err.log'
"@
	$tunnelContent = @"
`$ErrorActionPreference = 'Stop'
& '$FrpcPath' -c '$FrpcConfigPath' 1>>'$logsDir\tunnel.out.log' 2>>'$logsDir\tunnel.err.log'
"@
	$doctorContent = @"
`$ErrorActionPreference = 'Continue'
Write-Host 'Nano PoW Doctor'
Write-Host 'Install root: $InstallRoot'
Write-Host 'Worker exists: ' (Test-Path '$WorkerPath')
Write-Host 'frpc exists:   ' (Test-Path '$FrpcPath')
Write-Host 'Worker task:   ' ((schtasks /Query /TN NanoPowWorker 2>`$null) -ne `$null)
Write-Host 'Tunnel task:   ' ((schtasks /Query /TN NanoPowTunnel 2>`$null) -ne `$null)
try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:$LocalPort' -ContentType 'application/json' -Body '{"action":"work_generate","hash":"E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7"}' -TimeoutSec 20 | ConvertTo-Json -Compress } catch { Write-Host 'Local work_generate failed:' `$_.Exception.Message }
"@

	Invoke-IfLive {
		Set-Content -Path $workerScript -Value $workerContent -Encoding ASCII
		Set-Content -Path $tunnelScript -Value $tunnelContent -Encoding ASCII
		Set-Content -Path $doctorScript -Value $doctorContent -Encoding ASCII
	} "write runner scripts" | Out-Null

	return @{ Worker = $workerScript; Tunnel = $tunnelScript; Doctor = $doctorScript }
}

function Install-ScheduledTasks($Scripts) {
	$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
	$workerCmd = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$($Scripts.Worker)`""
	$tunnelCmd = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$($Scripts.Tunnel)`""

	Invoke-IfLive {
		schtasks /Create /TN NanoPowWorker /SC ONLOGON /RL LIMITED /F /TR $workerCmd | Out-Null
		schtasks /Create /TN NanoPowTunnel /SC ONLOGON /RL LIMITED /F /TR $tunnelCmd | Out-Null
	} 'create NanoPowWorker and NanoPowTunnel scheduled tasks' | Out-Null
}

function Start-ScheduledTasks {
	Invoke-IfLive {
		schtasks /Run /TN NanoPowWorker | Out-Null
		Start-Sleep -Seconds 2
		schtasks /Run /TN NanoPowTunnel | Out-Null
	} 'start scheduled tasks' | Out-Null
}

function Test-LocalWorker {
	if ($DryRun) { return }
	Start-Sleep -Seconds 4
	try {
		$body = @{ action = 'work_generate'; hash = 'E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7' } | ConvertTo-Json -Compress
		$response = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$LocalPort" -ContentType 'application/json' -Body $body -TimeoutSec 30
		if (-not $response.work) { Write-Warn 'Local worker responded but did not include work.'; return }
		Write-Ok 'Local work_generate succeeded'
	} catch {
		Write-Warn "Local worker test failed: $($_.Exception.Message). Run the doctor script for logs."
	}
}

function Send-Heartbeat($Bundle, $GpuInfo) {
	if ($DryRun -or -not $ApiKey) { return }
	try {
		$tunnel = $Bundle.tunnel
		$payload = @{
			workerName = $WorkerName
			labels = 'windows,auto,managed'
			localPort = $LocalPort
			tunnelHost = $tunnel.publicHost
			tunnelPort = $tunnel.remotePort
			tunnelUrl = $tunnel.publicUrl
			version = '0.1.0-windows'
			os = 'windows'
			arch = 'amd64'
			gpuVendor = $GpuInfo.Vendor
			computeMode = $(if ($GpuInfo.Vendor -in @('nvidia', 'amd')) { 'gpu' } else { 'cpu' })
		} | ConvertTo-Json -Depth 5
		Invoke-RestMethod -Method Post -Uri "$RpcApiBase/api/account/work-servers/heartbeat" -Headers @{ Authorization = "Bearer $ApiKey" } -ContentType 'application/json' -Body $payload | Out-Null
		Write-Ok 'Heartbeat sent to rpc.nano.to'
	} catch {
		Write-Warn "Heartbeat pending: $($_.Exception.Message)"
	}
}

function Main {
	Assert-WindowsAmd64
	if (-not $ApiKey) { Fail 'Missing Work API key. Set $env:WORK_API_KEY before running the installer.' }

	Write-Step 'Starting Windows one-click setup'
	New-InstallDirs
	$gpuInfo = Get-GpuInfo
	Assert-GpuReady $gpuInfo
	$workerPath = Install-Worker
	$frpcPath = Install-Frpc
	$bundle = if ($DryRun) { @{ tunnel = @{ host = 'tunnel.nano.to'; remotePort = 7000; frpToken = 'dry-run'; frpSubdomain = 'dry-run'; publicHost = 'dry-run.tunnel.nano.to'; publicUrl = 'https://dry-run.tunnel.nano.to' } } } else { Invoke-BootstrapTunnel $ApiKey }
	$workerConfigPath = Write-WorkerConfig $gpuInfo
	$frpcConfigPath = Write-FrpcConfig $bundle
	Write-StateConfig $bundle $gpuInfo $workerPath $frpcPath $workerConfigPath $frpcConfigPath | Out-Null
	$scripts = Write-RunnerScripts $workerPath $workerConfigPath $frpcPath $frpcConfigPath
	Install-ScheduledTasks $scripts

	if (-not $NoStart) {
		Start-ScheduledTasks
		Test-LocalWorker
		Send-Heartbeat $bundle $gpuInfo
	}

	Write-Ok 'Windows PoW setup complete'
	Write-Host "Install root: $InstallRoot"
	Write-Host "Doctor: powershell -NoProfile -ExecutionPolicy Bypass -File `"$($scripts.Doctor)`""
	if ($bundle.tunnel.publicUrl) { Write-Host "Public URL: $($bundle.tunnel.publicUrl)" }
}

try {
	Main
} catch {
	if (Test-DefenderBlocked $_) {
		Write-Host '[nano-pow] Windows Security blocked a downloaded installer file.' -ForegroundColor Red
		Write-Host 'Open Windows Security -> Virus & threat protection -> Protection history, review the blocked item, and choose Allow on device if you trust this install. Then rerun the command.' -ForegroundColor Yellow
	} else {
		Write-Host $_.Exception.Message -ForegroundColor Red
	}
	Write-Host "Run with -DryRun to validate paths without changing the machine." -ForegroundColor Yellow
	exit 1
}
