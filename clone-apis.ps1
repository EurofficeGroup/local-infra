<#
.SYNOPSIS
    Clones the satellite API repositories next to this one, so the "apis"
    compose profile has something to build from.

.DESCRIPTION
    Five services sit behind the "Use local" radio buttons in WebConfigPicker.
    Two are already here (api.configuration, api.tax); the rest are not.

    The folder names are not arbitrary - WebConfigPicker looks the repositories
    up by name under the workspace folder (GetWorkspaceProjectFolder in
    MainWindow.xaml.cs), and docker-compose.yml uses the same paths as build
    contexts. Keep them as written below.

    Elasticsearch's API is deliberately absent: the index is too large to host
    locally, so SearchApiServiceUrl stays pointed at TEST4.

    No credentials are set up here. If the clone asks for a password, sign in to
    GitHub for the EurofficeGroup org first - these are private repositories.

.EXAMPLE
    .\clone-apis.ps1

.EXAMPLE
    .\clone-apis.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Where the repositories live side by side. The parent of this one.
    [string] $Workspace = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

# folder name  ->  repository name in the EurofficeGroup org.
# The folders are short; the repositories are not. Both are load-bearing.
$Repos = [ordered] @{
    'api.pricing'  = 'eurofficegroup.api.pricing'
    'api.product'  = 'eurofficegroup.api.product'
    'api.audience' = 'eurofficegroup.api.audience'
    'api.payments' = 'eurofficegroup.api.payments'
}

foreach ($folder in $Repos.Keys) {
    $repo   = $Repos[$folder]
    $target = Join-Path $Workspace $folder

    if (Test-Path $target) {
        Write-Host "$folder  already present - skipped"
        continue
    }

    $url = "https://github.com/EurofficeGroup/$repo.git"

    if ($PSCmdlet.ShouldProcess($target, "git clone $url")) {
        Write-Host ''
        Write-Host "$folder  <-  $repo"
        git clone $url $target
        if ($LASTEXITCODE -ne 0) {
            throw "Clone of $repo failed. Check the repository name on GitHub - the org renames these occasionally."
        }
    }
}

Write-Host ''
Write-Host 'Next:'
Write-Host '  1. docker compose --profile apis build'
Write-Host '  2. docker compose --profile apis up -d'
Write-Host '  3. .\power-local-setup.ps1        (points the IIS sites at them)'
