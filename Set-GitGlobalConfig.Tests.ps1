#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests Git identity resolution and the global configuration plan.
.DESCRIPTION
    Pure steps (profile parsing, name selection, plan and command building) are
    tested with plain data. Applying the plan runs real Git against a temporary
    GIT_CONFIG_GLOBAL file. Nothing is mocked.
.EXAMPLE
    Invoke-Pester -Path .\Set-GitGlobalConfig.Tests.ps1
    Runs only the global Git configuration tests.
.INPUTS
    None. Run this file through Pester rather than invoking it directly.
.OUTPUTS
    None. Pester reports results; use Invoke-Pester -PassThru for result objects.
.NOTES
    Requires PowerShell 7, Pester and Git. Real global Git configuration is never
    written. Assert-Precondition, Get-GitHubIdentity and Invoke-Main depend on an
    installed and authenticated gh and are not tested here.
#>
BeforeAll {
    . "$PSScriptRoot\Set-GitGlobalConfig.ps1"
    . "$PSScriptRoot\GitTooling.TestHelpers.ps1"
}

Describe 'ConvertFrom-GitHubUser' {
    It 'returns the trimmed profile name and the noreply email' {
        $identity = ConvertFrom-GitHubUser -Json '{"id":1,"login":"DenWin","name":" Dennis Winter "}'
        $identity.Name | Should -BeExactly 'Dennis Winter'
        $identity.Email | Should -BeExactly '1+DenWin@users.noreply.github.com'
    }

    It 'falls back to the login for the name <Name>' -ForEach @(
        @{ Name = 'null'; Json = '{"id":1,"login":"DenWin","name":null}' }
        @{ Name = 'empty'; Json = '{"id":1,"login":"DenWin","name":""}' }
        @{ Name = 'missing'; Json = '{"id":1,"login":"DenWin"}' }
    ) {
        (ConvertFrom-GitHubUser -Json $Json).Name | Should -BeExactly 'DenWin'
    }

    It 'throws when <Name> is missing' -ForEach @(
        @{ Name = 'id'; Json = '{"login":"DenWin"}' }
        @{ Name = 'login'; Json = '{"id":1,"login":" "}' }
    ) {
        { ConvertFrom-GitHubUser -Json $Json } | Should -Throw '*noreply*'
    }
}

Describe 'Select-GitUserName' {
    It 'returns <Expected> for user name <UserName>' -ForEach @(
        @{ UserName = 'Jane'; Expected = 'Jane' }
        @{ UserName = ''; Expected = 'Profile Name' }
        @{ UserName = ' '; Expected = 'Profile Name' }
    ) {
        Select-GitUserName -UserName $UserName -IdentityName 'Profile Name' | Should -BeExactly $Expected
    }
}

Describe 'Get-GitConfigPlan' {
    BeforeAll {
        $script:plan = Get-GitConfigPlan -UserName 'Jane' -Email 'j@x.com' -Windows $false
    }

    It 'contains identity values' {
        ($plan | Where-Object Key -EQ 'user.name').Value | Should -BeExactly 'Jane'
        ($plan | Where-Object Key -EQ 'user.email').Value | Should -BeExactly 'j@x.com'
    }

    It 'has unique keys' {
        $windowsPlan = Get-GitConfigPlan -UserName 'Jane' -Email 'j@x.com' -Windows $true
        ($windowsPlan.Key | Select-Object -Unique).Count | Should -Be $windowsPlan.Count
    }

    It 'sets <Key> to <Value>' -ForEach @(
        @{ Key = 'core.autocrlf'; Value = 'input' }
        @{ Key = 'pull.rebase'; Value = 'true' }
        @{ Key = 'push.autoSetupRemote'; Value = 'true' }
        @{ Key = 'merge.conflictStyle'; Value = 'zdiff3' }
        @{ Key = 'core.editor'; Value = 'code --wait' }
        @{ Key = 'init.defaultBranch'; Value = 'main' }
        @{ Key = 'transfer.fsckObjects'; Value = 'true' }
        @{ Key = 'protocol.file.allow'; Value = 'user' }
        @{ Key = 'push.followTags'; Value = 'true' }
        @{ Key = 'fetch.writeCommitGraph'; Value = 'true' }
    ) {
        ($plan | Where-Object Key -EQ $Key).Value | Should -BeExactly $Value
    }

    It 'adds Git Credential Manager and long paths only on Windows' {
        $windowsPlan = Get-GitConfigPlan -UserName 'Jane' -Email 'j@x.com' -Windows $true
        ($windowsPlan | Where-Object Key -EQ 'credential.helper').Value | Should -BeExactly 'manager'
        ($windowsPlan | Where-Object Key -EQ 'core.longpaths').Value | Should -BeExactly 'true'
        @($plan | Where-Object Key -In @('credential.helper', 'core.longpaths')).Count | Should -Be 0
    }
}

Describe 'Get-GitConfigCommand' {
    It 'sets an ordinary key in one command' {
        $command = @(Get-GitConfigCommand -Plan @([pscustomobject]@{ Key = 'c.d'; Value = 'x y' }))
        $command.Count | Should -Be 1
        $command[0].Arguments | Should -BeExactly @('config', '--global', 'c.d', 'x y')
        $command[0].FailureMessage | Should -BeExactly "Failed to set git config 'c.d'."
    }

    It 'resets inherited credential helpers before adding the planned helper' {
        $command = @(Get-GitConfigCommand -Plan @([pscustomobject]@{ Key = 'credential.helper'; Value = 'manager' }))
        $command.Count | Should -Be 2
        $command[0].Arguments | Should -BeExactly @('config', '--global', '--replace-all', 'credential.helper', '')
        $command[0].FailureMessage | Should -BeLike '*reset*'
        $command[1].Arguments | Should -BeExactly @('config', '--global', '--add', 'credential.helper', 'manager')
    }
}

Describe 'Format-GitCommand' {
    It 'quotes the final argument: <Expected>' -ForEach @(
        @{ Arguments = @('config', '--global', 'c.d', 'x y'); Expected = "git config --global c.d 'x y'" }
        @{ Arguments = @('config', '--global', '--replace-all', 'credential.helper', ''); Expected = "git config --global --replace-all credential.helper ''" }
    ) {
        Format-GitCommand -Arguments $Arguments | Should -BeExactly $Expected
    }
}

Describe 'Invoke-GitConfigPlan' -Tag 'Integration' {
    BeforeEach {
        $script:configFile = Join-Path $TestDrive "gitconfig-$([guid]::NewGuid().ToString('N'))"
        $script:systemFile = Join-Path $TestDrive "system-$([guid]::NewGuid().ToString('N'))"
        $script:oldGlobal = $env:GIT_CONFIG_GLOBAL
        $script:oldSystem = $env:GIT_CONFIG_SYSTEM
        $env:GIT_CONFIG_GLOBAL = $configFile
        $env:GIT_CONFIG_SYSTEM = $systemFile
        $script:plan = @(
            [pscustomobject]@{ Key = 'a.b'; Value = '1' }
            [pscustomobject]@{ Key = 'c.d'; Value = 'x y' }
        )
    }

    AfterEach {
        $env:GIT_CONFIG_GLOBAL = $oldGlobal
        $env:GIT_CONFIG_SYSTEM = $oldSystem
    }

    It 'writes every entry to the global configuration' {
        Invoke-GitConfigPlan -Plan $plan
        Invoke-Git -Arguments @('config', '--global', 'a.b') | Should -BeExactly '1'
        Invoke-Git -Arguments @('config', '--global', 'c.d') | Should -BeExactly 'x y'
    }

    It 'previews every command without writing with -DryRun' {
        $output = Invoke-Captured { Invoke-GitConfigPlan -Plan $plan -DryRun }
        $output.Host | Should -BeExactly @("[DRY RUN] git config --global a.b '1'", "[DRY RUN] git config --global c.d 'x y'")
        Test-Path -LiteralPath $configFile | Should -BeFalse
    }

    It 'stops at the first failing entry' {
        $badPlan = @([pscustomobject]@{ Key = 'nosection'; Value = '1' }) + $plan
        { Invoke-GitConfigPlan -Plan $badPlan 2>$null } | Should -Throw "Failed to set git config 'nosection'."
        Invoke-Git -AllowFailure -Arguments @('config', '--global', 'a.b') | Should -BeNullOrEmpty
    }

    It 'replaces all global helpers and resets inherited helpers, idempotently' {
        Invoke-Git -Arguments @('config', '--file', $systemFile, 'credential.helper', 'store')
        Invoke-Git -Arguments @('config', '--global', '--add', 'credential.helper', 'store')
        Invoke-Git -Arguments @('config', '--global', '--add', 'credential.helper', 'cache')
        $helperPlan = @([pscustomobject]@{ Key = 'credential.helper'; Value = 'manager' })
        Invoke-GitConfigPlan -Plan $helperPlan
        Invoke-GitConfigPlan -Plan $helperPlan
        Invoke-Git -Arguments @('config', '--global', '--get-all', 'credential.helper') | Should -BeExactly @('', 'manager')
    }
}
