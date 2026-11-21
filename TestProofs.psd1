# Data for Invoke-TestProof.ps1. See its comment-based help for the method.
@{
    # Applied to every proven function: "no result" and "a slightly wrong result".
    DefaultStub = @(
        'return'
        "return 'unexpected'"
    )

    # Scripts whose functions are also proven from other scripts' test files.
    SharedScript = @('GitTooling.Common.ps1')

    # Describe blocks whose name is not the function they test.
    DescribeTarget = @{
        'Opt-in local hooks' = 'Invoke-RepositorySecurity'
        'Remove-StaleGitWorktree.ps1' = 'Invoke-WorktreeCleanup'
    }

    # Additional stubs per function, for wrong results the defaults cannot model.
    # Tests asserting that something is NOT done (WhatIf, keep, preserve) pass
    # against a stub that does nothing, so they need a stub that does it anyway.
    Stub = @{
        # Installs hooks ignoring WhatIf and fails when they are already installed.
        'Invoke-RepositorySecurity' = @(
            @'
if (Invoke-Git -AllowFailure -Arguments @('-C', $Path, 'config', '--local', '--get', 'core.hooksPath')) { throw 'Hooks already installed.' }
Invoke-Git -Arguments @('-C', $Path, 'config', '--local', 'core.hooksPath', '.githooks')
'@
        )
        # Removes every worktree folder, ignoring staleness, detached HEADs and WhatIf.
        'Remove-StaleRepositoryWorktree' = @(
            @'
Get-ChildItem -LiteralPath $RepositoryRoot -Directory | Where-Object Name -NE '.git' |
    Remove-Item -Recurse -Force -WhatIf:$false -Confirm:$false
'@
        )
        # Cleans every repository of the owner, ignoring the selected repository, branch and WhatIf.
        'Invoke-WorktreeCleanup' = @(
            @'
$target = Resolve-GitHubTarget -GitHubOwner $GitHubOwner -Url $Url
foreach ($repository in Get-ChildItem -LiteralPath (Join-Path $TargetDirectory $target.Owner) -Directory) {
    Remove-StaleRepositoryWorktree -RepositoryRoot $repository.FullName -Apply -WhatIf:$false 6>$null
}
'@
        )
        # Overwrites any configured upstream with origin/<branch>.
        'New-BranchWorktree' = @(
            @'
Invoke-Git -Arguments @('-C', $BareRepository, 'branch', "--set-upstream-to=origin/$Branch", $Branch) | Out-Null
'@
        )
        # Reports failure although every repository synchronized.
        'Invoke-RepositorySync' = @(
            "throw 'Synchronization incomplete.'"
        )
    }
}
