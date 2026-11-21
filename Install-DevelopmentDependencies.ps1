#Requires -Version 7.0

<#
.SYNOPSIS
    Installs development modules from SHA-512-verified PowerShell Gallery archives.
.DESCRIPTION
    Reads exact versions from DevelopmentDependencies.psd1 and matching hashes
    from DevelopmentDependencyHashes.psd1 beside this script. Downloads each
    archive over HTTPS, verifies its SHA-512 before extraction, checks for the
    expected manifest, and moves it into a versioned module directory.
    Does not download implicit dependencies or import modules into the session.
.PARAMETER Destination
    Required module root. Modules are installed as <Destination>\<Name>\<Version>.
    Missing parent directories are created; existing module versions are refused.
.EXAMPLE
    .\Install-DevelopmentDependencies.ps1 -Destination C:\Tools\VerifiedModules
    Installs the pinned modules into a dedicated module root.
.EXAMPLE
    $modules = Join-Path $HOME 'verified-powershell-modules'
    .\Install-DevelopmentDependencies.ps1 -Destination $modules
    $env:PSModulePath = "$modules$([System.IO.Path]::PathSeparator)$env:PSModulePath"
    Installs modules and makes them discoverable in the current PowerShell session.
.INPUTS
    None. This script does not accept pipeline input.
.OUTPUTS
    None. Installation status is written to the host.
.NOTES
    Requires network access to PowerShell Gallery and write access to Destination.
    Failures stop installation and temporary downloads are cleaned up. Cleanup
    failures are reported without replacing an installation failure. Modules
    installed before a failure remain installed; use a fresh destination to retry
    the complete set. Hash pins detect archive changes, not publisher trust.
    Dot-sourcing with Destination loads functions without installing modules.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Install-ModuleArchive {
    <#
    .SYNOPSIS
        Verifies a downloaded module archive against its pin and installs it.
    .DESCRIPTION
        Extracts into WorkingDirectory, which the caller owns and removes.
        Nothing is written below Destination unless the hash and manifest match.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Archive,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Version,

        [Parameter(Mandatory)]
        [string] $SHA512,

        [Parameter(Mandatory)]
        [string] $Destination,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    $modulePath = Join-Path (Join-Path $Destination $Name) $Version
    if (Test-Path -LiteralPath $modulePath) {
        throw "Module destination already exists: $modulePath"
    }
    $actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA512).Hash
    if ($actual -ne $SHA512) {
        throw "SHA-512 mismatch for ${Name}:${Version}; refusing to install."
    }

    $extracted = Join-Path $WorkingDirectory 'module'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $extracted)
    if (-not (Test-Path -LiteralPath (Join-Path $extracted "$Name.psd1") -PathType Leaf)) {
        throw "Verified archive for ${Name}:${Version} does not contain its module manifest."
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $modulePath) -Force | Out-Null
    Move-Item -LiteralPath $extracted -Destination $modulePath
    Write-Host "Installed verified ${Name}:${Version} in $modulePath"
}

function Remove-TemporaryDirectory {
    <#
    .SYNOPSIS
        Removes a temporary directory without hiding an earlier installation error.
    .DESCRIPTION
        A removal failure is thrown when there is no InstallationError. Otherwise
        it is written as a non-terminating error so the caller rethrows the
        installation error, which is the root cause.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        $InstallationError
    )

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        if ($null -eq $InstallationError) {
            throw
        }
        Write-Error `
            -Message "Could not remove temporary directory '$Path': $($_.Exception.Message). The installation error is preserved." `
            -ErrorAction Continue
    }
}

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

    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("git-setup-module-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $temporary | Out-Null
    $installationError = $null
    try {
        $archive = Join-Path $temporary 'package.zip'
        Invoke-WebRequest -Uri "https://www.powershellgallery.com/api/v2/package/$Name/$Version" -OutFile $archive
        Install-ModuleArchive -Archive $archive -Name $Name -Version $Version -SHA512 $SHA512 `
            -Destination $Destination -WorkingDirectory $temporary
    }
    catch {
        $installationError = $_
        throw
    }
    finally {
        Remove-TemporaryDirectory -Path $temporary -InstallationError $installationError
    }
}

function Get-DependencyPinProblem {
    <#
    .SYNOPSIS
        Returns why the version and hash pin files disagree, or nothing when they match.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable] $Dependency,

        [Parameter(Mandatory)]
        [hashtable] $Hash
    )

    if ($Dependency.Count -ne $Hash.Count) {
        return 'Dependency versions and package hash pins do not match.'
    }
    foreach ($name in $Dependency.Keys) {
        if (-not $Hash.ContainsKey($name) -or $Hash[$name].Version -ne $Dependency[$name]) {
            return "Missing or mismatched package hash pin for '$name'."
        }
    }
}

function Install-DevelopmentDependency {
    param ([Parameter(Mandatory)] [string] $Destination)

    $dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
    $hashes = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencyHashes.psd1')
    $problem = Get-DependencyPinProblem -Dependency $dependencies -Hash $hashes
    if ($problem) {
        throw $problem
    }
    foreach ($name in $dependencies.Keys) {
        Install-DevelopmentModule -Name $name -Version $dependencies[$name] -SHA512 $hashes[$name].SHA512 -Destination $Destination
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Install-DevelopmentDependency -Destination $Destination
}
