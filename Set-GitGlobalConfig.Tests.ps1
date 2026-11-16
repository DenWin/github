#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\Set-GitGlobalConfig.ps1"
}

Describe 'Assert-Precondition' {
    It 'throws when git is missing' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'git' }
        { Assert-Precondition } | Should -Throw '*Git is not installed*'
    }

    It 'throws when gh is missing' {
        Mock Get-Command { 'git' } -ParameterFilter { $Name -eq 'git' }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
        { Assert-Precondition } | Should -Throw '*GitHub CLI (gh) is not installed*'
    }

    It 'throws when gh is not authenticated' {
        Mock Get-Command { 'x' }
        Mock Invoke-Gh { $global:LASTEXITCODE = 1 }
        { Assert-Precondition } | Should -Throw '*not authenticated*'
    }

    It 'passes when everything is available' {
        Mock Get-Command { 'x' }
        Mock Invoke-Gh { $global:LASTEXITCODE = 0 }
        { Assert-Precondition } | Should -Not -Throw
    }
}

Describe 'Get-GitHubIdentity' {
    It 'returns profile name and noreply email' {
        Mock Invoke-Gh { $global:LASTEXITCODE = 0; '{"id":1,"login":"DenWin","name":" Dennis Winter "}' }
        $identity = Get-GitHubIdentity
        $identity.Name | Should -Be 'Dennis Winter'
        $identity.Email | Should -Be '1+DenWin@users.noreply.github.com'
    }

    It 'falls back to the login when the profile has no name' -ForEach @(
        @{ Json = '{"id":1,"login":"DenWin","name":null}' }
        @{ Json = '{"id":1,"login":"DenWin","name":""}' }
    ) {
        Mock Invoke-Gh { $global:LASTEXITCODE = 0; $Json }
        (Get-GitHubIdentity).Name | Should -Be 'DenWin'
    }

    It 'throws on gh failure' {
        Mock Invoke-Gh { $global:LASTEXITCODE = 1 }
        { Get-GitHubIdentity } | Should -Throw '*user profile*'
    }

    It 'throws when id or login is missing' {
        Mock Invoke-Gh { $global:LASTEXITCODE = 0; '{"name":"x"}' }
        { Get-GitHubIdentity } | Should -Throw '*noreply*'
    }
}

Describe 'Get-GitConfigPlan' {
    BeforeAll {
        $script:plan = Get-GitConfigPlan -UserName 'Jane' -Email 'j@x.com'
    }

    It 'contains identity values' {
        ($plan | Where-Object Key -EQ 'user.name').Value | Should -Be 'Jane'
        ($plan | Where-Object Key -EQ 'user.email').Value | Should -Be 'j@x.com'
    }

    It 'has unique keys' {
        ($plan.Key | Select-Object -Unique).Count | Should -Be $plan.Count
    }

    It 'contains expected settings' -ForEach @(
        @{ Key = 'core.autocrlf'; Value = 'input' }
        @{ Key = 'pull.rebase'; Value = 'true' }
        @{ Key = 'push.autoSetupRemote'; Value = 'true' }
        @{ Key = 'merge.conflictStyle'; Value = 'zdiff3' }
        @{ Key = 'core.editor'; Value = 'code --wait' }
        @{ Key = 'init.defaultBranch'; Value = 'main' }
    ) {
        ($plan | Where-Object Key -EQ $Key).Value | Should -Be $Value
    }
}

Describe 'Invoke-GitConfigPlan' {
    BeforeAll {
        $script:plan = @(
            [pscustomobject]@{ Key = 'a.b'; Value = '1'; Section = 'S' }
            [pscustomobject]@{ Key = 'c.d'; Value = 'x y'; Section = 'S' }
        )
    }

    It 'writes every entry' {
        Mock Invoke-Git { $global:LASTEXITCODE = 0 }
        Invoke-GitConfigPlan -Plan $plan
        Should -Invoke Invoke-Git -Times 2 -Exactly
        Should -Invoke Invoke-Git -ParameterFilter { $args[2] -eq 'c.d' -and $args[3] -eq 'x y' }
    }

    It 'does not write anything with -DryRun' {
        Mock Invoke-Git { }
        Mock Write-Host { }
        Invoke-GitConfigPlan -Plan $plan -DryRun
        Should -Invoke Invoke-Git -Times 0 -Exactly
        Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter { $Object -like '`[DRY RUN`]*' }
    }

    It 'throws when git fails' {
        Mock Invoke-Git { $global:LASTEXITCODE = 1 }
        { Invoke-GitConfigPlan -Plan $plan } | Should -Throw "*Failed to set git config 'a.b'*"
    }
}

Describe 'Invoke-Main' {
    BeforeEach {
        Mock Assert-Precondition { }
        Mock Get-GitHubIdentity { [pscustomobject]@{ Name = 'Profile Name'; Email = 'j@x.com' } }
        Mock Invoke-GitConfigPlan { }
        Mock Show-GitConfigResult { }
        Mock Write-Host { }
    }

    It 'uses the GitHub profile name when no UserName is given' {
        Invoke-Main
        Should -Invoke Invoke-GitConfigPlan -Times 1 -Exactly -ParameterFilter {
            ($Plan | Where-Object Key -EQ 'user.name').Value -eq 'Profile Name'
        }
    }

    It 'prefers an explicit UserName' {
        Invoke-Main -UserName 'Jane'
        Should -Invoke Invoke-GitConfigPlan -Times 1 -Exactly -ParameterFilter {
            ($Plan | Where-Object Key -EQ 'user.name').Value -eq 'Jane'
        }
    }

    It 'applies config and shows result' {
        Invoke-Main -UserName 'Jane'
        Should -Invoke Invoke-GitConfigPlan -Times 1 -Exactly -ParameterFilter { -not $DryRun }
        Should -Invoke Show-GitConfigResult -Times 1 -Exactly
    }

    It 'passes DryRun through and skips the result listing' {
        Invoke-Main -UserName 'Jane' -DryRun
        Should -Invoke Invoke-GitConfigPlan -Times 1 -Exactly -ParameterFilter { $DryRun }
        Should -Invoke Show-GitConfigResult -Times 0 -Exactly
    }

    It 'stops when preconditions fail' {
        Mock Assert-Precondition { throw 'nope' }
        { Invoke-Main -UserName 'Jane' } | Should -Throw 'nope'
        Should -Invoke Invoke-GitConfigPlan -Times 0 -Exactly
    }
}
