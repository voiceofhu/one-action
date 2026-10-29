#Requires -Version 5.1
# One Node lifecycle for Windows hosts (monitor mode only): install, status,
# doctor, upgrade, rollback, restart, logs, uninstall, and the upgrade request
# the node queues for the installer. Windows counterpart of node/install.sh.
#
# Run as Administrator. Installation reads ONE_NODE_SERVER, ONE_NODE_ID and
# ONE_NODE_BOOTSTRAP_TOKEN (plus optional ONE_NODE_VERSION,
# ONE_NODE_ENROLL_TIMEOUT and ONE_NODE_ALLOW_INSECURE) from the environment.
# Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Role = 'monitor',
    [switch]$Reset,
    [switch]$Status,
    [switch]$Doctor,
    [switch]$Upgrade,
    [Parameter(Position = 0)]
    [string]$Target = '',
    [switch]$Rollback,
    [switch]$Restart,
    [switch]$Logs,
    [switch]$Follow,
    [switch]$Uninstall,
    [switch]$Yes,
    [switch]$ProcessUpgradeRequest,
    [switch]$Help
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# RSA-3072 key whose private half signs every release SHA256SUMS as
# SHA256SUMS.rsa.sig. Assigned unconditionally so the environment cannot
# replace the trust root; scripts/sign-release.sh checks it is the same key
# as ONE_NODE_RELEASE_RSA_PUBLIC_KEY in scripts/shared/bootstrap.sh.
$script:OneNodeReleaseModulus = 'wpZSFZX6/OjPHr+OJtl0zBT8uqXgfKrqptLQRHCO9myeLh9geka7TMZ8IlK0g4NSstx+qQWWjyND7sCQnydZDBxbfIsM2v25Fj3N3Tp0i0Rwf6Qim6neVCxrI0Y0k2hAlRBaBo4abxvmvmAJXkoS6IRWq8GOow3Km6Rxj8AgXRrqLq2c475RwFTpnBSjXnD/9sb/VLMkUvH047TJb18R9L2iwxFNEj/3urzsL5pLHj7yXGDQs/SR5KHQd1Je+TOlJfDGeDVTGUlmQ04+v6ksXc3bKmUItCx3Kh2NAB5d9qO1Wzzhw0mNghfSxv4GOQyK6DgBTqKYc0OgriGl26U+nY496CMUZW2HQvHfSdvGSkNMQ5FgyXpZlTm+zhdbMmY3mWH6q5ZZNXPw7ntJnU4m0v0UwgoGpHgtmEtuVCTDbw5KlBEEhIVR4PS52Ajm3UNQlShJMYCWfVpNJiXxlN5PcPezF6z2Ef7Brz/sSORfTwXEPqI7nb2HggDV6gn/O/j7'
$script:OneNodeReleaseExponent = 'AQAB'
$script:OneNodeRepository = 'voiceofhu/one-action'
$script:OneNodeServiceName = 'OneNode'
$script:OneNodeMutexName = 'Global\OneNodeInstaller'
$script:OneNodeUserAgent = 'one-node-installer'
$script:OneNodeManifestFormat = 'one-node-windows-v1'
$script:OneNodeManifestKeys = @('format', 'mode', 'role', 'current_version', 'previous_version', 'state_dir')
$script:OneNodeTrustedSids = @('S-1-5-18', 'S-1-5-32-544')
$script:OneNodeOperations = @('Status', 'Doctor', 'Upgrade', 'Rollback', 'Restart', 'Logs', 'Uninstall', 'ProcessUpgradeRequest', 'Help')
$script:OneNodeHealthSeconds = 20
$script:OneNodeUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:OneNodeInsecure = $false
$script:OneNodeCaptureFile = $null
$script:OneNodeExitCode = 0
$script:OneNodeScriptPath = [string]$PSCommandPath

# ---------------------------------------------------------------------------
# Output and failures
# ---------------------------------------------------------------------------

# Every line also lands in the upgrade-request transcript while one runs.
function Write-OneNodeLine {
    param([System.IO.TextWriter]$Writer, [string]$Line)
    $Writer.WriteLine($Line)
    if ($script:OneNodeCaptureFile) {
        [System.IO.File]::AppendAllText($script:OneNodeCaptureFile, $Line + "`n", $script:OneNodeUtf8)
    }
}

function Write-OneNodeLog {
    param([string]$Message)
    Write-OneNodeLine -Writer ([Console]::Out) -Line "[one-node] $Message"
}

function Write-OneNodeWarning {
    param([string]$Message)
    Write-OneNodeLine -Writer ([Console]::Error) -Line "[one-node] warning: $Message"
}

function Write-OneNodeErrorLine {
    param([string]$Message)
    Write-OneNodeLine -Writer ([Console]::Error) -Line "[one-node] error: $Message"
}

# Throws instead of exiting so an in-process upgrade can record the failure;
# the entry point prints "[one-node] error: ..." and exits 1.
function Stop-OneNodeInstaller {
    param([string]$Message)
    throw $Message
}

# A broken chain of trust is fatal unless the operator opted into development.
function Invoke-OneNodeTrustFailure {
    param([string]$Message)
    if ($script:OneNodeInsecure) {
        Write-OneNodeWarning "$Message (continuing because ONE_NODE_ALLOW_INSECURE=true)"
        return
    }
    Stop-OneNodeInstaller $Message
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

function Test-OneNodeVersion {
    param([string]$Value)
    return ($Value -cmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z')
}

function Test-OneNodeDevelopmentUrl {
    param([string]$Uri)
    return ($Uri -cmatch '^http://(127\.0\.0\.1|localhost|host\.orb\.internal):[0-9]{1,5}(/|\z)')
}

function Get-OneNodeEnvironmentInput {
    $names = @(
        'ONE_NODE_SERVER', 'ONE_NODE_ID', 'ONE_NODE_BOOTSTRAP_TOKEN', 'ONE_NODE_VERSION',
        'ONE_NODE_ALLOW_INSECURE', 'ONE_NODE_RELEASE_BASE_URL', 'ONE_NODE_ENROLL_TIMEOUT'
    )
    $values = @{}
    foreach ($name in $names) {
        $values[$name] = [string][Environment]::GetEnvironmentVariable($name)
    }
    return $values
}

function Assert-OneNodeSingleLine {
    param([string]$Name, [string]$Value)
    if ($Value -eq '') { Stop-OneNodeInstaller "$Name is required" }
    if ($Value -match "[`r`n]") { Stop-OneNodeInstaller "$Name must be a single line" }
}

function ConvertTo-OneNodeReleaseSettings {
    param([hashtable]$Environment)
    $insecureText = [string]$Environment['ONE_NODE_ALLOW_INSECURE']
    if ($insecureText -eq '') { $insecureText = 'false' }
    if ($insecureText -cnotin @('true', 'false')) {
        Stop-OneNodeInstaller 'ONE_NODE_ALLOW_INSECURE must be true or false'
    }
    $insecure = ($insecureText -ceq 'true')
    $baseUrl = ([string]$Environment['ONE_NODE_RELEASE_BASE_URL']).TrimEnd('/')
    if ($baseUrl) {
        if (-not $insecure) {
            Stop-OneNodeInstaller 'local HTTP release assets require ONE_NODE_ALLOW_INSECURE=true'
        }
        if (-not (Test-OneNodeDevelopmentUrl $baseUrl)) {
            Stop-OneNodeInstaller 'ONE_NODE_RELEASE_BASE_URL is only available for local development (http://127.0.0.1:PORT, http://localhost:PORT or http://host.orb.internal:PORT)'
        }
    }
    return @{ Insecure = $insecure; ReleaseBaseUrl = $baseUrl }
}

function ConvertTo-OneNodeInstallConfig {
    param([hashtable]$Environment, [bool]$Reset)
    $settings = ConvertTo-OneNodeReleaseSettings -Environment $Environment
    $server = [string]$Environment['ONE_NODE_SERVER']
    $nodeId = [string]$Environment['ONE_NODE_ID']
    $token = [string]$Environment['ONE_NODE_BOOTSTRAP_TOKEN']
    Assert-OneNodeSingleLine -Name 'ONE_NODE_SERVER' -Value $server
    Assert-OneNodeSingleLine -Name 'ONE_NODE_ID' -Value $nodeId
    Assert-OneNodeSingleLine -Name 'ONE_NODE_BOOTSTRAP_TOKEN' -Value $token
    if ($nodeId -cnotmatch '^[1-9][0-9]{0,18}\z') {
        Stop-OneNodeInstaller 'ONE_NODE_ID must be a positive integer'
    }
    $version = [string]$Environment['ONE_NODE_VERSION']
    if ($version -and -not (Test-OneNodeVersion $version)) {
        Stop-OneNodeInstaller 'ONE_NODE_VERSION must be an exact three-component numeric version'
    }
    $timeoutText = [string]$Environment['ONE_NODE_ENROLL_TIMEOUT']
    if ($timeoutText -eq '') { $timeoutText = '120' }
    if ($timeoutText -cnotmatch '^[0-9]{1,6}\z' -or [int]$timeoutText -le 0) {
        Stop-OneNodeInstaller 'ONE_NODE_ENROLL_TIMEOUT must be a positive integer'
    }
    if ($Reset -and -not $settings.Insecure) {
        Stop-OneNodeInstaller '-Reset is only available for an insecure development installation'
    }
    if ($server -cmatch '^(https|grpcs)://[^/\s]') {
        # TLS control connection.
    } elseif ($server -cmatch '^(http|grpc)://[^/\s]' -or $server -cmatch '^[A-Za-z0-9.\[\]:-]+:[0-9]{1,5}\z') {
        if (-not $settings.Insecure) {
            Stop-OneNodeInstaller 'plaintext control connections require ONE_NODE_ALLOW_INSECURE=true'
        }
    } else {
        Stop-OneNodeInstaller 'ONE_NODE_SERVER is invalid'
    }
    return @{
        Server = $server
        NodeId = $nodeId
        Token = $token
        Version = $version
        EnrollTimeout = [int]$timeoutText
        Insecure = $settings.Insecure
        ReleaseBaseUrl = $settings.ReleaseBaseUrl
        Reset = $Reset
    }
}

function Get-OneNodeOperation {
    param([hashtable]$Options)
    $selected = @(foreach ($name in $script:OneNodeOperations) { if ($Options[$name]) { $name } })
    if ($selected.Count -gt 1) {
        Stop-OneNodeInstaller ('choose only one of ' + (($selected | ForEach-Object { "-$_" }) -join ', '))
    }
    if ($selected.Count -eq 1) { return $selected[0] }
    return ''
}

function Assert-OneNodeOptionCombination {
    param([hashtable]$Options, [string]$Operation)
    if ($Options['Follow'] -and $Operation -ne 'Logs') { Stop-OneNodeInstaller '-Follow is only valid with -Logs' }
    if ($Options['Yes'] -and $Operation -ne 'Uninstall') { Stop-OneNodeInstaller '-Yes is only valid with -Uninstall' }
    if ($Options['Target'] -and $Operation -ne 'Upgrade') { Stop-OneNodeInstaller "unexpected argument: $($Options['Target'])" }
    if ($Options['Reset'] -and $Operation) { Stop-OneNodeInstaller '-Reset is only valid for installation' }
}

# ---------------------------------------------------------------------------
# Files and text formats
# ---------------------------------------------------------------------------

# Splits LF or CRLF text into lines; one trailing line break is optional.
function Split-OneNodeLines {
    param([string]$Content)
    $text = $Content -replace "`r`n", "`n"
    if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
    if ($text -eq '') { return }
    $text -split "`n"
}

function Test-OneNodeReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-OneNodeRegularFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (-not (Test-OneNodeReparsePoint $Path))
}

# Writes UTF-8 without a BOM (godotenv would read a BOM into the first key)
# through a sibling temporary file so readers never see a partial file.
function Write-OneNodeTextFile {
    param([string]$Path, [string]$Content)
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $name = '.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N')
    $temporary = [System.IO.Path]::Combine($directory, $name)
    try {
        [System.IO.File]::WriteAllText($temporary, $Content, $script:OneNodeUtf8)
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Move-OneNodeFile {
    param([string]$Source, [string]$Destination)
    if ([System.IO.File]::Exists($Destination)) { [System.IO.File]::Delete($Destination) }
    [System.IO.File]::Move($Source, $Destination)
}

# Restores Destination to the backed-up Source, or removes it when the backup
# shows it did not exist.
function Restore-OneNodeOptionalFile {
    param([string]$Source, [string]$Destination)
    if ([System.IO.File]::Exists($Source)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    } elseif ([System.IO.File]::Exists($Destination)) {
        [System.IO.File]::Delete($Destination)
    }
}

function Get-OneNodeFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-OneNodeWorkDirectory {
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('one-node-' + [guid]::NewGuid().ToString('N')))
    $null = [System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-OneNodeWorkDirectory {
    param([string]$Path)
    if (-not $Path) { return }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# godotenv keeps single-quoted values literal, so Windows backslashes survive
# (double quotes would eat them). Single quotes have no escape, and a
# backslash before the closing quote would be read as an escaped quote.
function ConvertTo-OneNodeEnvLine {
    param([string]$Name, [string]$Value)
    if ($Name -cnotmatch '^[A-Z][A-Z0-9_]*\z') { Stop-OneNodeInstaller "invalid environment key: $Name" }
    if ($Value.Contains("'")) { Stop-OneNodeInstaller "$Name must not contain a single quote" }
    if ($Value -match '[\x00-\x1F\x7F]') { Stop-OneNodeInstaller "$Name must be a single line without control characters" }
    if ($Value.EndsWith('\')) { Stop-OneNodeInstaller "$Name must not end with a backslash" }
    return "$Name='$Value'"
}

function Format-OneNodeEnvironment {
    param([System.Collections.IDictionary]$Values)
    $lines = @(foreach ($key in $Values.Keys) { ConvertTo-OneNodeEnvLine -Name $key -Value ([string]$Values[$key]) })
    return (($lines -join "`n") + "`n")
}

function ConvertFrom-OneNodeEnvironment {
    param([string]$Content)
    $values = @{}
    foreach ($line in @(Split-OneNodeLines $Content)) {
        if ($line -cmatch "^([A-Z][A-Z0-9_]*)='([^']*)'\z") { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function New-OneNodeEnvironmentValues {
    param([hashtable]$Paths, [string]$NodeId, [string]$Server)
    $values = [ordered]@{}
    $values['NODE_NODE_ID'] = $NodeId
    $values['NODE_ROLE'] = 'monitor'
    $values['NODE_HEARTBEAT_INTERVAL'] = '60s'
    $values['NODE_STATE_DIR'] = $Paths.StateDir
    $values['NODE_UPGRADE_REQUEST_FILE'] = $Paths.UpgradeRequest
    $values['NODE_UPGRADE_INSTALLER'] = $Paths.Installer
    $values['CONTROL_ADDR'] = $Server
    $values['CONTROL_BOOTSTRAP_ENV_FILE'] = $Paths.BootstrapEnv
    $values['LOG_LEVEL'] = 'info'
    $values['LOG_FILE'] = $Paths.LogFile
    return $values
}

function New-OneNodeManifest {
    param([string]$CurrentVersion, [string]$PreviousVersion, [string]$StateDirectory)
    return @{
        format = $script:OneNodeManifestFormat
        mode = 'service'
        role = 'monitor'
        current_version = $CurrentVersion
        previous_version = $PreviousVersion
        state_dir = $StateDirectory
    }
}

function Format-OneNodeManifest {
    param([hashtable]$Manifest)
    $lines = @(foreach ($key in $script:OneNodeManifestKeys) { '{0}={1}' -f $key, $Manifest[$key] })
    return (($lines -join "`n") + "`n")
}

function ConvertFrom-OneNodeManifest {
    param([string]$Content)
    $manifest = @{}
    foreach ($line in @(Split-OneNodeLines $Content)) {
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { throw "malformed line: $line" }
        $key = $line.Substring(0, $separator)
        if ($script:OneNodeManifestKeys -cnotcontains $key) { throw "unknown field: $key" }
        if ($manifest.ContainsKey($key)) { throw "duplicate field: $key" }
        $manifest[$key] = $line.Substring($separator + 1)
    }
    foreach ($key in $script:OneNodeManifestKeys) {
        if (-not $manifest.ContainsKey($key)) { throw "missing field: $key" }
    }
    if ($manifest['format'] -cne $script:OneNodeManifestFormat) { throw "unsupported format: $($manifest['format'])" }
    if ($manifest['mode'] -cne 'service') { throw "unsupported mode: $($manifest['mode'])" }
    if ($manifest['role'] -cne 'monitor') { throw "unsupported role: $($manifest['role'])" }
    if (-not (Test-OneNodeVersion $manifest['current_version'])) { throw 'current_version is invalid' }
    if ($manifest['previous_version'] -and -not (Test-OneNodeVersion $manifest['previous_version'])) { throw 'previous_version is invalid' }
    if (-not $manifest['state_dir']) { throw 'state_dir is empty' }
    return $manifest
}

function Read-OneNodeManifest {
    param([hashtable]$Paths)
    if (-not (Test-Path -LiteralPath $Paths.Manifest)) {
        Stop-OneNodeInstaller 'One Node installation manifest was not found'
    }
    $problem = ''
    $manifest = $null
    if (Test-OneNodeRegularFile $Paths.Manifest) {
        try {
            $manifest = ConvertFrom-OneNodeManifest -Content ([System.IO.File]::ReadAllText($Paths.Manifest, $script:OneNodeUtf8))
        } catch {
            $problem = $_.Exception.Message
        }
    } else {
        $problem = 'not a regular file'
    }
    if ($problem) {
        Stop-OneNodeInstaller "refusing unknown or unsafe installation manifest $($Paths.Manifest) ($problem); remove it with -Uninstall -Yes"
    }
    if ($manifest['state_dir'] -ne $Paths.StateDir) {
        Stop-OneNodeInstaller "installation manifest records an unexpected state directory: $($manifest['state_dir'])"
    }
    return $manifest
}

function Write-OneNodeManifest {
    param([hashtable]$Paths, [hashtable]$Manifest)
    Write-OneNodeTextFile -Path $Paths.Manifest -Content (Format-OneNodeManifest -Manifest $Manifest)
}

function Get-OneNodeInstalledNodeId {
    param([hashtable]$Paths)
    if (-not (Test-OneNodeRegularFile $Paths.EnvFile)) { return '' }
    $values = ConvertFrom-OneNodeEnvironment -Content ([System.IO.File]::ReadAllText($Paths.EnvFile, $script:OneNodeUtf8))
    $nodeId = [string]$values['NODE_NODE_ID']
    if ($nodeId -cmatch '^[1-9][0-9]{0,18}\z') { return $nodeId }
    return ''
}

# The node writes node-secret atomically; enrollment is complete once it
# names this node and reports the active state.
function Test-OneNodeIdentityDocument {
    param([string]$Json, [string]$NodeId)
    try {
        $document = ConvertFrom-Json -InputObject $Json
    } catch {
        return $false
    }
    if ($null -eq $document) { return $false }
    $idProperty = $document.PSObject.Properties['node_id']
    $stateProperty = $document.PSObject.Properties['state']
    if ($null -eq $idProperty -or $null -eq $stateProperty) { return $false }
    return (($idProperty.Value -is [string]) -and ($idProperty.Value -ceq $NodeId) -and ($stateProperty.Value -ceq 'active'))
}

function Test-OneNodeIdentityActive {
    param([string]$Path, [string]$NodeId)
    if (-not (Test-OneNodeRegularFile $Path)) { return $false }
    try {
        $json = [System.IO.File]::ReadAllText($Path, $script:OneNodeUtf8)
    } catch {
        return $false
    }
    return (Test-OneNodeIdentityDocument -Json $json -NodeId $NodeId)
}

function Test-OneNodeBootstrapTokenPresent {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $content = [System.IO.File]::ReadAllText($Path, $script:OneNodeUtf8)
    return [regex]::IsMatch($content, '(?m)^[\t ]*(export[\t ]+)?CONTROL_BOOTSTRAP_TOKEN[\t ]*=')
}

function Format-OneNodeBytes {
    param([long]$Bytes)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $kib = [Math]::Floor($Bytes / 1024)
    if ($kib -ge 1048576) { return [string]::Format($culture, '{0:0.00} GiB', $kib / 1048576) }
    if ($kib -ge 1024) { return [string]::Format($culture, '{0:0.0} MiB', $kib / 1024) }
    return [string]::Format($culture, '{0} KiB', $kib)
}

# Same shape as ps etime on Linux: [[dd-]hh:]mm:ss.
function Format-OneNodeUptime {
    param([TimeSpan]$Duration)
    if ($Duration -lt [TimeSpan]::Zero) { return '-' }
    $days = [int][Math]::Floor($Duration.TotalDays)
    $clock = '{0:00}:{1:00}:{2:00}' -f $Duration.Hours, $Duration.Minutes, $Duration.Seconds
    if ($days -gt 0) { return "$days-$clock" }
    if ($Duration.Hours -gt 0) { return $clock }
    return ('{0:00}:{1:00}' -f $Duration.Minutes, $Duration.Seconds)
}

# ---------------------------------------------------------------------------
# Upgrade request protocol (port of scripts/install/updater.sh)
# ---------------------------------------------------------------------------

function ConvertFrom-OneNodeUpgradeRequest {
    param([string]$Content)
    $lines = @(Split-OneNodeLines $Content)
    if ($lines.Count -ne 6) { throw 'request has an invalid field count' }
    $request = @{}
    foreach ($line in $lines) {
        if ($line -cmatch '^(command_id|version|state|requested_at|updated_at|message)=(.*)\z') {
            if ($request.ContainsKey($Matches[1])) { throw "request repeats $($Matches[1])" }
            $request[$Matches[1]] = $Matches[2]
        } else {
            throw 'request has an unknown field'
        }
    }
    if ($request['command_id'] -cnotmatch '^[A-Za-z0-9._:-]{1,128}\z') { throw 'command_id is invalid' }
    if (-not (Test-OneNodeVersion $request['version'])) { throw 'version must have exactly three canonical numeric components' }
    if ($request['state'] -cne 'pending') { throw 'request state must be pending' }
    if (-not $request['requested_at'] -or -not $request['updated_at'] -or $request['message']) {
        throw 'request metadata is invalid'
    }
    return $request
}

function Format-OneNodeUpgradeStatus {
    param([hashtable]$Request, [string]$State, [string]$Message, [DateTime]$Time = [DateTime]::UtcNow)
    $text = $Message -replace "[`r`n]", ' '
    if ($text.Length -gt 1000) { $text = $text.Substring(0, 1000) }
    $stamp = $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    $lines = @(
        "command_id=$($Request['command_id'])",
        "version=$($Request['version'])",
        "state=$State",
        "requested_at=$($Request['requested_at'])",
        "updated_at=$stamp",
        "message=$text"
    )
    return (($lines -join "`n") + "`n")
}

function Write-OneNodeUpgradeStatus {
    param([string]$Path, [hashtable]$Request, [string]$State, [string]$Message)
    Write-OneNodeTextFile -Path $Path -Content (Format-OneNodeUpgradeStatus -Request $Request -State $State -Message $Message)
}

# The node reports the last installer error, else the last output line.
function Get-OneNodeUpgradeFailureMessage {
    param([string]$Output)
    $message = ''
    $lastLine = ''
    foreach ($line in @(Split-OneNodeLines $Output)) {
        if ($line -cmatch '^\[one-node\] error: (.*)\z') { $message = $Matches[1] }
        if ($line.Trim() -ne '') { $lastLine = $line }
    }
    if (-not $message) { $message = $lastLine }
    if (-not $message) { $message = 'upgrade failed' }
    $message = $message -replace "[`r`n]", ' '
    if ($message.Length -gt 1000) { $message = $message.Substring(0, 1000) }
    return $message
}

function Remove-OneNodeRequestPath {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Delete($Path)
        } elseif (Test-OneNodeReparsePoint $Path) {
            [System.IO.Directory]::Delete($Path)
        }
    } catch {
        Write-OneNodeWarning "unable to remove ${Path}: $($_.Exception.Message)"
    }
}

function Read-OneNodeUpgradeRequest {
    param([string]$Path)
    try {
        if (-not (Test-OneNodeRegularFile $Path)) { throw 'request is missing or unsafe' }
        return (ConvertFrom-OneNodeUpgradeRequest -Content ([System.IO.File]::ReadAllText($Path, $script:OneNodeUtf8)))
    } catch {
        Write-OneNodeErrorLine "invalid upgrade request: $($_.Exception.Message)"
        Remove-OneNodeRequestPath -Path $Path
        return $null
    }
}

# Runs one queued upgrade in-process and leaves status for the restarted node:
# running, then succeeded or failed with the last installer error.
function Invoke-OneNodeUpgradeRequest {
    param([hashtable]$Paths, [string]$ReleaseBaseUrl = '')
    $requestPath = [System.IO.Path]::Combine($Paths.UpdateDir, 'request')
    $runningPath = [System.IO.Path]::Combine($Paths.UpdateDir, 'request.running')
    $statusPath = [System.IO.Path]::Combine($Paths.UpdateDir, 'status')
    $logPath = [System.IO.Path]::Combine($Paths.UpdateDir, 'last-upgrade.log')
    $request = Read-OneNodeUpgradeRequest -Path $requestPath
    if ($null -eq $request) { return 1 }
    Move-OneNodeFile -Source $requestPath -Destination $runningPath
    Write-OneNodeUpgradeStatus -Path $statusPath -Request $request -State 'running' -Message 'upgrade started'
    $outputPath = [System.IO.Path]::Combine($Paths.UpdateDir, ('.upgrade-output.' + [guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($outputPath, '', $script:OneNodeUtf8)
    $succeeded = $false
    $recorded = $false
    $script:OneNodeCaptureFile = $outputPath
    try {
        try {
            $null = Invoke-OneNodeUpgrade -Paths $Paths -Target $request['version'] -ReleaseBaseUrl $ReleaseBaseUrl
            $succeeded = $true
        } catch {
            Write-OneNodeErrorLine $_.Exception.Message
        }
        $script:OneNodeCaptureFile = $null
        Move-OneNodeFile -Source $outputPath -Destination $logPath
        if ($succeeded) {
            Write-OneNodeUpgradeStatus -Path $statusPath -Request $request -State 'succeeded' -Message 'upgrade completed'
        } else {
            $failure = Get-OneNodeUpgradeFailureMessage -Output ([System.IO.File]::ReadAllText($logPath, $script:OneNodeUtf8))
            Write-OneNodeUpgradeStatus -Path $statusPath -Request $request -State 'failed' -Message $failure
        }
        $recorded = $true
    } finally {
        $script:OneNodeCaptureFile = $null
        if (-not $recorded) {
            try { Write-OneNodeUpgradeStatus -Path $statusPath -Request $request -State 'failed' -Message 'upgrade was interrupted' } catch { }
        }
        Remove-Item -LiteralPath $runningPath, $outputPath -Force -ErrorAction SilentlyContinue
    }
    if ($succeeded) { return 0 }
    return 1
}

# ---------------------------------------------------------------------------
# Release trust
# ---------------------------------------------------------------------------

function Enable-OneNodeTls {
    # Windows PowerShell 5.1 may offer only TLS 1.0/1.1, which GitHub refuses.
    $protocols = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Schannel ships TLS 1.3 from Windows Server 2022 (build 20348); requesting
    # it on older builds can fail every handshake.
    if (([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') -and [Environment]::OSVersion.Version.Build -ge 20348) {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocols
}

function Assert-OneNodeDownloadUri {
    param([string]$Uri)
    if ($Uri -cmatch '^https://') { return }
    if ($script:OneNodeInsecure -and (Test-OneNodeDevelopmentUrl $Uri)) { return }
    Stop-OneNodeInstaller "refusing to download from a non-HTTPS URL: $Uri"
}

function Get-OneNodeResponseUri {
    param($Response)
    $base = $Response.BaseResponse
    if ($null -eq $base) { return '' }
    # HttpWebResponse on Windows PowerShell, HttpResponseMessage on PowerShell 7.
    if ($base.PSObject.Properties['ResponseUri']) { return [string]$base.ResponseUri }
    if ($base.PSObject.Properties['RequestMessage'] -and $null -ne $base.RequestMessage) {
        return [string]$base.RequestMessage.RequestUri
    }
    return ''
}

# API calls never follow redirects; release assets must, because GitHub
# serves them from its object storage. Either way every hop stays on HTTPS.
function Invoke-OneNodeDownload {
    param(
        [string]$Uri,
        [string]$OutFile,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 30,
        [switch]$FollowRedirects
    )
    Assert-OneNodeDownloadUri -Uri $Uri
    $request = @{
        Uri = $Uri
        OutFile = $OutFile
        Headers = $Headers
        UserAgent = $script:OneNodeUserAgent
        TimeoutSec = $TimeoutSec
        UseBasicParsing = $true
        PassThru = $true
        MaximumRedirection = 0
    }
    if ($FollowRedirects) { $request['MaximumRedirection'] = 5 }
    $response = Invoke-WebRequest @request
    if ([int]$response.StatusCode -ne 200) {
        throw "unexpected HTTP status $($response.StatusCode) from $Uri"
    }
    $finalUri = Get-OneNodeResponseUri -Response $response
    if ($finalUri) { Assert-OneNodeDownloadUri -Uri $finalUri }
}

function Invoke-OneNodeApiText {
    param([string]$Uri, [string]$Accept)
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('one-node-api-' + [guid]::NewGuid().ToString('N')))
    try {
        $headers = @{ Accept = $Accept; 'X-GitHub-Api-Version' = '2022-11-28' }
        Invoke-OneNodeDownload -Uri $Uri -OutFile $path -Headers $headers
        return [System.IO.File]::ReadAllText($path, $script:OneNodeUtf8)
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

# Canonical components compare by length, then digit by digit, which avoids
# integer overflow on arbitrarily long numbers.
function Compare-OneNodeVersion {
    param([string]$Left, [string]$Right)
    $leftParts = $Left.Split('.')
    $rightParts = $Right.Split('.')
    for ($index = 0; $index -lt 3; $index++) {
        $a = $leftParts[$index]
        $b = $rightParts[$index]
        if ($a.Length -ne $b.Length) { return [Math]::Sign($a.Length - $b.Length) }
        $order = [string]::CompareOrdinal($a, $b)
        if ($order -ne 0) { return [Math]::Sign($order) }
    }
    return 0
}

# Highest published version, not the most recently created release.
function Select-OneNodeLatestVersion {
    param([string]$ReleasesJson)
    $pattern = '"tag_name"\s*:\s*"one-node-v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"'
    $latest = ''
    foreach ($found in [regex]::Matches($ReleasesJson, $pattern)) {
        $candidate = $found.Groups[1].Value
        if ($latest -eq '' -or (Compare-OneNodeVersion -Left $candidate -Right $latest) -gt 0) { $latest = $candidate }
    }
    return $latest
}

function Resolve-OneNodeLatestVersion {
    $json = ''
    $problem = ''
    try {
        $json = Invoke-OneNodeApiText -Uri "https://api.github.com/repos/$($script:OneNodeRepository)/releases?per_page=100" -Accept 'application/vnd.github+json'
    } catch {
        $problem = $_.Exception.Message
    }
    if ($problem) { Stop-OneNodeInstaller "unable to resolve the latest One Node release: $problem" }
    $version = Select-OneNodeLatestVersion -ReleasesJson $json
    if (-not $version) { Stop-OneNodeInstaller 'latest One Node release was not found' }
    return $version
}

function Resolve-OneNodeTargetVersion {
    param([string]$Target)
    if (-not $Target -or $Target -eq 'latest') { return (Resolve-OneNodeLatestVersion) }
    if (-not (Test-OneNodeVersion $Target)) {
        Stop-OneNodeInstaller 'upgrade version must be an exact three-component numeric version'
    }
    return $Target
}

# The release tag's commit, so the retained installer matches the binary.
function Resolve-OneNodeReleaseCommit {
    param([string]$Version)
    $body = ''
    $problem = ''
    try {
        $body = Invoke-OneNodeApiText -Uri "https://api.github.com/repos/$($script:OneNodeRepository)/commits/one-node-v$Version" -Accept 'application/vnd.github.sha'
    } catch {
        $problem = $_.Exception.Message
    }
    if ($problem) { Stop-OneNodeInstaller "unable to resolve the One Action commit of one-node-v${Version}: $problem" }
    $commit = $body -replace "[`r`n]", ''
    if ($commit -cnotmatch '^[0-9a-f]{40}\z') {
        Stop-OneNodeInstaller 'One Action commit response must be an exact lowercase commit SHA'
    }
    return $commit
}

# RSA-3072 PKCS#1 v1.5 SHA-256 over the exact SHA256SUMS bytes. RSA.Create()
# with ImportParameters works on .NET Framework 4.6+ and .NET 6+ alike.
function Test-OneNodeReleaseSignature {
    param([byte[]]$Data, [byte[]]$Signature)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $parameters = New-Object System.Security.Cryptography.RSAParameters
        $parameters.Modulus = [Convert]::FromBase64String($script:OneNodeReleaseModulus)
        $parameters.Exponent = [Convert]::FromBase64String($script:OneNodeReleaseExponent)
        $rsa.ImportParameters($parameters)
        return [bool]$rsa.VerifyData(
            $Data,
            $Signature,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch {
        # A malformed signature throws on some providers instead of failing.
        return $false
    } finally {
        $rsa.Dispose()
    }
}

# Returns the lowercase digest of Name when SHA256SUMS lists it exactly once.
function Get-OneNodeReleaseHash {
    param([string]$Manifest, [string]$Name)
    $found = @()
    foreach ($line in @(Split-OneNodeLines $Manifest)) {
        if ($line -cmatch '^([0-9A-Fa-f]{64}) [ *](.+)\z' -and $Matches[2] -ceq $Name) {
            $found += $Matches[1].ToLowerInvariant()
        }
    }
    if ($found.Count -ne 1) { return '' }
    return $found[0]
}

function Confirm-OneNodeReleaseFile {
    param([string]$Manifest, [string]$ManifestPath, [string]$File, [string]$Version)
    $expected = Get-OneNodeReleaseHash -Manifest $Manifest -Name $ManifestPath
    if (-not $expected) {
        Invoke-OneNodeTrustFailure "one-node-v$Version does not sign $ManifestPath"
        return
    }
    if ((Get-OneNodeFileSha256 $File) -cne $expected) {
        Invoke-OneNodeTrustFailure "$ManifestPath does not match signed release one-node-v$Version"
    }
}

# Downloads SHA256SUMS and checks its detached RSA signature.
function Get-OneNodeSignedManifest {
    param([string]$BaseUrl, [string]$Version, [string]$WorkDirectory)
    $sumsPath = [System.IO.Path]::Combine($WorkDirectory, 'SHA256SUMS')
    $signaturePath = [System.IO.Path]::Combine($WorkDirectory, 'SHA256SUMS.rsa.sig')
    $problem = ''
    try {
        Invoke-OneNodeDownload -Uri "$BaseUrl/SHA256SUMS" -OutFile $sumsPath -FollowRedirects
    } catch {
        $problem = $_.Exception.Message
    }
    if ($problem) { Stop-OneNodeInstaller "unable to download SHA256SUMS of one-node-v${Version}: $problem" }
    $signed = $true
    try {
        Invoke-OneNodeDownload -Uri "$BaseUrl/SHA256SUMS.rsa.sig" -OutFile $signaturePath -FollowRedirects
    } catch {
        $signed = $false
    }
    if (-not $signed) {
        Invoke-OneNodeTrustFailure "release checksums are unsigned: $BaseUrl/SHA256SUMS.rsa.sig is unavailable"
    } elseif (-not (Test-OneNodeReleaseSignature -Data ([System.IO.File]::ReadAllBytes($sumsPath)) -Signature ([System.IO.File]::ReadAllBytes($signaturePath)))) {
        Invoke-OneNodeTrustFailure "release checksum signature verification failed for $BaseUrl/SHA256SUMS"
    }
    return [System.IO.File]::ReadAllText($sumsPath, $script:OneNodeUtf8)
}

function Test-OneNodeScriptSyntax {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    return (@($errors).Count -eq 0)
}

# Retains the install.ps1 of the selected release: this very file when its
# hash is the signed one, otherwise the copy at the release tag's commit.
function Get-OneNodeReleaseInstaller {
    param([string]$Version, [string]$Manifest, [string]$WorkDirectory, [string]$ReleaseBaseUrl)
    $target = [System.IO.Path]::Combine($WorkDirectory, 'install.ps1')
    $expected = Get-OneNodeReleaseHash -Manifest $Manifest -Name 'node/install.ps1'
    $self = $script:OneNodeScriptPath
    $selfAvailable = [bool]($self -and (Test-OneNodeRegularFile $self))
    if ($expected -and $selfAvailable -and (Get-OneNodeFileSha256 $self) -ceq $expected) {
        Copy-Item -LiteralPath $self -Destination $target
        return $target
    }
    if ($ReleaseBaseUrl) {
        # A local development release is not published on GitHub.
        if (-not $selfAvailable) { Stop-OneNodeInstaller 'run install.ps1 from a file so it can be retained' }
        Invoke-OneNodeTrustFailure 'node/install.ps1 is not signed by the local development release'
        Copy-Item -LiteralPath $self -Destination $target
        return $target
    }
    $commit = Resolve-OneNodeReleaseCommit -Version $Version
    $problem = ''
    try {
        Invoke-OneNodeDownload -Uri "https://raw.githubusercontent.com/$($script:OneNodeRepository)/$commit/node/install.ps1" -OutFile $target
    } catch {
        $problem = $_.Exception.Message
    }
    if ($problem) { Stop-OneNodeInstaller "unable to download the persistent installer: $problem" }
    if (-not (Test-OneNodeScriptSyntax $target)) { Stop-OneNodeInstaller 'downloaded persistent installer has invalid syntax' }
    Confirm-OneNodeReleaseFile -Manifest $Manifest -ManifestPath 'node/install.ps1' -File $target -Version $Version
    return $target
}

function Get-OneNodeBinaryVersion {
    param([string]$Path)
    $result = Invoke-OneNodeNative -FilePath $Path -ArgumentList @('version', '--product-name')
    if ($result.ExitCode -ne 0) { return '' }
    $lines = @($result.Output | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -ne 1) { return '' }
    return $lines[0].Trim()
}

# Downloads and verifies the binary and installer of one release into
# WorkDirectory before anything on the host changes.
function Get-OneNodeVerifiedRelease {
    param([string]$Version, [string]$Architecture, [string]$WorkDirectory, [string]$ReleaseBaseUrl = '')
    $baseUrl = $ReleaseBaseUrl
    if (-not $baseUrl) {
        $baseUrl = "https://github.com/$($script:OneNodeRepository)/releases/download/one-node-v$Version"
    }
    $manifest = Get-OneNodeSignedManifest -BaseUrl $baseUrl -Version $Version -WorkDirectory $WorkDirectory
    $binaryName = "one-node-windows-$Architecture.exe"
    $expected = Get-OneNodeReleaseHash -Manifest $manifest -Name $binaryName
    if (-not $expected) { Stop-OneNodeInstaller "release checksum is missing $binaryName" }
    $binaryPath = [System.IO.Path]::Combine($WorkDirectory, 'one-node.exe')
    Write-OneNodeLog "downloading $binaryName"
    $problem = ''
    try {
        Invoke-OneNodeDownload -Uri "$baseUrl/$binaryName" -OutFile $binaryPath -FollowRedirects -TimeoutSec 600
    } catch {
        $problem = $_.Exception.Message
    }
    if ($problem) { Stop-OneNodeInstaller "unable to download ${binaryName}: $problem" }
    if ((Get-OneNodeFileSha256 $binaryPath) -cne $expected) {
        Stop-OneNodeInstaller "binary SHA256 verification failed for $binaryName"
    }
    $reported = Get-OneNodeBinaryVersion -Path $binaryPath
    if ($reported -cne $Version) {
        Stop-OneNodeInstaller "downloaded binary reports One Node version '$reported' instead of requested release $Version"
    }
    $installer = Get-OneNodeReleaseInstaller -Version $Version -Manifest $manifest -WorkDirectory $WorkDirectory -ReleaseBaseUrl $ReleaseBaseUrl
    return @{ Version = $Version; Binary = $binaryPath; Installer = $installer }
}

# ---------------------------------------------------------------------------
# Windows host
# ---------------------------------------------------------------------------

# Windows PowerShell turns native stderr into terminating errors while
# ErrorActionPreference is Stop; native failures stay in the exit code here.
function Invoke-OneNodeNative {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [switch]$MergeError)
    $ErrorActionPreference = 'Continue'
    try {
        if ($MergeError) {
            $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        } else {
            $output = @(& $FilePath @ArgumentList 2>$null | ForEach-Object { [string]$_ })
        }
        return @{ ExitCode = [int]$LASTEXITCODE; Output = $output }
    } catch {
        return @{ ExitCode = -1; Output = @([string]$_.Exception.Message) }
    }
}

function Invoke-OneNodeSc {
    param([string[]]$Arguments)
    $sc = [System.IO.Path]::Combine([Environment]::SystemDirectory, 'sc.exe')
    return (Invoke-OneNodeNative -FilePath $sc -ArgumentList $Arguments -MergeError)
}

function Format-OneNodeNativeOutput {
    param([hashtable]$Result)
    return ((@($Result.Output) -join ' ') -replace '\s+', ' ').Trim()
}

function Assert-OneNodeWindows {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Stop-OneNodeInstaller 'install.ps1 manages Windows hosts; use install.sh on Linux'
    }
    if ([Environment]::OSVersion.Version.Build -lt 14393) {
        Stop-OneNodeInstaller 'One Node requires Windows Server 2016 or newer'
    }
}

function Assert-OneNodeAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-OneNodeInstaller 'install.ps1 must run as Administrator; open PowerShell with "Run as administrator" and retry'
    }
}

function ConvertTo-OneNodeArchitecture {
    param([string]$Wow64Architecture, [string]$ProcessorArchitecture)
    # A 32-bit PowerShell on 64-bit Windows reports the real CPU in the WOW64 variable.
    $value = $Wow64Architecture
    if (-not $value) { $value = $ProcessorArchitecture }
    if ($value -ceq 'AMD64') { return 'amd64' }
    if ($value -ceq 'ARM64') { return 'arm64' }
    if (-not $value) { $value = 'unknown' }
    Stop-OneNodeInstaller "unsupported Windows architecture: $value; One Node supports AMD64 and ARM64"
}

function Get-OneNodeArchitecture {
    return (ConvertTo-OneNodeArchitecture -Wow64Architecture $env:PROCESSOR_ARCHITEW6432 -ProcessorArchitecture $env:PROCESSOR_ARCHITECTURE)
}

function Get-OneNodeProgramFilesRoot {
    # A 32-bit PowerShell sees Program Files (x86) as ProgramFiles.
    if ($env:ProgramW6432) { return $env:ProgramW6432 }
    return $env:ProgramFiles
}

function Get-OneNodePaths {
    param([string]$ProgramRoot = (Get-OneNodeProgramFilesRoot), [string]$DataRoot = $env:ProgramData)
    if (-not $ProgramRoot -or -not $DataRoot) { Stop-OneNodeInstaller 'ProgramFiles and ProgramData must be set' }
    $program = [System.IO.Path]::Combine($ProgramRoot, 'OneNode')
    $previous = [System.IO.Path]::Combine($program, 'previous')
    $data = [System.IO.Path]::Combine($DataRoot, 'OneNode')
    $state = [System.IO.Path]::Combine($data, 'state')
    $update = [System.IO.Path]::Combine($state, 'update')
    $logs = [System.IO.Path]::Combine($data, 'logs')
    return @{
        ProgramDir = $program
        Binary = [System.IO.Path]::Combine($program, 'one-node.exe')
        Installer = [System.IO.Path]::Combine($program, 'install.ps1')
        PreviousDir = $previous
        PreviousBinary = [System.IO.Path]::Combine($previous, 'one-node.exe')
        PreviousInstaller = [System.IO.Path]::Combine($previous, 'install.ps1')
        DataDir = $data
        EnvFile = [System.IO.Path]::Combine($data, 'one-node.env')
        Manifest = [System.IO.Path]::Combine($data, 'installation')
        StateDir = $state
        BootstrapEnv = [System.IO.Path]::Combine($state, 'bootstrap.env')
        IdentityFile = [System.IO.Path]::Combine($state, 'node-secret')
        UpdateDir = $update
        UpgradeRequest = [System.IO.Path]::Combine($update, 'request')
        LogsDir = $logs
        LogFile = [System.IO.Path]::Combine($logs, 'one-node.log')
    }
}

function Assert-OneNodeSafeLocations {
    param([hashtable]$Paths)
    foreach ($path in @($Paths.ProgramDir, $Paths.DataDir, $Paths.StateDir)) {
        # Windows PowerShell's recursive Remove-Item follows junctions.
        if (Test-OneNodeReparsePoint $path) {
            Stop-OneNodeInstaller "$path must not be a symbolic link or junction"
        }
    }
}

# Names are localized on non-English Windows; well-known SIDs are not.
function Set-OneNodeOwnerOnlyAcl {
    param([string]$Path)
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in $script:OneNodeTrustedSids) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Test-OneNodeOwnerOnlyAcl {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($script:OneNodeTrustedSids -notcontains $rule.IdentityReference.Value) { return $false }
    }
    return $true
}

function Unblock-OneNodeFile {
    param([string]$Path)
    try { Unblock-File -LiteralPath $Path } catch { }
}

# Service controllers are disposed at once: a lingering handle keeps a
# deleted service "marked for deletion" until this process exits.
function Get-OneNodeServiceStatus {
    $service = Get-Service -Name $script:OneNodeServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) { return $null }
    try { return [string]$service.Status } finally { $service.Dispose() }
}

function Get-OneNodeServiceProcessId {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($script:OneNodeServiceName)'" -ErrorAction SilentlyContinue
    if ($null -eq $service) { return 0 }
    return [int]$service.ProcessId
}

function Wait-OneNodeServiceStatus {
    param([string]$Status, [int]$TimeoutSeconds)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ((Get-OneNodeServiceStatus) -eq $Status) { return $true }
        Start-Sleep -Milliseconds 500
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $false
}

function Wait-OneNodeServiceRemoved {
    param([int]$TimeoutSeconds)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($null -eq (Get-OneNodeServiceStatus)) { return $true }
        Start-Sleep -Milliseconds 500
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $false
}

function Format-OneNodeServiceCommand {
    param([hashtable]$Paths)
    return ('"{0}" start --env-file "{1}" --env-file "{2}"' -f $Paths.Binary, $Paths.EnvFile, $Paths.BootstrapEnv)
}

function New-OneNodeService {
    param([hashtable]$Paths)
    $problem = ''
    try {
        $service = New-Service -Name $script:OneNodeServiceName -BinaryPathName (Format-OneNodeServiceCommand -Paths $Paths) `
            -DisplayName 'One Node' -Description 'One Node monitor agent' -StartupType Automatic
        $service.Dispose()
    } catch {
        $problem = $_.Exception.Message
    }
    if ($problem) { Stop-OneNodeInstaller "unable to create the OneNode service: $problem" }
    $failure = Invoke-OneNodeSc -Arguments @('failure', $script:OneNodeServiceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/10000/restart/30000')
    if ($failure.ExitCode -ne 0) { Stop-OneNodeInstaller "unable to configure OneNode service recovery: $(Format-OneNodeNativeOutput $failure)" }
    $flag = Invoke-OneNodeSc -Arguments @('failureflag', $script:OneNodeServiceName, '1')
    if ($flag.ExitCode -ne 0) { Stop-OneNodeInstaller "unable to configure OneNode service recovery: $(Format-OneNodeNativeOutput $flag)" }
}

function Start-OneNodeService {
    $result = Invoke-OneNodeSc -Arguments @('start', $script:OneNodeServiceName)
    # 1056: the service is already running.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1056) {
        Stop-OneNodeInstaller "unable to start the OneNode service: $(Format-OneNodeNativeOutput $result)"
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 60) {
        $status = Get-OneNodeServiceStatus
        if ($status -eq 'Running') { return }
        if ($null -eq $status -or $status -eq 'Stopped') { Stop-OneNodeInstaller 'the OneNode service stopped during startup' }
        Start-Sleep -Milliseconds 500
    }
    Stop-OneNodeInstaller 'the OneNode service did not reach the Running state within 60s'
}

function Stop-OneNodeService {
    $status = Get-OneNodeServiceStatus
    if ($null -eq $status -or $status -eq 'Stopped') { return }
    $processId = Get-OneNodeServiceProcessId
    # The resulting state is checked below; sc.exe reports races as errors.
    $null = Invoke-OneNodeSc -Arguments @('stop', $script:OneNodeServiceName)
    if (-not (Wait-OneNodeServiceStatus -Status 'Stopped' -TimeoutSeconds 30)) {
        if ($processId -gt 0) {
            Write-OneNodeWarning "the OneNode service did not stop within 30s; terminating process $processId"
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        if (-not (Wait-OneNodeServiceStatus -Status 'Stopped' -TimeoutSeconds 15)) {
            Stop-OneNodeInstaller 'the OneNode service did not stop'
        }
    }
    # The executable stays locked until the process has exited.
    if ($processId -gt 0) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -ne $process -and -not $process.WaitForExit(15000)) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
    }
}

# Returns $false when the service still exists, marked for deletion.
function Remove-OneNodeService {
    if ($null -eq (Get-OneNodeServiceStatus)) { return $true }
    Stop-OneNodeService
    $result = Invoke-OneNodeSc -Arguments @('delete', $script:OneNodeServiceName)
    # 1060: does not exist; 1072: already marked for deletion.
    if (@(0, 1060, 1072) -notcontains $result.ExitCode) {
        Stop-OneNodeInstaller "unable to delete the OneNode service: $(Format-OneNodeNativeOutput $result)"
    }
    return (Wait-OneNodeServiceRemoved -TimeoutSeconds 30)
}

function Remove-OneNodeDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-OneNodeReparsePoint $Path) { Stop-OneNodeInstaller "$Path must not be a symbolic link or junction" }
    for ($attempt = 1; $true; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force
            return
        } catch {
            # Antivirus scanners and exiting processes hold files briefly.
            if ($attempt -ge 5) { Stop-OneNodeInstaller "unable to remove ${Path}: $($_.Exception.Message)" }
            Start-Sleep -Seconds 1
        }
    }
}

function Test-OneNodeInstallationPresent {
    param([hashtable]$Paths)
    if ($null -ne (Get-OneNodeServiceStatus)) { return $true }
    return ((Test-Path -LiteralPath $Paths.ProgramDir) -or (Test-Path -LiteralPath $Paths.DataDir))
}

# Removes the service, program files and all runtime state.
function Remove-OneNodeInstallation {
    param([hashtable]$Paths, [switch]$RequireServiceDeleted)
    # Windows cannot delete a directory that is a process's working directory.
    $location = [string](Get-Location).ProviderPath
    foreach ($directory in @($Paths.ProgramDir, $Paths.DataDir)) {
        if ($location.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase)) {
            Set-Location -LiteralPath $env:SystemRoot
        }
    }
    [Environment]::CurrentDirectory = $env:SystemRoot
    if (-not (Remove-OneNodeService)) {
        if ($RequireServiceDeleted) {
            Stop-OneNodeInstaller 'the OneNode service is still marked for deletion; close the Services console and retry'
        }
        Write-OneNodeWarning 'the OneNode service is marked for deletion and disappears once open handles close'
    }
    Remove-OneNodeDirectory -Path $Paths.ProgramDir
    Remove-OneNodeDirectory -Path $Paths.DataDir
}

function New-OneNodeLayout {
    param([hashtable]$Paths)
    $null = [System.IO.Directory]::CreateDirectory($Paths.ProgramDir)
    $null = [System.IO.Directory]::CreateDirectory($Paths.DataDir)
    # The bootstrap token and node identity live here; lock it before writing them.
    Set-OneNodeOwnerOnlyAcl -Path $Paths.DataDir
    foreach ($directory in @($Paths.StateDir, $Paths.UpdateDir, $Paths.LogsDir)) {
        $null = [System.IO.Directory]::CreateDirectory($directory)
    }
}

# Uses a script-level lock so the node's upgrade request and an operator never
# change the installation at the same time.
function Wait-OneNodeMutex {
    param([System.Threading.Mutex]$Mutex, [TimeSpan]$Timeout)
    try {
        return $Mutex.WaitOne($Timeout)
    } catch {
        $exception = $_.Exception
        while ($null -ne $exception) {
            # The previous holder exited without releasing it; ownership passes to us.
            if ($exception -is [System.Threading.AbandonedMutexException]) { return $true }
            $exception = $exception.InnerException
        }
        throw
    }
}

function Invoke-OneNodeLocked {
    param([scriptblock]$Action)
    $lockMutex = New-Object System.Threading.Mutex($false, $script:OneNodeMutexName)
    $lockAcquired = $false
    try {
        $lockAcquired = Wait-OneNodeMutex -Mutex $lockMutex -Timeout ([TimeSpan]::Zero)
        if (-not $lockAcquired) {
            Write-OneNodeLog 'waiting for another One Node lifecycle operation to finish'
            $lockAcquired = Wait-OneNodeMutex -Mutex $lockMutex -Timeout ([TimeSpan]::FromMinutes(10))
        }
        if (-not $lockAcquired) { Stop-OneNodeInstaller 'another One Node lifecycle operation is still running' }
        & $Action
    } finally {
        if ($lockAcquired) { $lockMutex.ReleaseMutex() }
        $lockMutex.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------

function Write-OneNodeRecentLogs {
    param([hashtable]$Paths, [int]$Lines = 120)
    if (-not (Test-OneNodeRegularFile $Paths.LogFile)) {
        Write-OneNodeWarning "no One Node log was written to $($Paths.LogFile); check the System event log for Service Control Manager errors"
        return
    }
    Write-OneNodeLog 'recent One Node logs:'
    try {
        foreach ($line in @(Get-Content -LiteralPath $Paths.LogFile -Tail $Lines -Encoding UTF8)) {
            [Console]::Error.WriteLine($line)
        }
    } catch {
        Write-OneNodeWarning "unable to read $($Paths.LogFile): $($_.Exception.Message)"
    }
}

function Wait-OneNodeEnrollment {
    param([hashtable]$Paths, [string]$NodeId, [string]$Server, [int]$TimeoutSeconds)
    Write-OneNodeLog "waiting up to ${TimeoutSeconds}s for node $NodeId to become ready"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $status = Get-OneNodeServiceStatus
        if ($null -eq $status -or $status -eq 'Stopped') {
            Stop-OneNodeInstaller 'the OneNode service stopped before enrollment became ready'
        }
        # The node removes the token line once its identity is stored.
        if ((Test-OneNodeIdentityActive -Path $Paths.IdentityFile -NodeId $NodeId) -and
            -not (Test-OneNodeBootstrapTokenPresent -Path $Paths.BootstrapEnv)) {
            return
        }
        Start-Sleep -Seconds 1
    }
    Stop-OneNodeInstaller "Node registration did not complete through $Server; verify that the public gRPC route reaches the One Node control listener"
}

# Healthy means the service kept running (the recovery restart would show as
# a state change) and the stored identity is still active.
function Test-OneNodeStaysHealthy {
    param([hashtable]$Paths, [string]$NodeId)
    Write-OneNodeLog "checking that One Node stays running for $($script:OneNodeHealthSeconds)s"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $script:OneNodeHealthSeconds) {
        if ((Get-OneNodeServiceStatus) -ne 'Running') { return $false }
        Start-Sleep -Seconds 1
    }
    if ((Get-OneNodeServiceStatus) -ne 'Running') { return $false }
    return (Test-OneNodeIdentityActive -Path $Paths.IdentityFile -NodeId $NodeId)
}

function Get-OneNodeRequiredNodeId {
    param([hashtable]$Paths)
    $nodeId = Get-OneNodeInstalledNodeId -Paths $Paths
    if (-not $nodeId) { Stop-OneNodeInstaller "the installed node id is missing from $($Paths.EnvFile)" }
    return $nodeId
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

function Show-OneNodeInstallSummary {
    param([hashtable]$Paths, [string]$Version, [string]$NodeId)
    Write-OneNodeLog "One Node $Version is running in monitor mode as node $NodeId"
    Write-OneNodeLog 'manage it from an elevated PowerShell:'
    foreach ($command in @('-Status', '-Doctor', '-Upgrade latest', '-Rollback', '-Restart', '-Logs -Follow', '-Uninstall -Yes')) {
        [Console]::Out.WriteLine(('  & "{0}" {1}' -f $Paths.Installer, $command))
    }
}

# The new install command is authoritative: once its artifacts are verified,
# any existing installation and its runtime state are replaced.
function Install-OneNode {
    param([hashtable]$Paths, [hashtable]$Config)
    Assert-OneNodeSafeLocations -Paths $Paths
    # Render before changing anything so invalid values fail early.
    $environment = Format-OneNodeEnvironment -Values (New-OneNodeEnvironmentValues -Paths $Paths -NodeId $Config.NodeId -Server $Config.Server)
    $bootstrap = Format-OneNodeEnvironment -Values ([ordered]@{ CONTROL_BOOTSTRAP_TOKEN = $Config.Token })
    if ($Config.Reset) {
        Write-OneNodeLog 'removing the existing One Node installation and runtime state'
        Remove-OneNodeInstallation -Paths $Paths -RequireServiceDeleted
    } elseif (Test-Path -LiteralPath $Paths.Manifest) {
        # Refuse to replace an installation this installer did not write.
        $null = Read-OneNodeManifest -Paths $Paths
    }
    Enable-OneNodeTls
    $architecture = Get-OneNodeArchitecture
    $version = $Config.Version
    if (-not $version) {
        $version = Resolve-OneNodeLatestVersion
        Write-OneNodeLog "using latest published One Node version $version"
    }
    $manifest = Format-OneNodeManifest -Manifest (New-OneNodeManifest -CurrentVersion $version -PreviousVersion '' -StateDirectory $Paths.StateDir)
    $work = New-OneNodeWorkDirectory
    $created = $false
    $committed = $false
    try {
        $release = Get-OneNodeVerifiedRelease -Version $version -Architecture $architecture -WorkDirectory $work -ReleaseBaseUrl $Config.ReleaseBaseUrl
        if (Test-OneNodeInstallationPresent -Paths $Paths) {
            Write-OneNodeLog 'removing the existing One Node installation and runtime state'
            Remove-OneNodeInstallation -Paths $Paths -RequireServiceDeleted
        }
        $created = $true
        Write-OneNodeLog "installing One Node $version in monitor mode"
        New-OneNodeLayout -Paths $Paths
        Copy-Item -LiteralPath $release.Binary -Destination $Paths.Binary
        Copy-Item -LiteralPath $release.Installer -Destination $Paths.Installer
        Unblock-OneNodeFile -Path $Paths.Installer
        Write-OneNodeTextFile -Path $Paths.EnvFile -Content $environment
        # The node deletes the token line after enrollment but keeps the file,
        # which the service command line always loads.
        Write-OneNodeTextFile -Path $Paths.BootstrapEnv -Content $bootstrap
        Write-OneNodeTextFile -Path $Paths.Manifest -Content $manifest
        New-OneNodeService -Paths $Paths
        Write-OneNodeLog 'starting the OneNode service'
        Start-OneNodeService
        Wait-OneNodeEnrollment -Paths $Paths -NodeId $Config.NodeId -Server $Config.Server -TimeoutSeconds $Config.EnrollTimeout
        $committed = $true
    } catch {
        if ($created) { Write-OneNodeRecentLogs -Paths $Paths -Lines 120 }
        throw
    } finally {
        if ($created -and -not $committed) {
            Write-OneNodeLog 'installation did not become ready; removing everything this run created'
            try {
                Remove-OneNodeInstallation -Paths $Paths
            } catch {
                Write-OneNodeWarning "partial installation cleanup failed: $($_.Exception.Message)"
            }
        }
        Remove-OneNodeWorkDirectory -Path $work
    }
    Show-OneNodeInstallSummary -Paths $Paths -Version $version -NodeId $Config.NodeId
}

function Backup-OneNodeProgramFiles {
    param([hashtable]$Paths, [string]$Destination)
    $previous = [System.IO.Path]::Combine($Destination, 'previous')
    $null = [System.IO.Directory]::CreateDirectory($previous)
    $pairs = @(
        @($Paths.Binary, [System.IO.Path]::Combine($Destination, 'one-node.exe')),
        @($Paths.Installer, [System.IO.Path]::Combine($Destination, 'install.ps1')),
        @($Paths.PreviousBinary, [System.IO.Path]::Combine($previous, 'one-node.exe')),
        @($Paths.PreviousInstaller, [System.IO.Path]::Combine($previous, 'install.ps1')),
        @($Paths.Manifest, [System.IO.Path]::Combine($Destination, 'installation'))
    )
    foreach ($pair in $pairs) {
        if ([System.IO.File]::Exists($pair[0])) { Copy-Item -LiteralPath $pair[0] -Destination $pair[1] }
    }
}

# Puts back exactly what Backup-OneNodeProgramFiles saw, however far the
# switch got, and restarts that version.
function Restore-OneNodeProgramFiles {
    param([hashtable]$Paths, [string]$Backup)
    $previous = [System.IO.Path]::Combine($Backup, 'previous')
    Stop-OneNodeService
    Copy-Item -LiteralPath ([System.IO.Path]::Combine($Backup, 'one-node.exe')) -Destination $Paths.Binary -Force
    Restore-OneNodeOptionalFile -Source ([System.IO.Path]::Combine($Backup, 'install.ps1')) -Destination $Paths.Installer
    Restore-OneNodeOptionalFile -Source ([System.IO.Path]::Combine($previous, 'one-node.exe')) -Destination $Paths.PreviousBinary
    Restore-OneNodeOptionalFile -Source ([System.IO.Path]::Combine($previous, 'install.ps1')) -Destination $Paths.PreviousInstaller
    $manifest = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($Backup, 'installation'), $script:OneNodeUtf8)
    Write-OneNodeTextFile -Path $Paths.Manifest -Content $manifest
    Start-OneNodeService
}

function Switch-OneNodeProgramFiles {
    param([hashtable]$Paths, [hashtable]$Release, [hashtable]$Manifest)
    $null = [System.IO.Directory]::CreateDirectory($Paths.PreviousDir)
    Move-OneNodeFile -Source $Paths.Binary -Destination $Paths.PreviousBinary
    if ([System.IO.File]::Exists($Paths.Installer)) {
        Move-OneNodeFile -Source $Paths.Installer -Destination $Paths.PreviousInstaller
    } elseif ([System.IO.File]::Exists($Paths.PreviousInstaller)) {
        [System.IO.File]::Delete($Paths.PreviousInstaller)
    }
    Copy-Item -LiteralPath $Release.Binary -Destination $Paths.Binary
    Copy-Item -LiteralPath $Release.Installer -Destination $Paths.Installer
    Unblock-OneNodeFile -Path $Paths.Installer
    $next = New-OneNodeManifest -CurrentVersion $Release.Version -PreviousVersion $Manifest['current_version'] -StateDirectory $Paths.StateDir
    Write-OneNodeManifest -Paths $Paths -Manifest $next
}

# Keeps identity and state; a target that does not stay healthy is replaced
# by the exact previous files again.
function Invoke-OneNodeUpgrade {
    param([hashtable]$Paths, [string]$Target = 'latest', [string]$ReleaseBaseUrl = '')
    Assert-OneNodeSafeLocations -Paths $Paths
    $manifest = Read-OneNodeManifest -Paths $Paths
    $nodeId = Get-OneNodeRequiredNodeId -Paths $Paths
    Enable-OneNodeTls
    $version = Resolve-OneNodeTargetVersion -Target $Target
    $current = $manifest['current_version']
    if ($version -ceq $current) { Stop-OneNodeInstaller "upgrade target $version is already current" }
    $architecture = Get-OneNodeArchitecture
    $work = New-OneNodeWorkDirectory
    try {
        $release = Get-OneNodeVerifiedRelease -Version $version -Architecture $architecture -WorkDirectory $work -ReleaseBaseUrl $ReleaseBaseUrl
        $backup = [System.IO.Path]::Combine($work, 'backup')
        Backup-OneNodeProgramFiles -Paths $Paths -Destination $backup
        Write-OneNodeLog "upgrading One Node $current to $version"
        Stop-OneNodeService
        $failure = ''
        try {
            Switch-OneNodeProgramFiles -Paths $Paths -Release $release -Manifest $manifest
            Start-OneNodeService
            if (-not (Test-OneNodeStaysHealthy -Paths $Paths -NodeId $nodeId)) {
                throw "One Node $version did not stay running with an active identity"
            }
        } catch {
            $failure = $_.Exception.Message
        }
        if ($failure) {
            Write-OneNodeRecentLogs -Paths $Paths -Lines 120
            Write-OneNodeLog "upgrade failed after switching; restoring One Node $current"
            $restoreProblem = ''
            try {
                Restore-OneNodeProgramFiles -Paths $Paths -Backup $backup
                if (-not (Test-OneNodeStaysHealthy -Paths $Paths -NodeId $nodeId)) {
                    $restoreProblem = "restored One Node $current did not stay running with an active identity"
                }
            } catch {
                $restoreProblem = $_.Exception.Message
            }
            if ($restoreProblem) {
                Stop-OneNodeInstaller "upgrade to $version failed ($failure) and automatic rollback failed: $restoreProblem"
            }
            Stop-OneNodeInstaller "upgrade to $version failed and One Node $current was restored: $failure"
        }
    } finally {
        Remove-OneNodeWorkDirectory -Path $work
    }
    Write-OneNodeLog "upgrade to $version is ready"
}

function Invoke-OneNodeRollback {
    param([hashtable]$Paths)
    Assert-OneNodeSafeLocations -Paths $Paths
    $manifest = Read-OneNodeManifest -Paths $Paths
    $current = $manifest['current_version']
    $previous = $manifest['previous_version']
    if (-not $previous) { Stop-OneNodeInstaller 'installation manifest has no previous version' }
    if (-not (Test-OneNodeRegularFile $Paths.PreviousBinary)) { Stop-OneNodeInstaller "previous binary is missing: $($Paths.PreviousBinary)" }
    $reported = Get-OneNodeBinaryVersion -Path $Paths.PreviousBinary
    if ($reported -cne $previous) { Stop-OneNodeInstaller "previous binary reports version '$reported' instead of $previous" }
    $nodeId = Get-OneNodeRequiredNodeId -Paths $Paths
    $work = New-OneNodeWorkDirectory
    try {
        $swapBinary = [System.IO.Path]::Combine($work, 'one-node.exe')
        $swapInstaller = [System.IO.Path]::Combine($work, 'install.ps1')
        Copy-Item -LiteralPath $Paths.Binary -Destination $swapBinary
        if ([System.IO.File]::Exists($Paths.Installer)) { Copy-Item -LiteralPath $Paths.Installer -Destination $swapInstaller }
        Write-OneNodeLog "rolling back One Node $current to $previous"
        Stop-OneNodeService
        Move-OneNodeFile -Source $Paths.PreviousBinary -Destination $Paths.Binary
        if (Test-OneNodeRegularFile $Paths.PreviousInstaller) {
            Move-OneNodeFile -Source $Paths.PreviousInstaller -Destination $Paths.Installer
        } else {
            Write-OneNodeWarning 'the previous install.ps1 is missing; keeping the current installer'
        }
        Copy-Item -LiteralPath $swapBinary -Destination $Paths.PreviousBinary -Force
        Restore-OneNodeOptionalFile -Source $swapInstaller -Destination $Paths.PreviousInstaller
        Write-OneNodeManifest -Paths $Paths -Manifest (New-OneNodeManifest -CurrentVersion $previous -PreviousVersion $current -StateDirectory $Paths.StateDir)
        Start-OneNodeService
        if (-not (Test-OneNodeStaysHealthy -Paths $Paths -NodeId $nodeId)) {
            Write-OneNodeRecentLogs -Paths $Paths -Lines 120
            Stop-OneNodeInstaller "rolled-back One Node $previous did not stay running with an active identity"
        }
    } finally {
        Remove-OneNodeWorkDirectory -Path $work
    }
    Write-OneNodeLog "rollback to $previous is ready"
}

function Restart-OneNode {
    param([hashtable]$Paths)
    $null = Read-OneNodeManifest -Paths $Paths
    Stop-OneNodeService
    Start-OneNodeService
    Show-OneNodeStatus -Paths $Paths
}

function Uninstall-OneNode {
    param([hashtable]$Paths)
    Assert-OneNodeSafeLocations -Paths $Paths
    Write-OneNodeLog 'removing the OneNode service, program files and runtime state'
    Remove-OneNodeInstallation -Paths $Paths
    Write-OneNodeLog 'One Node and all runtime state were removed'
}

# ---------------------------------------------------------------------------
# Management
# ---------------------------------------------------------------------------

function Get-OneNodeServiceDetails {
    $details = @{ State = 'not installed'; ProcessId = '-'; Memory = '-'; Uptime = '-' }
    $status = Get-OneNodeServiceStatus
    if ($null -eq $status) { return $details }
    $details.State = $status
    $processId = Get-OneNodeServiceProcessId
    if ($processId -le 0) { return $details }
    $details.ProcessId = [string]$processId
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $details }
    $details.Memory = Format-OneNodeBytes -Bytes $process.WorkingSet64
    try { $details.Uptime = Format-OneNodeUptime -Duration ((Get-Date) - $process.StartTime) } catch { }
    return $details
}

function Show-OneNodeStatus {
    param([hashtable]$Paths)
    $manifest = Read-OneNodeManifest -Paths $Paths
    $details = Get-OneNodeServiceDetails
    $nodeId = Get-OneNodeInstalledNodeId -Paths $Paths
    if (-not $nodeId) { $nodeId = '-' }
    $previous = $manifest['previous_version']
    if (-not $previous) { $previous = '-' }
    $lines = @(
        'One Node status',
        "  mode:             $($manifest['mode'])",
        "  role:             $($manifest['role'])",
        "  version:          $($manifest['current_version'])",
        "  previous version: $previous",
        "  node id:          $nodeId",
        "  state:            $($details.State)",
        "  pid:              $($details.ProcessId)",
        "  memory:           $($details.Memory)",
        "  uptime:           $($details.Uptime)"
    )
    foreach ($line in $lines) { [Console]::Out.WriteLine($line) }
}

function Invoke-OneNodeDoctor {
    param([hashtable]$Paths)
    Show-OneNodeStatus -Paths $Paths
    $status = Get-OneNodeServiceStatus
    if ($null -eq $status) { Stop-OneNodeInstaller 'the OneNode service is missing' }
    if ($status -ne 'Running') { Stop-OneNodeInstaller "the OneNode service is $status, not Running" }
    if (-not (Test-OneNodeRegularFile $Paths.EnvFile)) { Stop-OneNodeInstaller "environment file is missing or unsafe: $($Paths.EnvFile)" }
    if (-not (Test-OneNodeRegularFile $Paths.BootstrapEnv)) { Stop-OneNodeInstaller "bootstrap environment file is missing or unsafe: $($Paths.BootstrapEnv)" }
    if (-not (Test-Path -LiteralPath $Paths.StateDir -PathType Container) -or (Test-OneNodeReparsePoint $Paths.StateDir)) {
        Stop-OneNodeInstaller "state directory is missing or unsafe: $($Paths.StateDir)"
    }
    if (-not (Test-OneNodeOwnerOnlyAcl -Path $Paths.DataDir)) {
        Stop-OneNodeInstaller "$($Paths.DataDir) must grant access only to SYSTEM and Administrators"
    }
    $nodeId = Get-OneNodeInstalledNodeId -Paths $Paths
    if (-not $nodeId -or -not (Test-OneNodeIdentityActive -Path $Paths.IdentityFile -NodeId $nodeId)) {
        Stop-OneNodeInstaller 'the node identity is not active; inspect -Logs'
    }
    Write-OneNodeLog 'environment check passed'
}

function Show-OneNodeLogs {
    param([hashtable]$Paths, [bool]$Follow)
    $null = Read-OneNodeManifest -Paths $Paths
    if (-not (Test-OneNodeRegularFile $Paths.LogFile)) { Stop-OneNodeInstaller "log file was not found: $($Paths.LogFile)" }
    if ($Follow) {
        Get-Content -LiteralPath $Paths.LogFile -Tail 100 -Wait -Encoding UTF8 | Out-Host
    } else {
        Get-Content -LiteralPath $Paths.LogFile -Tail 100 -Encoding UTF8 | Out-Host
    }
}

function Test-OneNodeInteractive {
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        if ($argument -match '^[-/]noni') { return $false }
    }
    return $true
}

function Confirm-OneNodeUninstall {
    $answer = Read-Host 'Remove One Node, its identity, and all runtime state? [y/N]'
    return ([string]$answer -match '^(y|yes)\z')
}

function Invoke-OneNodeUninstallCommand {
    param([hashtable]$Paths, [bool]$Confirmed)
    if (-not (Test-OneNodeInstallationPresent -Paths $Paths)) {
        Write-OneNodeLog 'One Node is not installed'
        return
    }
    if (-not $Confirmed) {
        if (-not (Test-OneNodeInteractive)) { Stop-OneNodeInstaller '-Uninstall requires -Yes outside an interactive console' }
        if (-not (Confirm-OneNodeUninstall)) {
            Write-OneNodeLog 'uninstall cancelled'
            return
        }
    }
    Invoke-OneNodeLocked { Uninstall-OneNode -Paths $Paths }
}

function Show-OneNodeHelp {
    $lines = @(
        'Install or manage the One Node monitor agent on Windows (run as Administrator).',
        '',
        'Install:',
        "  `$env:ONE_NODE_SERVER='https://control.example.com'",
        "  `$env:ONE_NODE_ID='42'",
        "  `$env:ONE_NODE_BOOTSTRAP_TOKEN='...'",
        '  & .\install.ps1 -Role monitor',
        '',
        '  Optional: ONE_NODE_VERSION (default latest), ONE_NODE_ENROLL_TIMEOUT (seconds, default 120).',
        '  Windows nodes support monitor mode only. An existing One Node installation',
        '  and its runtime state are replaced once the new release is verified.',
        '  -Reset removes an insecure development installation first.',
        '',
        'Manage an installed node:',
        '  -Status',
        '  -Doctor',
        '  -Upgrade [latest|VERSION]',
        '  -Rollback',
        '  -Restart',
        '  -Logs [-Follow]',
        '  -Uninstall [-Yes]',
        '',
        'Without arguments on an installed host an interactive console opens a menu.'
    )
    foreach ($line in $lines) { [Console]::Out.WriteLine($line) }
}

function Invoke-OneNodeMenu {
    param([hashtable]$Paths, [hashtable]$Settings)
    $menu = @('', 'One Node', '  1. Status', '  2. Doctor', '  3. Upgrade to latest', '  4. Upgrade to version',
        '  5. Roll back', '  6. Restart', '  7. Logs', '  8. Follow logs', '  9. Uninstall', '  0. Exit')
    while ($true) {
        foreach ($line in $menu) { [Console]::Out.WriteLine($line) }
        $choice = Read-Host 'Select'
        if ($null -eq $choice) { return }
        try {
            switch ($choice.Trim()) {
                '1' { Show-OneNodeStatus -Paths $Paths }
                '2' { Invoke-OneNodeDoctor -Paths $Paths }
                '3' { Invoke-OneNodeLocked { Invoke-OneNodeUpgrade -Paths $Paths -Target 'latest' -ReleaseBaseUrl $Settings.ReleaseBaseUrl } }
                '4' {
                    $requested = Read-Host 'Version'
                    Invoke-OneNodeLocked { Invoke-OneNodeUpgrade -Paths $Paths -Target $requested -ReleaseBaseUrl $Settings.ReleaseBaseUrl }
                }
                '5' { Invoke-OneNodeLocked { Invoke-OneNodeRollback -Paths $Paths } }
                '6' { Invoke-OneNodeLocked { Restart-OneNode -Paths $Paths } }
                '7' { Show-OneNodeLogs -Paths $Paths -Follow $false }
                '8' { Show-OneNodeLogs -Paths $Paths -Follow $true }
                '9' {
                    if (Confirm-OneNodeUninstall) {
                        Invoke-OneNodeLocked { Uninstall-OneNode -Paths $Paths }
                        return
                    }
                }
                '0' { return }
                default { Write-OneNodeLog 'invalid selection' }
            }
        } catch {
            Write-OneNodeErrorLine $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Invoke-OneNodeMain {
    param([hashtable]$Options)
    $operation = Get-OneNodeOperation -Options $Options
    if ($Options['Role'] -ne 'monitor') { Stop-OneNodeInstaller 'Windows nodes support monitor mode only' }
    if ($operation -eq 'Help') {
        Show-OneNodeHelp
        return
    }
    Assert-OneNodeOptionCombination -Options $Options -Operation $operation
    Assert-OneNodeWindows
    Assert-OneNodeAdministrator
    $settings = ConvertTo-OneNodeReleaseSettings -Environment (Get-OneNodeEnvironmentInput)
    $script:OneNodeInsecure = $settings.Insecure
    $paths = Get-OneNodePaths
    switch ($operation) {
        'Status' { Show-OneNodeStatus -Paths $paths }
        'Doctor' { Invoke-OneNodeDoctor -Paths $paths }
        'Upgrade' { Invoke-OneNodeLocked { Invoke-OneNodeUpgrade -Paths $paths -Target $Options['Target'] -ReleaseBaseUrl $settings.ReleaseBaseUrl } }
        'Rollback' { Invoke-OneNodeLocked { Invoke-OneNodeRollback -Paths $paths } }
        'Restart' { Invoke-OneNodeLocked { Restart-OneNode -Paths $paths } }
        'Logs' { Show-OneNodeLogs -Paths $paths -Follow ([bool]$Options['Follow']) }
        'Uninstall' { Invoke-OneNodeUninstallCommand -Paths $paths -Confirmed ([bool]$Options['Yes']) }
        'ProcessUpgradeRequest' {
            $null = Read-OneNodeManifest -Paths $paths
            Invoke-OneNodeLocked { $script:OneNodeExitCode = Invoke-OneNodeUpgradeRequest -Paths $paths -ReleaseBaseUrl $settings.ReleaseBaseUrl }
        }
        default {
            if ($Options['NoArguments'] -and (Test-Path -LiteralPath $paths.Manifest)) {
                if (Test-OneNodeInteractive) { Invoke-OneNodeMenu -Paths $paths -Settings $settings } else { Show-OneNodeHelp }
                return
            }
            $config = ConvertTo-OneNodeInstallConfig -Environment (Get-OneNodeEnvironmentInput) -Reset ([bool]$Options['Reset'])
            Invoke-OneNodeLocked { Install-OneNode -Paths $paths -Config $config }
        }
    }
}

# Tests dot-source this file with ONE_NODE_INSTALLER_LIBRARY_ONLY=1 to load
# the functions without running anything.
if ($env:ONE_NODE_INSTALLER_LIBRARY_ONLY -eq '1') {
    return
}

$entryOptions = @{
    Role = $Role
    Reset = [bool]$Reset
    Status = [bool]$Status
    Doctor = [bool]$Doctor
    Upgrade = [bool]$Upgrade
    Target = $Target
    Rollback = [bool]$Rollback
    Restart = [bool]$Restart
    Logs = [bool]$Logs
    Follow = [bool]$Follow
    Uninstall = [bool]$Uninstall
    Yes = [bool]$Yes
    ProcessUpgradeRequest = [bool]$ProcessUpgradeRequest
    Help = [bool]$Help
    NoArguments = ($PSBoundParameters.Count -eq 0)
}
try {
    $null = Invoke-OneNodeMain -Options $entryOptions
} catch {
    Write-OneNodeErrorLine $_.Exception.Message
    exit 1
}
exit $script:OneNodeExitCode
