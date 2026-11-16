#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\Install-DevelopmentDependencies.ps1" -Destination $TestDrive
}

Describe 'Verified PowerShell module installation' {
    BeforeEach {
        $script:source = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:testDestination = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'Example.psd1') -Value "@{ ModuleVersion = '1.0.0' }"
        $script:testArchive = Join-Path $TestDrive "$([guid]::NewGuid()).zip"
        [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $testArchive)
        $script:hash = (Get-FileHash -LiteralPath $testArchive -Algorithm SHA512).Hash
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:testArchive -Destination $OutFile }
    }

    It 'installs only the archive matching the pinned hash' {
        Install-DevelopmentModule -Name Example -Version 1.0.0 -SHA512 $hash -Destination $script:testDestination
        Test-Path -LiteralPath (Join-Path $script:testDestination 'Example\1.0.0\Example.psd1') | Should -BeTrue
    }

    It 'rejects modified downloads without installing them' {
        { Install-DevelopmentModule -Name Example -Version 1.0.0 -SHA512 ('0' * 128) -Destination $script:testDestination } |
            Should -Throw '*SHA-512 mismatch*'
        Test-Path -LiteralPath $script:testDestination | Should -BeFalse
    }

    It 'refuses to overwrite an existing module version' {
        Install-DevelopmentModule -Name Example -Version 1.0.0 -SHA512 $hash -Destination $script:testDestination
        { Install-DevelopmentModule -Name Example -Version 1.0.0 -SHA512 $hash -Destination $script:testDestination } |
            Should -Throw '*already exists*'
    }
}
