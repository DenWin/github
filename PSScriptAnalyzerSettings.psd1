@{
    Severity = @('Error', 'Warning', 'Information')

    IncludeRules = @(
        'PSAvoidUsingCmdletAliases'
        'PSAvoidGlobalVars'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSMisleadingBacktick'
        'PSPlaceOpenBrace'
        'PSPlaceCloseBrace'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSUseApprovedVerbs'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseSingularNouns'
        'PSUseCompatibleSyntax'
        'PSAvoidTrailingWhitespace'
    )

    Rules = @{
        PSPlaceOpenBrace = @{
            Enable = $true
            OnSameLine = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace = @{
            Enable = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore = $false
        }
        PSUseConsistentIndentation = @{
            Enable = $true
            IndentationSize = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind = 'space'
        }
        PSUseConsistentWhitespace = @{
            Enable = $true
            CheckOpenBrace = $true
            CheckOpenParen = $true
            CheckOperator = $true
            CheckSeparator = $true
            CheckInnerBrace = $true
            CheckPipe = $true
        }
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('7.0')
        }
    }
}
