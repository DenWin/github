# PSScriptAnalyzer settings used by Invoke-Checks.ps1 for every PowerShell file in
# the repository. Rule names and options are defined by PSScriptAnalyzer (pinned
# to 1.25.0); reference: https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/readme
@{
    # Report findings of every severity. 'Information' is required, because
    # PSAvoidTrailingWhitespace reports at that level and would otherwise be hidden.
    Severity = @('Error', 'Warning', 'Information')

    # Only the rules listed here run; all other built-in rules are skipped, even
    # those PSScriptAnalyzer enables by default (for example empty catch blocks or
    # missing ShouldProcess support). Add a rule here to enforce it.
    IncludeRules = @(
        # Readability and maintainability
        'PSAvoidUsingCmdletAliases'            # Full command names instead of aliases such as 'gci' or 'where'.
        'PSAvoidGlobalVars'                    # No $global: variables; state stays in script or function scope.
        'PSUseDeclaredVarsMoreThanAssignments' # Flags variables that are assigned but never read.
        'PSUseApprovedVerbs'                   # Function verbs from Get-Verb, so names are discoverable and consistent.
        'PSUseSingularNouns'                   # Singular nouns in function names (Get-Item, not Get-Items).

        # Security
        'PSAvoidUsingInvokeExpression'         # No Invoke-Expression; executing strings risks code injection.
        'PSAvoidUsingPlainTextForPassword'     # Password-like parameters must use SecureString or PSCredential.

        # Correctness
        'PSMisleadingBacktick'                 # A backtick followed by whitespace looks like, but is not, a line continuation.
        'PSUseCompatibleSyntax'                # No syntax newer than the TargetVersions configured below.

        # Formatting; options are configured under Rules below
        'PSPlaceOpenBrace'
        'PSPlaceCloseBrace'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSAvoidTrailingWhitespace'            # No spaces or tabs at line ends.
    )

    # Rule options. Formatting rules are disabled by default in PSScriptAnalyzer,
    # so Enable = $true is required. The other values match PSScriptAnalyzer's
    # documented defaults; they are stated explicitly to pin the style.
    Rules = @{
        PSPlaceOpenBrace = @{
            Enable = $true
            OnSameLine = $true          # '{' on the same line as the keyword: 'if ($x) {'.
            NewLineAfter = $true        # Line break after '{'.
            IgnoreOneLineBlock = $true  # Allow '{ ... }' on one line.
        }
        PSPlaceCloseBrace = @{
            Enable = $true
            NewLineAfter = $true        # Line break after '}'.
            IgnoreOneLineBlock = $true  # Allow '{ ... }' on one line.
            NoEmptyLineBefore = $false  # Empty lines before '}' are not flagged.
        }
        PSUseConsistentIndentation = @{
            Enable = $true
            IndentationSize = 4
            # Continuation lines of a multi-line pipeline are indented one level.
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind = 'space'
        }
        PSUseConsistentWhitespace = @{
            Enable = $true
            CheckOpenBrace = $true      # Space before '{': 'foo {', not 'foo{'.
            CheckOpenParen = $true      # Space between keyword and '(': 'if (', not 'if('.
            CheckOperator = $true       # Spaces around operators: '$x = 1', not '$x=1'.
            CheckSeparator = $true      # Space after ',' and ';'.
            CheckInnerBrace = $true     # Spaces inside braces: '{ foo }', not '{foo}'.
            CheckPipe = $true           # Spaces around '|': 'foo | bar'.
        }
        PSUseCompatibleSyntax = @{
            Enable = $true
            # Matches '#Requires -Version 7.0' in the repository scripts.
            TargetVersions = @('7.0')
        }
    }
}
