#Requires -Version 5.1
# Unit tests for node/install.ps1 loaded in library mode. Windows-only parts
# (services, ACLs, the SCM) are not exercised. Run through install_ps1_test.sh,
# which signs the fixture in ONE_NODE_PS_FIXTURE_DIR with a throwaway key.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$nodeDirectory = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installerPath = Join-Path $nodeDirectory 'install.ps1'
$fixtureDirectory = [string]$env:ONE_NODE_PS_FIXTURE_DIR
if (-not $fixtureDirectory) {
    throw 'ONE_NODE_PS_FIXTURE_DIR must name the signed fixture created by tests/install_ps1_test.sh'
}

$script:TestCount = 0
$script:TestFailures = 0
$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('one-node-ps1-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:TestRoot

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    $script:TestCount++
    try {
        & $Body
        [Console]::Out.WriteLine("ok - $Name")
    } catch {
        $script:TestFailures++
        [Console]::Out.WriteLine("not ok - ${Name}: $($_.Exception.Message)")
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = 'values differ')
    if (-not ($Expected -ceq $Actual)) {
        throw "${Message}: expected [$Expected], got [$Actual]"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern = '')
    $failed = $false
    $message = ''
    try {
        $null = & $Body
    } catch {
        $failed = $true
        $message = $_.Exception.Message
    }
    if (-not $failed) { throw "expected a failure matching '$Pattern'" }
    if ($Pattern -and $message -notmatch $Pattern) { throw "unexpected failure message: $message" }
}

function New-TestDirectory {
    $path = Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path
    return $path
}

function ConvertFrom-HexString {
    param([string]$Hex)
    $Hex = $Hex.Trim()
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return , $bytes
}

function Write-TestFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Static checks on the script text
# ---------------------------------------------------------------------------

$parseTokens = $null
$parseErrors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$parseTokens, [ref]$parseErrors)

Invoke-TestCase 'install.ps1 parses without errors' {
    $messages = @($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" })
    Assert-True ($messages.Count -eq 0) ($messages -join '; ')
}

Invoke-TestCase 'install.ps1 is ASCII only (Windows PowerShell reads BOM-less files as ANSI)' {
    $bytes = [System.IO.File]::ReadAllBytes($installerPath)
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $found = [regex]::Match($text, '[^\x00-\x7F]')
    Assert-True (-not $found.Success) "non-ASCII byte at offset $($found.Index)"
}

Invoke-TestCase 'install.ps1 avoids PowerShell 7-only syntax' {
    $forbiddenTokens = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
    $hits = @($parseTokens | Where-Object { $forbiddenTokens -contains [string]$_.Kind } | ForEach-Object { "$($_.Text) on line $($_.Extent.StartLineNumber)" })
    Assert-True ($hits.Count -eq 0) ($hits -join '; ')
    $text = [System.IO.File]::ReadAllText($installerPath)
    foreach ($pattern in @('Remove-Service', 'SkipHttpErrorCheck', 'AsHashtable', 'utf8NoBOM', 'Join-String', '-Parallel', 'AdditionalChildPath', '\$IsWindows', '\$IsLinux', '\$IsMacOS')) {
        Assert-True ($text -notmatch $pattern) "install.ps1 uses PowerShell 7-only $pattern"
    }
}

Invoke-TestCase 'install.ps1 calls commands by full name, not alias' {
    $aliases = @(Get-Alias | ForEach-Object { $_.Name }) + @(
        'sc', 'curl', 'wget', 'ls', 'dir', 'cp', 'copy', 'mv', 'move', 'rm', 'del', 'rd', 'rmdir',
        'cat', 'type', 'echo', 'kill', 'ps', 'sleep', 'cd', 'pwd', 'md', 'ri', 'ni', 'gi', 'gci',
        'gc', 'sls', 'iwr', 'irm', 'iex', 'write', 'select', 'where', 'sort', 'tee', 'start', 'diff')
    $commands = $installerAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
    $hits = @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $aliases -contains $_ })
    Assert-True ($hits.Count -eq 0) ('aliases used: ' + ($hits -join ', '))
}

# ---------------------------------------------------------------------------
# Library mode
# ---------------------------------------------------------------------------

$env:ONE_NODE_INSTALLER_LIBRARY_ONLY = '1'
. $installerPath
$embeddedModulus = $script:OneNodeReleaseModulus
$fixtureModulus = [Convert]::ToBase64String((ConvertFrom-HexString ([System.IO.File]::ReadAllText((Join-Path $fixtureDirectory 'modulus.hex')))))
$fixtureSums = [System.IO.File]::ReadAllBytes((Join-Path $fixtureDirectory 'SHA256SUMS'))
$fixtureSignature = [System.IO.File]::ReadAllBytes((Join-Path $fixtureDirectory 'SHA256SUMS.rsa.sig'))

# The upgrade request runs the upgrade in-process; replace it with a fixture
# unless a test asks for the real one.
$script:RealUpgrade = ${function:Invoke-OneNodeUpgrade}
$script:UseRealUpgrade = $false
$script:FakeUpgradeFailure = ''
$script:FakeUpgradeTargets = New-Object System.Collections.Generic.List[string]
function Invoke-OneNodeUpgrade {
    param([hashtable]$Paths, [string]$Target, [string]$ReleaseBaseUrl)
    if ($script:UseRealUpgrade) {
        & $script:RealUpgrade -Paths $Paths -Target $Target -ReleaseBaseUrl $ReleaseBaseUrl
        return
    }
    $script:FakeUpgradeTargets.Add($Target)
    Write-OneNodeLog "fixture upgrade to $Target"
    if ($script:FakeUpgradeFailure) { Stop-OneNodeInstaller $script:FakeUpgradeFailure }
}

Invoke-TestCase 'library mode defines functions without running the installer' {
    Assert-True ($null -ne (Get-Command Invoke-OneNodeMain -CommandType Function)) 'Invoke-OneNodeMain is missing'
    Assert-Equal 0 $script:OneNodeExitCode 'exit code'
}

# ---------------------------------------------------------------------------
# Release signature
# ---------------------------------------------------------------------------

Invoke-TestCase 'embedded release key is RSA-3072 with exponent 65537' {
    $modulus = [Convert]::FromBase64String($embeddedModulus)
    Assert-Equal 384 $modulus.Length 'modulus length'
    Assert-True ($modulus[0] -ge 0x80) 'modulus must use all 3072 bits'
    Assert-Equal 'AQAB' $script:OneNodeReleaseExponent 'exponent'
}

Invoke-TestCase 'RSA signature from openssl verifies' {
    $script:OneNodeReleaseModulus = $fixtureModulus
    try {
        Assert-True (Test-OneNodeReleaseSignature -Data $fixtureSums -Signature $fixtureSignature) 'valid signature was rejected'
    } finally {
        $script:OneNodeReleaseModulus = $embeddedModulus
    }
}

Invoke-TestCase 'RSA signature rejects a tampered manifest' {
    $script:OneNodeReleaseModulus = $fixtureModulus
    try {
        $tampered = [byte[]]$fixtureSums.Clone()
        $tampered[0] = $tampered[0] -bxor 1
        Assert-True (-not (Test-OneNodeReleaseSignature -Data $tampered -Signature $fixtureSignature)) 'tampered manifest was accepted'
        $appended = [byte[]]($fixtureSums + [byte[]](0x0A))
        Assert-True (-not (Test-OneNodeReleaseSignature -Data $appended -Signature $fixtureSignature)) 'extended manifest was accepted'
    } finally {
        $script:OneNodeReleaseModulus = $embeddedModulus
    }
}

Invoke-TestCase 'RSA signature rejects a tampered or truncated signature' {
    $script:OneNodeReleaseModulus = $fixtureModulus
    try {
        $tampered = [byte[]]$fixtureSignature.Clone()
        $tampered[100] = $tampered[100] -bxor 0x40
        Assert-True (-not (Test-OneNodeReleaseSignature -Data $fixtureSums -Signature $tampered)) 'tampered signature was accepted'
        $truncated = [byte[]]$fixtureSignature[0..200]
        Assert-True (-not (Test-OneNodeReleaseSignature -Data $fixtureSums -Signature $truncated)) 'truncated signature was accepted'
        Assert-True (-not (Test-OneNodeReleaseSignature -Data $fixtureSums -Signature ([byte[]]@()))) 'empty signature was accepted'
    } finally {
        $script:OneNodeReleaseModulus = $embeddedModulus
    }
}

Invoke-TestCase 'RSA signature from another key is rejected by the embedded key' {
    Assert-True (-not (Test-OneNodeReleaseSignature -Data $fixtureSums -Signature $fixtureSignature)) 'foreign signature was accepted'
}

Invoke-TestCase 'trust failures are fatal unless insecure' {
    $script:OneNodeInsecure = $false
    Assert-Throws { Invoke-OneNodeTrustFailure 'release checksums are unsigned' } '^release checksums are unsigned$'
    $script:OneNodeInsecure = $true
    try {
        Invoke-OneNodeTrustFailure 'release checksums are unsigned'
    } finally {
        $script:OneNodeInsecure = $false
    }
}

# ---------------------------------------------------------------------------
# SHA256SUMS
# ---------------------------------------------------------------------------

$hashA = 'a' * 64
$hashB = 'b' * 64
$hashC = 'C' * 64

Invoke-TestCase 'SHA256SUMS lookup returns the single matching entry' {
    $manifest = "$hashA  one-node-windows-amd64.exe`n$hashB  one-node-windows-arm64.exe`n$hashC  node/install.ps1`n"
    Assert-Equal $hashA (Get-OneNodeReleaseHash -Manifest $manifest -Name 'one-node-windows-amd64.exe') 'amd64'
    Assert-Equal $hashB (Get-OneNodeReleaseHash -Manifest $manifest -Name 'one-node-windows-arm64.exe') 'arm64'
    Assert-Equal ('c' * 64) (Get-OneNodeReleaseHash -Manifest $manifest -Name 'node/install.ps1') 'digest is lowercased'
}

Invoke-TestCase 'SHA256SUMS lookup refuses duplicate and missing entries' {
    $duplicate = "$hashA  node/install.ps1`n$hashB  node/install.ps1`n"
    Assert-Equal '' (Get-OneNodeReleaseHash -Manifest $duplicate -Name 'node/install.ps1') 'duplicate'
    $identical = "$hashA  node/install.ps1`n$hashA  node/install.ps1`n"
    Assert-Equal '' (Get-OneNodeReleaseHash -Manifest $identical -Name 'node/install.ps1') 'identical duplicate'
    $other = "$hashA  node/install.ps1.bak`n$hashB  xnode/install.ps1`n$hashB  NODE/install.ps1`n"
    Assert-Equal '' (Get-OneNodeReleaseHash -Manifest $other -Name 'node/install.ps1') 'similar names'
    Assert-Equal '' (Get-OneNodeReleaseHash -Manifest '' -Name 'node/install.ps1') 'empty manifest'
    $short = ('a' * 63) + "  node/install.ps1`n"
    Assert-Equal '' (Get-OneNodeReleaseHash -Manifest $short -Name 'node/install.ps1') 'short digest'
}

Invoke-TestCase 'SHA256SUMS lookup accepts CRLF and binary-mode lines' {
    $manifest = "$hashA *one-node-windows-amd64.exe`r`n$hashB  node/install.ps1`r`n"
    Assert-Equal $hashA (Get-OneNodeReleaseHash -Manifest $manifest -Name 'one-node-windows-amd64.exe') 'binary mode'
    Assert-Equal $hashB (Get-OneNodeReleaseHash -Manifest $manifest -Name 'node/install.ps1') 'CRLF'
}

Invoke-TestCase 'fixture SHA256SUMS signs this install.ps1 under node/install.ps1' {
    $manifest = [System.Text.Encoding]::UTF8.GetString($fixtureSums)
    Assert-Equal (Get-OneNodeFileSha256 $installerPath) (Get-OneNodeReleaseHash -Manifest $manifest -Name 'node/install.ps1') 'installer digest'
}

# ---------------------------------------------------------------------------
# Latest version
# ---------------------------------------------------------------------------

Invoke-TestCase 'latest version is the numerically highest one-node tag' {
    $releases = @'
[
  { "tag_name": "node-server-v99.0.0", "name": "server" },
  { "tag_name" : "one-node-v26.820.1507" },
  {"tag_name":"one-node-v26.1001.900"},
  {
    "tag_name": "one-node-v26.821.1200",
    "body": "mentions one-node-v99.9.9 in prose"
  },
  { "tag_name": "one-node-v01.2.3" },
  { "tag_name": "one-node-v99.0.0-rc1" },
  { "tag_name": "one-node-v100.0" }
]
'@
    Assert-Equal '26.1001.900' (Select-OneNodeLatestVersion -ReleasesJson $releases) 'latest'
}

Invoke-TestCase 'latest version is empty without one-node releases' {
    Assert-Equal '' (Select-OneNodeLatestVersion -ReleasesJson '[{"tag_name":"node-server-v9.9.9"}]') 'no release'
    Assert-Equal '' (Select-OneNodeLatestVersion -ReleasesJson '[]') 'empty list'
}

Invoke-TestCase 'version comparison is numeric per component' {
    Assert-Equal 1 (Compare-OneNodeVersion -Left '10.0.0' -Right '9.99.99') 'major'
    Assert-Equal -1 (Compare-OneNodeVersion -Left '26.99.0' -Right '26.100.0') 'minor'
    Assert-Equal 0 (Compare-OneNodeVersion -Left '1.2.3' -Right '1.2.3') 'equal'
    Assert-Equal 1 (Compare-OneNodeVersion -Left '1.2.123456789012345678901' -Right '1.2.99999999999999999999') 'beyond Int64'
}

Invoke-TestCase 'versions must be canonical a.b.c' {
    foreach ($valid in @('0.0.0', '1.2.3', '26.1029.1500')) { Assert-True (Test-OneNodeVersion $valid) "rejected $valid" }
    foreach ($invalid in @('', '1.2', '1.2.3.4', '01.2.3', '1.02.3', 'v1.2.3', '1.2.3-rc1', "1.2.3`n", ' 1.2.3')) {
        Assert-True (-not (Test-OneNodeVersion $invalid)) "accepted [$invalid]"
    }
}

# ---------------------------------------------------------------------------
# Environment files
# ---------------------------------------------------------------------------

$windowsPaths = @{
    StateDir = 'C:\ProgramData\OneNode\state'
    UpgradeRequest = 'C:\ProgramData\OneNode\state\update\request'
    Installer = 'C:\Program Files\OneNode\install.ps1'
    BootstrapEnv = 'C:\ProgramData\OneNode\state\bootstrap.env'
    LogFile = 'C:\ProgramData\OneNode\logs\one-node.log'
    Binary = 'C:\Program Files\OneNode\one-node.exe'
    EnvFile = 'C:\ProgramData\OneNode\one-node.env'
}

Invoke-TestCase 'environment file keeps Windows paths literal in single quotes' {
    $content = Format-OneNodeEnvironment -Values (New-OneNodeEnvironmentValues -Paths $windowsPaths -NodeId '42' -Server 'https://control.example.com')
    $expected = @(
        "NODE_NODE_ID='42'",
        "NODE_ROLE='monitor'",
        "NODE_HEARTBEAT_INTERVAL='60s'",
        "NODE_STATE_DIR='C:\ProgramData\OneNode\state'",
        "NODE_UPGRADE_REQUEST_FILE='C:\ProgramData\OneNode\state\update\request'",
        "NODE_UPGRADE_INSTALLER='C:\Program Files\OneNode\install.ps1'",
        "CONTROL_ADDR='https://control.example.com'",
        "CONTROL_BOOTSTRAP_ENV_FILE='C:\ProgramData\OneNode\state\bootstrap.env'",
        "LOG_LEVEL='info'",
        "LOG_FILE='C:\ProgramData\OneNode\logs\one-node.log'"
    ) -join "`n"
    Assert-Equal ($expected + "`n") $content 'environment file'
    Assert-True ($content -notmatch 'TOKEN') 'the main environment file must not carry the token'
}

Invoke-TestCase 'bootstrap environment carries only the token' {
    $content = Format-OneNodeEnvironment -Values ([ordered]@{ CONTROL_BOOTSTRAP_TOKEN = 'abc.DEF-123_$x\y' })
    Assert-Equal "CONTROL_BOOTSTRAP_TOKEN='abc.DEF-123_`$x\y'`n" $content 'bootstrap file'
    Assert-True (-not (Test-OneNodeBootstrapTokenPresent -Path (Join-Path (New-TestDirectory) 'missing'))) 'missing file reported a token'
}

Invoke-TestCase 'environment values reject quotes, line breaks and a trailing backslash' {
    Assert-Throws { ConvertTo-OneNodeEnvLine -Name 'CONTROL_ADDR' -Value "it's" } 'single quote'
    Assert-Throws { ConvertTo-OneNodeEnvLine -Name 'CONTROL_ADDR' -Value "a`nb" } 'single line'
    Assert-Throws { ConvertTo-OneNodeEnvLine -Name 'CONTROL_ADDR' -Value "a`rb" } 'single line'
    Assert-Throws { ConvertTo-OneNodeEnvLine -Name 'CONTROL_ADDR' -Value "a`tb" } 'control characters'
    Assert-Throws { ConvertTo-OneNodeEnvLine -Name 'NODE_STATE_DIR' -Value 'C:\state\' } 'backslash'
    Assert-Throws { ConvertTo-OneNodeEnvLine -Name 'lower' -Value 'x' } 'invalid environment key'
    Assert-Throws { Format-OneNodeEnvironment -Values ([ordered]@{ CONTROL_BOOTSTRAP_TOKEN = "x'y" }) } 'CONTROL_BOOTSTRAP_TOKEN must not contain a single quote'
}

Invoke-TestCase 'environment files parse back' {
    $content = Format-OneNodeEnvironment -Values (New-OneNodeEnvironmentValues -Paths $windowsPaths -NodeId '42' -Server 'grpcs://control.example.com:443')
    $values = ConvertFrom-OneNodeEnvironment -Content ($content -replace "`n", "`r`n")
    Assert-Equal '42' $values['NODE_NODE_ID'] 'node id'
    Assert-Equal 'C:\ProgramData\OneNode\state' $values['NODE_STATE_DIR'] 'state dir'
    Assert-Equal 'grpcs://control.example.com:443' $values['CONTROL_ADDR'] 'control address'
}

Invoke-TestCase 'installed node id is read from the environment file' {
    $root = New-TestDirectory
    $paths = Get-OneNodePaths -ProgramRoot (Join-Path $root 'program') -DataRoot (Join-Path $root 'data')
    Assert-Equal '' (Get-OneNodeInstalledNodeId -Paths $paths) 'missing file'
    $null = New-Item -ItemType Directory -Path $paths.DataDir
    Write-TestFile -Path $paths.EnvFile -Content (Format-OneNodeEnvironment -Values (New-OneNodeEnvironmentValues -Paths $paths -NodeId '7' -Server 'https://x'))
    Assert-Equal '7' (Get-OneNodeInstalledNodeId -Paths $paths) 'node id'
    Write-TestFile -Path $paths.EnvFile -Content "NODE_NODE_ID='07'`n"
    Assert-Equal '' (Get-OneNodeInstalledNodeId -Paths $paths) 'non-canonical id'
}

Invoke-TestCase 'service command loads both environment files' {
    Assert-Equal '"C:\Program Files\OneNode\one-node.exe" start --env-file "C:\ProgramData\OneNode\one-node.env" --env-file "C:\ProgramData\OneNode\state\bootstrap.env"' `
        (Format-OneNodeServiceCommand -Paths $windowsPaths) 'binary path'
}

# ---------------------------------------------------------------------------
# Installation inputs
# ---------------------------------------------------------------------------

function New-TestEnvironment {
    param([hashtable]$Overrides = @{})
    $environment = @{
        ONE_NODE_SERVER = 'https://control.example.com'
        ONE_NODE_ID = '42'
        ONE_NODE_BOOTSTRAP_TOKEN = 'token-1'
        ONE_NODE_VERSION = ''
        ONE_NODE_ALLOW_INSECURE = ''
        ONE_NODE_RELEASE_BASE_URL = ''
        ONE_NODE_ENROLL_TIMEOUT = ''
    }
    foreach ($key in $Overrides.Keys) { $environment[$key] = $Overrides[$key] }
    return $environment
}

Invoke-TestCase 'install config accepts the documented defaults' {
    $config = ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment) -Reset $false
    Assert-Equal 'https://control.example.com' $config.Server 'server'
    Assert-Equal '42' $config.NodeId 'node id'
    Assert-Equal '' $config.Version 'version means latest'
    Assert-Equal 120 $config.EnrollTimeout 'timeout'
    Assert-Equal $false $config.Insecure 'insecure'
    $config = ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_SERVER = 'grpcs://control.example.com:443'; ONE_NODE_VERSION = '26.1029.1500'; ONE_NODE_ENROLL_TIMEOUT = '300' }) -Reset $false
    Assert-Equal '26.1029.1500' $config.Version 'version'
    Assert-Equal 300 $config.EnrollTimeout 'custom timeout'
}

Invoke-TestCase 'install config refuses plaintext control unless insecure' {
    foreach ($server in @('http://10.0.0.1:27519', 'grpc://10.0.0.1:27519', '10.0.0.1:27519', 'host.orb.internal:27519')) {
        Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_SERVER = $server }) -Reset $false } 'plaintext control connections require ONE_NODE_ALLOW_INSECURE=true'
        $config = ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_SERVER = $server; ONE_NODE_ALLOW_INSECURE = 'true' }) -Reset $false
        Assert-Equal $server $config.Server 'insecure server'
    }
    foreach ($server in @('ftp://control.example.com', 'https://', 'control.example.com', 'https:///path')) {
        Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_SERVER = $server; ONE_NODE_ALLOW_INSECURE = 'true' }) -Reset $false } 'ONE_NODE_SERVER is invalid'
    }
}

Invoke-TestCase 'install config validates identity, token, version and timeout' {
    foreach ($id in @('0', '-1', '007', 'abc', '1.5', '12345678901234567890')) {
        Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_ID = $id }) -Reset $false } 'ONE_NODE_ID must be a positive integer'
    }
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_ID = '' }) -Reset $false } 'ONE_NODE_ID is required'
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_BOOTSTRAP_TOKEN = "a`nb" }) -Reset $false } 'ONE_NODE_BOOTSTRAP_TOKEN must be a single line'
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_VERSION = '1.2' }) -Reset $false } 'ONE_NODE_VERSION must be an exact'
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_ENROLL_TIMEOUT = '0' }) -Reset $false } 'ONE_NODE_ENROLL_TIMEOUT'
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_ENROLL_TIMEOUT = 'soon' }) -Reset $false } 'ONE_NODE_ENROLL_TIMEOUT'
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_ALLOW_INSECURE = 'yes' }) -Reset $false } 'ONE_NODE_ALLOW_INSECURE must be true or false'
}

Invoke-TestCase 'development release URL and reset require insecure local hosts' {
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment) -Reset $true } 'Reset is only available'
    $config = ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_ALLOW_INSECURE = 'true' }) -Reset $true
    Assert-Equal $true $config.Reset 'reset'
    Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_RELEASE_BASE_URL = 'http://127.0.0.1:8080/dist' }) -Reset $false } 'require ONE_NODE_ALLOW_INSECURE=true'
    foreach ($url in @('https://example.com/dist', 'http://example.com:8080/dist', 'http://127.0.0.1/dist', 'http://127.0.0.1.example.com:80/')) {
        Assert-Throws { ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_RELEASE_BASE_URL = $url; ONE_NODE_ALLOW_INSECURE = 'true' }) -Reset $false } 'only available for local development'
    }
    foreach ($url in @('http://127.0.0.1:8080/dist/', 'http://localhost:9000', 'http://host.orb.internal:27500/one-node-v1.2.3')) {
        $config = ConvertTo-OneNodeInstallConfig -Environment (New-TestEnvironment @{ ONE_NODE_RELEASE_BASE_URL = $url; ONE_NODE_ALLOW_INSECURE = 'true' }) -Reset $false
        Assert-Equal $url.TrimEnd('/') $config.ReleaseBaseUrl 'release base URL'
    }
}

Invoke-TestCase 'downloads stay on HTTPS except insecure local development hosts' {
    $script:OneNodeInsecure = $false
    try {
        Assert-OneNodeDownloadUri -Uri 'https://github.com/voiceofhu/one-action/releases/download/one-node-v1.2.3/SHA256SUMS'
        Assert-Throws { Assert-OneNodeDownloadUri -Uri 'http://127.0.0.1:8080/SHA256SUMS' } 'non-HTTPS'
        $script:OneNodeInsecure = $true
        Assert-OneNodeDownloadUri -Uri 'http://127.0.0.1:8080/SHA256SUMS'
        Assert-Throws { Assert-OneNodeDownloadUri -Uri 'http://objects.example.com/one-node.exe' } 'non-HTTPS'
    } finally {
        $script:OneNodeInsecure = $false
    }
}

Invoke-TestCase 'management options are exclusive and scoped' {
    Assert-Equal 'Status' (Get-OneNodeOperation -Options @{ Status = $true }) 'single'
    Assert-Equal '' (Get-OneNodeOperation -Options @{ Role = 'monitor' }) 'install'
    Assert-Throws { Get-OneNodeOperation -Options @{ Status = $true; Upgrade = $true } } 'choose only one of -Status, -Upgrade'
    Assert-Throws { Assert-OneNodeOptionCombination -Options @{ Follow = $true } -Operation 'Status' } '-Follow is only valid with -Logs'
    Assert-Throws { Assert-OneNodeOptionCombination -Options @{ Yes = $true } -Operation '' } '-Yes is only valid with -Uninstall'
    Assert-Throws { Assert-OneNodeOptionCombination -Options @{ Target = '1.2.3' } -Operation '' } 'unexpected argument: 1.2.3'
    Assert-Throws { Assert-OneNodeOptionCombination -Options @{ Reset = $true } -Operation 'Status' } '-Reset is only valid for installation'
    Assert-OneNodeOptionCombination -Options @{ Target = 'latest' } -Operation 'Upgrade'
    Assert-OneNodeOptionCombination -Options @{ Follow = $true } -Operation 'Logs'
}

Invoke-TestCase 'other roles are refused' {
    Assert-Throws { Invoke-OneNodeMain -Options @{ Role = 'relay' } } '^Windows nodes support monitor mode only$'
}

# ---------------------------------------------------------------------------
# Architecture and paths
# ---------------------------------------------------------------------------

Invoke-TestCase 'architecture maps AMD64 and ARM64, preferring the WOW64 variable' {
    Assert-Equal 'amd64' (ConvertTo-OneNodeArchitecture -Wow64Architecture '' -ProcessorArchitecture 'AMD64') 'native amd64'
    Assert-Equal 'arm64' (ConvertTo-OneNodeArchitecture -Wow64Architecture $null -ProcessorArchitecture 'ARM64') 'native arm64'
    Assert-Equal 'amd64' (ConvertTo-OneNodeArchitecture -Wow64Architecture 'AMD64' -ProcessorArchitecture 'x86') '32-bit PowerShell on x64'
    Assert-Equal 'arm64' (ConvertTo-OneNodeArchitecture -Wow64Architecture 'ARM64' -ProcessorArchitecture 'x86') '32-bit PowerShell on ARM64'
    Assert-Throws { ConvertTo-OneNodeArchitecture -Wow64Architecture '' -ProcessorArchitecture 'x86' } 'unsupported Windows architecture: x86'
    Assert-Throws { ConvertTo-OneNodeArchitecture -Wow64Architecture '' -ProcessorArchitecture 'IA64' } 'unsupported Windows architecture: IA64'
    Assert-Throws { ConvertTo-OneNodeArchitecture -Wow64Architecture '' -ProcessorArchitecture '' } 'unsupported Windows architecture: unknown'
}

Invoke-TestCase 'paths follow the documented layout' {
    $paths = Get-OneNodePaths -ProgramRoot '/pf' -DataRoot '/pd'
    $program = [System.IO.Path]::Combine('/pf', 'OneNode')
    $data = [System.IO.Path]::Combine('/pd', 'OneNode')
    $state = [System.IO.Path]::Combine($data, 'state')
    Assert-Equal ([System.IO.Path]::Combine($program, 'one-node.exe')) $paths.Binary 'binary'
    Assert-Equal ([System.IO.Path]::Combine($program, 'install.ps1')) $paths.Installer 'installer'
    Assert-Equal ([System.IO.Path]::Combine([System.IO.Path]::Combine($program, 'previous'), 'one-node.exe')) $paths.PreviousBinary 'previous binary'
    Assert-Equal ([System.IO.Path]::Combine($data, 'one-node.env')) $paths.EnvFile 'env file'
    Assert-Equal ([System.IO.Path]::Combine($data, 'installation')) $paths.Manifest 'manifest'
    Assert-Equal ([System.IO.Path]::Combine($state, 'bootstrap.env')) $paths.BootstrapEnv 'bootstrap env'
    Assert-Equal ([System.IO.Path]::Combine($state, 'node-secret')) $paths.IdentityFile 'identity'
    Assert-Equal ([System.IO.Path]::Combine([System.IO.Path]::Combine($state, 'update'), 'request')) $paths.UpgradeRequest 'request'
    Assert-Equal ([System.IO.Path]::Combine([System.IO.Path]::Combine($data, 'logs'), 'one-node.log')) $paths.LogFile 'log file'
}

# ---------------------------------------------------------------------------
# Installation manifest
# ---------------------------------------------------------------------------

Invoke-TestCase 'installation manifest round-trips' {
    $content = Format-OneNodeManifest -Manifest (New-OneNodeManifest -CurrentVersion '1.2.4' -PreviousVersion '1.2.3' -StateDirectory 'C:\ProgramData\OneNode\state')
    Assert-Equal "format=one-node-windows-v1`nmode=service`nrole=monitor`ncurrent_version=1.2.4`nprevious_version=1.2.3`nstate_dir=C:\ProgramData\OneNode\state`n" $content 'manifest text'
    $manifest = ConvertFrom-OneNodeManifest -Content $content
    Assert-Equal '1.2.4' $manifest['current_version'] 'current'
    Assert-Equal '1.2.3' $manifest['previous_version'] 'previous'
    $fresh = ConvertFrom-OneNodeManifest -Content (Format-OneNodeManifest -Manifest (New-OneNodeManifest -CurrentVersion '1.2.4' -PreviousVersion '' -StateDirectory 'C:\s'))
    Assert-Equal '' $fresh['previous_version'] 'empty previous version'
}

Invoke-TestCase 'installation manifest refuses unknown content' {
    $valid = Format-OneNodeManifest -Manifest (New-OneNodeManifest -CurrentVersion '1.2.4' -PreviousVersion '' -StateDirectory 'C:\s')
    Assert-Throws { ConvertFrom-OneNodeManifest -Content ($valid + "extra=1`n") } 'unknown field: extra'
    Assert-Throws { ConvertFrom-OneNodeManifest -Content ($valid + "mode=service`n") } 'duplicate field: mode'
    Assert-Throws { ConvertFrom-OneNodeManifest -Content ($valid -replace 'role=monitor\n', '') } 'missing field: role'
    Assert-Throws { ConvertFrom-OneNodeManifest -Content ($valid -replace 'one-node-windows-v1', 'one-node-manifest') } 'unsupported format'
    Assert-Throws { ConvertFrom-OneNodeManifest -Content ($valid -replace 'current_version=1.2.4', 'current_version=1.2') } 'current_version is invalid'
    Assert-Throws { ConvertFrom-OneNodeManifest -Content ($valid -replace 'role=monitor', 'role=relay') } 'unsupported role'
    Assert-Throws { ConvertFrom-OneNodeManifest -Content "format=one-node-windows-v1`ngarbage`n" } 'malformed line'
}

Invoke-TestCase 'installation manifest must match this host state directory' {
    $root = New-TestDirectory
    $paths = Get-OneNodePaths -ProgramRoot (Join-Path $root 'program') -DataRoot (Join-Path $root 'data')
    Assert-Throws { Read-OneNodeManifest -Paths $paths } 'manifest was not found'
    $null = New-Item -ItemType Directory -Path $paths.DataDir
    Write-OneNodeManifest -Paths $paths -Manifest (New-OneNodeManifest -CurrentVersion '1.2.3' -PreviousVersion '' -StateDirectory $paths.StateDir)
    Assert-Equal '1.2.3' (Read-OneNodeManifest -Paths $paths)['current_version'] 'manifest'
    Write-OneNodeManifest -Paths $paths -Manifest (New-OneNodeManifest -CurrentVersion '1.2.3' -PreviousVersion '' -StateDirectory '/elsewhere')
    Assert-Throws { Read-OneNodeManifest -Paths $paths } 'unexpected state directory'
    Write-TestFile -Path $paths.Manifest -Content "format=v2`n"
    Assert-Throws { Read-OneNodeManifest -Paths $paths } 'refusing unknown or unsafe installation manifest'
}

Invoke-TestCase 'text files are UTF-8 without BOM and replaced atomically' {
    $path = Join-Path (New-TestDirectory) 'status'
    Write-OneNodeTextFile -Path $path -Content "first`n"
    Write-OneNodeTextFile -Path $path -Content "second`n"
    $bytes = [System.IO.File]::ReadAllBytes($path)
    Assert-Equal 0x73 $bytes[0] 'no BOM'
    Assert-Equal "second`n" ([System.IO.File]::ReadAllText($path)) 'content'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Force).Count 'temporary files are gone'
}

# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------

Invoke-TestCase 'identity is active only for this node id as a string' {
    Assert-True (Test-OneNodeIdentityDocument -Json '{"node_id":"42","state":"active","key":"x"}' -NodeId '42') 'active identity rejected'
    Assert-True (-not (Test-OneNodeIdentityDocument -Json '{"node_id":42,"state":"active"}' -NodeId '42')) 'numeric node id accepted'
    Assert-True (-not (Test-OneNodeIdentityDocument -Json '{"node_id":"43","state":"active"}' -NodeId '42')) 'other node accepted'
    Assert-True (-not (Test-OneNodeIdentityDocument -Json '{"node_id":"42","state":"pending"}' -NodeId '42')) 'pending identity accepted'
    Assert-True (-not (Test-OneNodeIdentityDocument -Json '{"node_id":"42"}' -NodeId '42')) 'missing state accepted'
    Assert-True (-not (Test-OneNodeIdentityDocument -Json '{"node_id":"42","state":"act' -NodeId '42')) 'truncated JSON accepted'
    Assert-True (-not (Test-OneNodeIdentityDocument -Json '' -NodeId '42')) 'empty file accepted'
    Assert-True (-not (Test-OneNodeIdentityDocument -Json '["42","active"]' -NodeId '42')) 'array accepted'
}

Invoke-TestCase 'identity file and bootstrap token are read from disk' {
    $directory = New-TestDirectory
    $identity = Join-Path $directory 'node-secret'
    Assert-True (-not (Test-OneNodeIdentityActive -Path $identity -NodeId '42')) 'missing identity accepted'
    Write-TestFile -Path $identity -Content '{"node_id":"42","state":"active"}'
    Assert-True (Test-OneNodeIdentityActive -Path $identity -NodeId '42') 'identity rejected'
    $bootstrap = Join-Path $directory 'bootstrap.env'
    Write-TestFile -Path $bootstrap -Content "CONTROL_BOOTSTRAP_TOKEN='abc'`n"
    Assert-True (Test-OneNodeBootstrapTokenPresent -Path $bootstrap) 'token not detected'
    Write-TestFile -Path $bootstrap -Content ''
    Assert-True (-not (Test-OneNodeBootstrapTokenPresent -Path $bootstrap)) 'removed token detected'
}

Invoke-TestCase 'status values are formatted like the Linux manager' {
    Assert-Equal '512 KiB' (Format-OneNodeBytes -Bytes (512 * 1024)) 'KiB'
    Assert-Equal '10.5 MiB' (Format-OneNodeBytes -Bytes (10.5 * 1024 * 1024)) 'MiB'
    Assert-Equal '3.00 GiB' (Format-OneNodeBytes -Bytes (3 * 1024 * 1024 * 1024)) 'GiB'
    Assert-Equal '01:05' (Format-OneNodeUptime -Duration ([TimeSpan]::FromSeconds(65))) 'minutes'
    Assert-Equal '03:00:00' (Format-OneNodeUptime -Duration ([TimeSpan]::FromHours(3))) 'hours'
    Assert-Equal '2-03:04:05' (Format-OneNodeUptime -Duration (New-Object TimeSpan(2, 3, 4, 5))) 'days'
}

# ---------------------------------------------------------------------------
# Upgrade requests
# ---------------------------------------------------------------------------

$validRequest = "command_id=command-1`nversion=26.828.1600`nstate=pending`nrequested_at=2026-08-28T08:00:00Z`nupdated_at=2026-08-28T08:00:00Z`nmessage=`n"

Invoke-TestCase 'upgrade request parses the six updater fields' {
    $request = ConvertFrom-OneNodeUpgradeRequest -Content $validRequest
    Assert-Equal 'command-1' $request['command_id'] 'command id'
    Assert-Equal '26.828.1600' $request['version'] 'version'
    Assert-Equal '2026-08-28T08:00:00Z' $request['requested_at'] 'requested at'
    $crlf = ConvertFrom-OneNodeUpgradeRequest -Content ($validRequest -replace "`n", "`r`n")
    Assert-Equal 'command-1' $crlf['command_id'] 'CRLF'
    $unterminated = ConvertFrom-OneNodeUpgradeRequest -Content $validRequest.TrimEnd("`n")
    Assert-Equal '' $unterminated['message'] 'no trailing newline'
    $longId = 'a' * 128
    Assert-Equal $longId (ConvertFrom-OneNodeUpgradeRequest -Content ($validRequest -replace 'command-1', $longId))['command_id'] '128 characters'
    Assert-Equal 'job.1:retry_x-2' (ConvertFrom-OneNodeUpgradeRequest -Content ($validRequest -replace 'command-1', 'job.1:retry_x-2'))['command_id'] 'allowed punctuation'
}

Invoke-TestCase 'upgrade request validation rejects malformed requests' {
    $cases = @(
        @(($validRequest -replace 'message=\n', ''), 'invalid field count'),
        @(($validRequest + "extra=1`n"), 'invalid field count'),
        @(($validRequest + "`n"), 'invalid field count'),
        @(($validRequest -replace 'message=', 'version=1.2.3'), 'repeats version'),
        @(($validRequest -replace 'message=', 'note='), 'unknown field'),
        @(($validRequest -replace 'command-1', 'command 1'), 'command_id is invalid'),
        @(($validRequest -replace 'command-1', 'cmd/1'), 'command_id is invalid'),
        @(($validRequest -replace 'command-1', ''), 'command_id is invalid'),
        @(($validRequest -replace 'command-1', ('a' * 129)), 'command_id is invalid'),
        @(($validRequest -replace '26\.828\.1600', '026.828.1600'), 'version must have'),
        @(($validRequest -replace '26\.828\.1600', '26.828'), 'version must have'),
        @(($validRequest -replace '26\.828\.1600', '26.828.1600.1'), 'version must have'),
        @(($validRequest -replace '26\.828\.1600', 'latest'), 'version must have'),
        @(($validRequest -replace 'state=pending', 'state=running'), 'state must be pending'),
        @(($validRequest -replace 'message=', 'message=hello'), 'metadata is invalid'),
        @(($validRequest -replace 'requested_at=[^\n]*', 'requested_at='), 'metadata is invalid'),
        @('', 'invalid field count')
    )
    foreach ($case in $cases) {
        $content = $case[0]
        Assert-Throws { ConvertFrom-OneNodeUpgradeRequest -Content $content } $case[1]
    }
}

Invoke-TestCase 'upgrade status keeps the request fields and a UTC timestamp' {
    $request = ConvertFrom-OneNodeUpgradeRequest -Content $validRequest
    $time = New-Object DateTime(2026, 10, 29, 7, 8, 9, [DateTimeKind]::Utc)
    $status = Format-OneNodeUpgradeStatus -Request $request -State 'failed' -Message "line one`r`nline two" -Time $time
    Assert-Equal "command_id=command-1`nversion=26.828.1600`nstate=failed`nrequested_at=2026-08-28T08:00:00Z`nupdated_at=2026-10-29T07:08:09Z`nmessage=line one  line two`n" $status 'status'
    $long = Format-OneNodeUpgradeStatus -Request $request -State 'failed' -Message ('x' * 1500)
    Assert-Equal 1000 (@(Split-OneNodeLines $long)[5].Length - 'message='.Length) 'message is capped at 1000 characters'
    Assert-True (@(Split-OneNodeLines (Format-OneNodeUpgradeStatus -Request $request -State 'running' -Message 'upgrade started'))[4] -cmatch '^updated_at=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$') 'default timestamp format'
}

Invoke-TestCase 'upgrade failure message is the last installer error' {
    $output = "[one-node] downloading`n[one-node] error: first`n[one-node] restoring`n[one-node] error: binary SHA256 verification failed`ntrailing`n"
    Assert-Equal 'binary SHA256 verification failed' (Get-OneNodeUpgradeFailureMessage -Output $output) 'last error'
    Assert-Equal 'trailing' (Get-OneNodeUpgradeFailureMessage -Output "[one-node] working`ntrailing`n`n") 'last line'
    Assert-Equal 'upgrade failed' (Get-OneNodeUpgradeFailureMessage -Output '') 'fallback'
    Assert-Equal 1000 (Get-OneNodeUpgradeFailureMessage -Output ('[one-node] error: ' + ('y' * 2000))).Length 'capped'
}

function New-TestUpgradeHost {
    $root = New-TestDirectory
    $paths = Get-OneNodePaths -ProgramRoot (Join-Path $root 'program') -DataRoot (Join-Path $root 'data')
    $null = New-Item -ItemType Directory -Path $paths.UpdateDir -Force
    return $paths
}

function Read-TestStatus {
    param([hashtable]$Paths)
    $status = @{}
    foreach ($line in @(Split-OneNodeLines ([System.IO.File]::ReadAllText((Join-Path $Paths.UpdateDir 'status'))))) {
        $separator = $line.IndexOf('=')
        $status[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
    }
    return $status
}

Invoke-TestCase 'processing a request records running then succeeded' {
    $paths = New-TestUpgradeHost
    Write-TestFile -Path $paths.UpgradeRequest -Content $validRequest
    $script:FakeUpgradeFailure = ''
    $script:FakeUpgradeTargets.Clear()
    $exitCode = Invoke-OneNodeUpgradeRequest -Paths $paths
    Assert-Equal 0 $exitCode 'exit code'
    Assert-Equal '26.828.1600' ($script:FakeUpgradeTargets -join ',') 'upgrade target'
    $status = Read-TestStatus -Paths $paths
    Assert-Equal 'command-1' $status['command_id'] 'command id'
    Assert-Equal 'succeeded' $status['state'] 'state'
    Assert-Equal 'upgrade completed' $status['message'] 'message'
    Assert-Equal '2026-08-28T08:00:00Z' $status['requested_at'] 'requested at'
    Assert-True (-not (Test-Path -LiteralPath $paths.UpgradeRequest)) 'request was kept'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.UpdateDir 'request.running'))) 'running request was kept'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $paths.UpdateDir 'last-upgrade.log')) -match 'fixture upgrade to 26\.828\.1600') 'transcript is missing'
    $leftovers = @(Get-ChildItem -LiteralPath $paths.UpdateDir -Force | Where-Object { $_.Name -like '.*' })
    Assert-Equal 0 $leftovers.Count 'temporary files are gone'
}

Invoke-TestCase 'processing a request records the installer error on failure' {
    $paths = New-TestUpgradeHost
    Write-TestFile -Path $paths.UpgradeRequest -Content $validRequest
    $script:FakeUpgradeFailure = 'one-node-v26.828.1600 does not sign node/install.ps1'
    try {
        $exitCode = Invoke-OneNodeUpgradeRequest -Paths $paths
    } finally {
        $script:FakeUpgradeFailure = ''
    }
    Assert-Equal 1 $exitCode 'exit code'
    $status = Read-TestStatus -Paths $paths
    Assert-Equal 'failed' $status['state'] 'state'
    Assert-Equal 'one-node-v26.828.1600 does not sign node/install.ps1' $status['message'] 'message'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.UpdateDir 'request.running'))) 'running request was kept'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $paths.UpdateDir 'last-upgrade.log')) -match '\[one-node\] error: one-node-v26') 'transcript lacks the error'
}

Invoke-TestCase 'an invalid request is deleted without running an upgrade' {
    $paths = New-TestUpgradeHost
    Write-TestFile -Path $paths.UpgradeRequest -Content ($validRequest -replace 'command-1', 'bad id')
    $script:FakeUpgradeTargets.Clear()
    $exitCode = Invoke-OneNodeUpgradeRequest -Paths $paths
    Assert-Equal 1 $exitCode 'exit code'
    Assert-Equal 0 $script:FakeUpgradeTargets.Count 'upgrade ran'
    Assert-True (-not (Test-Path -LiteralPath $paths.UpgradeRequest)) 'invalid request was kept'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $paths.UpdateDir 'status'))) 'status was written'
    Assert-Equal 1 (Invoke-OneNodeUpgradeRequest -Paths $paths) 'missing request'
}

# ---------------------------------------------------------------------------
# Upgrade and rollback file switching (service control and downloads stubbed)
# ---------------------------------------------------------------------------

$script:ServiceCalls = New-Object System.Collections.Generic.List[string]
$script:FakeHealth = New-Object System.Collections.Generic.Queue[bool]
$script:FakePreviousVersion = ''
function Stop-OneNodeService { $script:ServiceCalls.Add('stop') }
function Start-OneNodeService { $script:ServiceCalls.Add('start') }
function Get-OneNodeArchitecture { return 'amd64' }
function Write-OneNodeRecentLogs { param([hashtable]$Paths, [int]$Lines) }
function Test-OneNodeStaysHealthy {
    param([hashtable]$Paths, [string]$NodeId)
    return $script:FakeHealth.Dequeue()
}
function Get-OneNodeBinaryVersion {
    param([string]$Path)
    return $script:FakePreviousVersion
}
function Get-OneNodeVerifiedRelease {
    param([string]$Version, [string]$Architecture, [string]$WorkDirectory, [string]$ReleaseBaseUrl)
    $binary = Join-Path $WorkDirectory 'one-node.exe'
    $installer = Join-Path $WorkDirectory 'install.ps1'
    Write-TestFile -Path $binary -Content "binary $Version"
    Write-TestFile -Path $installer -Content "installer $Version"
    return @{ Version = $Version; Binary = $binary; Installer = $installer }
}

function New-TestInstalledHost {
    param([string]$Current, [string]$Previous = '')
    $root = New-TestDirectory
    $paths = Get-OneNodePaths -ProgramRoot (Join-Path $root 'program') -DataRoot (Join-Path $root 'data')
    foreach ($directory in @($paths.ProgramDir, $paths.StateDir)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    Write-TestFile -Path $paths.Binary -Content "binary $Current"
    Write-TestFile -Path $paths.Installer -Content "installer $Current"
    if ($Previous) {
        $null = New-Item -ItemType Directory -Path $paths.PreviousDir
        Write-TestFile -Path $paths.PreviousBinary -Content "binary $Previous"
        Write-TestFile -Path $paths.PreviousInstaller -Content "installer $Previous"
    }
    Write-TestFile -Path $paths.EnvFile -Content (Format-OneNodeEnvironment -Values (New-OneNodeEnvironmentValues -Paths $paths -NodeId '42' -Server 'https://x'))
    Write-OneNodeManifest -Paths $paths -Manifest (New-OneNodeManifest -CurrentVersion $Current -PreviousVersion $Previous -StateDirectory $paths.StateDir)
    return $paths
}

function Assert-TestFile {
    param([string]$Path, [string]$Expected)
    Assert-Equal $Expected ([System.IO.File]::ReadAllText($Path)) $Path
}

function Invoke-TestRealUpgrade {
    param([hashtable]$Paths, [string]$Target)
    $script:UseRealUpgrade = $true
    try {
        Invoke-OneNodeUpgrade -Paths $Paths -Target $Target -ReleaseBaseUrl ''
    } finally {
        $script:UseRealUpgrade = $false
    }
}

Invoke-TestCase 'upgrade moves the current release into previous' {
    $paths = New-TestInstalledHost -Current '1.0.0' -Previous '0.9.0'
    $script:ServiceCalls.Clear()
    $script:FakeHealth.Clear()
    $script:FakeHealth.Enqueue($true)
    Invoke-TestRealUpgrade -Paths $paths -Target '2.0.0'
    Assert-TestFile $paths.Binary 'binary 2.0.0'
    Assert-TestFile $paths.Installer 'installer 2.0.0'
    Assert-TestFile $paths.PreviousBinary 'binary 1.0.0'
    Assert-TestFile $paths.PreviousInstaller 'installer 1.0.0'
    $manifest = Read-OneNodeManifest -Paths $paths
    Assert-Equal '2.0.0' $manifest['current_version'] 'current version'
    Assert-Equal '1.0.0' $manifest['previous_version'] 'previous version'
    Assert-Equal 'stop,start' ($script:ServiceCalls -join ',') 'service calls'
}

Invoke-TestCase 'unhealthy upgrade restores the exact previous installation' {
    $paths = New-TestInstalledHost -Current '1.0.0' -Previous '0.9.0'
    $before = [System.IO.File]::ReadAllText($paths.Manifest)
    $script:ServiceCalls.Clear()
    $script:FakeHealth.Clear()
    $script:FakeHealth.Enqueue($false)
    $script:FakeHealth.Enqueue($true)
    Assert-Throws { Invoke-TestRealUpgrade -Paths $paths -Target '2.0.0' } 'upgrade to 2\.0\.0 failed and One Node 1\.0\.0 was restored'
    Assert-TestFile $paths.Binary 'binary 1.0.0'
    Assert-TestFile $paths.Installer 'installer 1.0.0'
    Assert-TestFile $paths.PreviousBinary 'binary 0.9.0'
    Assert-TestFile $paths.PreviousInstaller 'installer 0.9.0'
    Assert-Equal $before ([System.IO.File]::ReadAllText($paths.Manifest)) 'manifest'
    Assert-Equal 'stop,start,stop,start' ($script:ServiceCalls -join ',') 'service calls'
}

Invoke-TestCase 'failed first upgrade leaves no previous slot behind' {
    $paths = New-TestInstalledHost -Current '1.0.0'
    $script:FakeHealth.Clear()
    $script:FakeHealth.Enqueue($false)
    $script:FakeHealth.Enqueue($false)
    Assert-Throws { Invoke-TestRealUpgrade -Paths $paths -Target '2.0.0' } 'automatic rollback failed'
    Assert-TestFile $paths.Binary 'binary 1.0.0'
    Assert-True (-not (Test-Path -LiteralPath $paths.PreviousBinary)) 'previous binary was left behind'
    Assert-Equal '' (Read-OneNodeManifest -Paths $paths)['previous_version'] 'previous version'
}

Invoke-TestCase 'upgrade refuses the current version' {
    $paths = New-TestInstalledHost -Current '1.0.0'
    Assert-Throws { Invoke-TestRealUpgrade -Paths $paths -Target '1.0.0' } 'upgrade target 1\.0\.0 is already current'
    Assert-Throws { Invoke-TestRealUpgrade -Paths $paths -Target '1.0' } 'exact three-component'
}

Invoke-TestCase 'rollback swaps the current and previous releases' {
    $paths = New-TestInstalledHost -Current '2.0.0' -Previous '1.0.0'
    $script:ServiceCalls.Clear()
    $script:FakeHealth.Clear()
    $script:FakeHealth.Enqueue($true)
    $script:FakePreviousVersion = '1.0.0'
    Invoke-OneNodeRollback -Paths $paths
    Assert-TestFile $paths.Binary 'binary 1.0.0'
    Assert-TestFile $paths.Installer 'installer 1.0.0'
    Assert-TestFile $paths.PreviousBinary 'binary 2.0.0'
    Assert-TestFile $paths.PreviousInstaller 'installer 2.0.0'
    $manifest = Read-OneNodeManifest -Paths $paths
    Assert-Equal '1.0.0' $manifest['current_version'] 'current version'
    Assert-Equal '2.0.0' $manifest['previous_version'] 'previous version'
    Assert-Equal 'stop,start' ($script:ServiceCalls -join ',') 'service calls'
}

Invoke-TestCase 'rollback refuses a missing or mismatched previous release' {
    $paths = New-TestInstalledHost -Current '2.0.0'
    Assert-Throws { Invoke-OneNodeRollback -Paths $paths } 'no previous version'
    $paths = New-TestInstalledHost -Current '2.0.0' -Previous '1.0.0'
    $script:FakePreviousVersion = '0.1.0'
    Assert-Throws { Invoke-OneNodeRollback -Paths $paths } "reports version '0\.1\.0' instead of 1\.0\.0"
    Assert-TestFile $paths.Binary 'binary 2.0.0'
}

# ---------------------------------------------------------------------------

Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
[Console]::Out.WriteLine("install.ps1 tests: $($script:TestCount - $script:TestFailures)/$($script:TestCount) passed")
if ($script:TestFailures -gt 0) { exit 1 }
exit 0
