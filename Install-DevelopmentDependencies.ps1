#Requires -Version 7.0

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-DevelopmentModule {
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d+\.\d+\.\d+$')]
        [string] $Version,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Fa-f0-9]{128}$')]
        [string] $SHA512,

        [Parameter(Mandatory)]
        [string] $Destination
    )

    $modulePath = Join-Path (Join-Path $Destination $Name) $Version
    if (Test-Path -LiteralPath $modulePath) {
        throw "Module destination already exists: $modulePath"
    }

    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("git-setup-module-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $archive = Join-Path $temporary 'package.zip'
        $url = "https://www.powershellgallery.com/api/v2/package/$Name/$Version"
        Invoke-WebRequest -Uri $url -OutFile $archive
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash
        if ($actual -ne $SHA512) {
            throw "SHA-512 mismatch for ${Name}:${Version}; refusing to install."
        }

        $extracted = Join-Path $temporary 'module'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
        if (-not (Test-Path -LiteralPath (Join-Path $extracted "$Name.psd1") -PathType Leaf)) {
            throw "Verified archive for ${Name}:${Version} does not contain its module manifest."
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $modulePath) -Force | Out-Null
        Move-Item -LiteralPath $extracted -Destination $modulePath
        Write-Host "Installed verified ${Name}:${Version} in $modulePath"
    }
    finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}

function Install-DevelopmentDependency {
    param ([Parameter(Mandatory)] [string] $Destination)

    $dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
    $hashes = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencyHashes.psd1')
    if ($dependencies.Count -ne $hashes.Count) {
        throw 'Dependency versions and package hash pins do not match.'
    }
    foreach ($name in $dependencies.Keys) {
        if (-not $hashes.ContainsKey($name) -or $hashes[$name].Version -ne $dependencies[$name]) {
            throw "Missing or mismatched package hash pin for '$name'."
        }
    }
    foreach ($name in $dependencies.Keys) {
        Install-DevelopmentModule -Name $name -Version $dependencies[$name] -SHA512 $hashes[$name].SHA512 -Destination $Destination
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Install-DevelopmentDependency -Destination $Destination
}
