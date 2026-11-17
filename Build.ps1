$ErrorActionPreference = 'Stop'

$PackageRepository = if ($env:PACKAGE_REPOSITORY) { $env:PACKAGE_REPOSITORY } else { 'https://dl-cdn.alpinelinux.org' }
if ($PackageRepository -notmatch '^https://[A-Za-z0-9._:/-]+$') {
  Write-Error 'PACKAGE_REPOSITORY must be an https:// URL containing only [A-Za-z0-9._:/-].'
  exit 1
}

& docker build --pull --build-arg "PACKAGE_REPOSITORY=$PackageRepository" --tag devops/ssh-keygen:latest $PSScriptRoot
exit $LASTEXITCODE
