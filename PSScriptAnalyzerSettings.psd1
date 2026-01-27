@{
    # PSScriptAnalyzer settings for AGenesysToolKit
    Severity = @('Error', 'Warning', 'Information')
    
    IncludeRules = @(
        'PSAvoidDefaultValueForMandatoryParameter',
        'PSAvoidDefaultValueSwitchParameter',
        'PSAvoidGlobalVars',
        'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingComputerNameHardcoded',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingEmptyCatchBlock',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingPositionalParameters',
        'PSAvoidUsingWMICmdlet',
        'PSUseBOMForUnicodeEncodedFile',
        'PSUseCmdletCorrectly',
        'PSUseCompatibleCmdlets',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseOutputTypeCorrectly',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSUseToExportFieldsInManifest'
    )
    
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'  # Allow Write-Host for console output
    )
}