param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$ConfigurationName,

  [Alias('p')]
  [switch]$PromptPassphrase,

  [Alias('c')]
  [switch]$PromptCaPassphrase
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-SecureInput([Security.SecureString]$Secure) {
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Read-Passphrase([string]$Label, [bool]$Confirm) {
  $s1 = Read-Host -Prompt $Label -AsSecureString
  $p1 = ConvertFrom-SecureInput $s1
  if ($Confirm -and $p1.Length -gt 0) {
    $s2 = Read-Host -Prompt "Confirm $Label" -AsSecureString
    $p2 = ConvertFrom-SecureInput $s2
    if ($p1 -cne $p2) {
      throw 'Passphrases do not match.'
    }
  }
  return $p1
}

$keyPass = if ($env:KEY_PASSPHRASE) { $env:KEY_PASSPHRASE } else { '' }
$caPass  = if ($env:CA_PASSPHRASE)  { $env:CA_PASSPHRASE }  else { '' }

if ($PromptPassphrase) {
  $keyPass = Read-Passphrase 'Key passphrase (min 12 chars)' $true
}
if ($PromptCaPassphrase) {
  $confirmCa = $env:REQUEST_NEW_CA_KEY -match '^(true|yes|1)$'
  $caPass = Read-Passphrase 'CA passphrase (min 12 chars)' $confirmCa
}

$keysDir = Join-Path $PSScriptRoot 'workspace/keys'
$caDir   = Join-Path $PSScriptRoot 'workspace/ca'
New-Item -ItemType Directory -Force -Path $keysDir, $caDir | Out-Null

$dockerArgs = @(
  'run', '--rm', '-i',
  '--network', 'none',
  '--read-only',
  '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=16m',
  '--cap-drop', 'ALL',
  '--security-opt', 'no-new-privileges',
  '--pids-limit', '64',
  '--memory', '256m',
  '-v', "${PSScriptRoot}/workspace:/var/ssh-keygen/workspace",
  '-v', "${PSScriptRoot}/workspace/conf:/var/ssh-keygen/workspace/conf:ro",
  '-e', "REQUEST_NEW_CA_KEY=$(if ($env:REQUEST_NEW_CA_KEY) { $env:REQUEST_NEW_CA_KEY } else { 'false' })",
  '-e', "OVERWRITE=$(if ($env:OVERWRITE) { $env:OVERWRITE } else { 'false' })",
  '-e', "OVERWRITE_CA=$(if ($env:OVERWRITE_CA) { $env:OVERWRITE_CA } else { 'false' })"
)

if ($IsLinux -or $IsMacOS) {
  $dockerArgs += @('--user', "$(id -u):$(id -g)")
}

$dockerArgs += @('devops/ssh-keygen:latest', $ConfigurationName)

# Passphrases are piped via STDIN so they never appear in the process list or `docker inspect`.
"$keyPass`n$caPass`n" | & docker @dockerArgs
exit $LASTEXITCODE
