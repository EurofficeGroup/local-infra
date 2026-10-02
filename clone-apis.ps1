<#
.SYNOPSIS
    Clones - or updates - every repository the local Docker stack builds from,
    next to this one. setup-local.bat runs it on every setup.

.DESCRIPTION
    The images are built from the working copies in the workspace folder
    (build contexts ../noodles, ../api.configuration, ../api.tax, ...), not from
    a registry. So whatever is checked out there is what runs - change code in
    C:\workspace\api.tax, rebuild (ops-local.bat apis-rebuild), and the container
    runs your change. To debug one service, stop its container and run that
    project from Rider: it reaches the other containers by the same hostnames.

    For each repository:
      missing                        git clone
      present, clean working copy    git pull --ff-only on the current branch
      present, local changes         left alone (your edits are never touched)
      present, pull not possible     left alone with a warning (diverged branch,
                                     no upstream, detached HEAD, no network)

    The folder names are not arbitrary - WebConfigPicker looks the repositories
    up by name under the workspace folder (GetWorkspaceProjectFolder in
    MainWindow.xaml.cs), and the compose files use the same paths as build
    contexts. Keep them as written below.

    Elasticsearch's API is deliberately absent: the index is too large to host
    locally, so SearchApiServiceUrl stays pointed at TEST4.

    No credentials are set up here. If git asks for a password, sign in to
    GitHub for the EurofficeGroup org first - these are private repositories.

.EXAMPLE
    .\clone-apis.ps1

.EXAMPLE
    .\clone-apis.ps1 -NoPull      # only clone what is missing

.EXAMPLE
    .\clone-apis.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Where the repositories live side by side. The parent of this one.
    [string] $Workspace,

    # Clone missing repositories only; do not pull existing ones.
    [switch] $NoPull
)

$ErrorActionPreference = 'Stop'

# Resolved here, not in param(): Windows PowerShell 5.1 leaves $PSScriptRoot
# empty while evaluating parameter defaults.
if (-not $Workspace) {
    $Workspace = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

# folder name  ->  repository name in the EurofficeGroup org.
# The folders are short; the repositories are not. Both are load-bearing.
$Repos = [ordered] @{
    'noodles'           = 'noodles'                            # docker-compose.noodles.yml
    'api.configuration' = 'eurofficegroup.api.configuration'   # config-api
    'api.tax'           = 'eurofficegroup.api.tax'
    'api.pricing'       = 'eurofficegroup.api.pricing'
    'api.product'       = 'eurofficegroup.api.product'
    'api.audience'      = 'eurofficegroup.api.audience'
    'api.payments'      = 'eurofficegroup.api.payments'
}

$warnings = @()

foreach ($folder in $Repos.Keys) {
    $repo   = $Repos[$folder]
    $target = Join-Path $Workspace $folder
    $url    = "https://github.com/EurofficeGroup/$repo.git"

    if (-not (Test-Path $target)) {
        if ($PSCmdlet.ShouldProcess($target, "git clone $url")) {
            Write-Host ''
            Write-Host "$folder  <-  $repo  (clone)"
            git clone $url $target
            if ($LASTEXITCODE -ne 0) {
                throw "Clone of $repo failed. Check GitHub access and the repository name - the org renames these occasionally."
            }
        }
        continue
    }

    if ($NoPull) {
        Write-Host "$folder  present - skipped (-NoPull)"
        continue
    }

    if (-not (Test-Path (Join-Path $target '.git'))) {
        $warnings += "$folder exists but is not a git repository - not updated."
        continue
    }

    $branch = git -C $target branch --show-current
    $dirty  = git -C $target status --porcelain --untracked-files=no
    if ($dirty) {
        Write-Host "$folder  [$branch]  has local changes - not pulled"
        continue
    }
    if (-not $branch) {
        $warnings += "$folder is on a detached HEAD - not pulled."
        continue
    }

    if ($PSCmdlet.ShouldProcess($target, "git pull --ff-only ($branch)")) {
        Write-Host "$folder  [$branch]  pulling ..."
        # Native stderr must not stop the script: a failed pull is a warning.
        $ErrorActionPreference = 'Continue'
        $out = git -C $target pull --ff-only 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) {
            $warnings += "$folder [$branch]: git pull --ff-only failed - building from the current checkout. $(($out | Select-Object -Last 1))"
        }
    }
}

if ($warnings) {
    Write-Host ''
    foreach ($w in $warnings) { Write-Host "WARNING: $w" -ForegroundColor Yellow }
}

Write-Host ''
Write-Host 'Next (setup-local.bat does these for you):'
Write-Host '  1. docker compose -f docker-compose.noodles.yml build noodles-build'
Write-Host '  2. docker compose -f docker-compose.api.yml build'
Write-Host '  3. docker compose -f docker-compose.api.yml up -d'
