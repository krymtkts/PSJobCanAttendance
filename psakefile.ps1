[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ModuleName')]
param()
Properties {
    $ModuleName = Get-ChildItem -File -Path ./ -Recurse -Name '*.psm1' | Split-Path -Parent
}

Task default -Depends TestAll

Task TestAll -Depends Lint, Test

Task Lint {
    $warn = Invoke-ScriptAnalyzer -Path "./${ModuleName}" -Settings PSScriptAnalyzerSettings.psd1
    if ($warn) {
        $warn
        throw 'Invoke-ScriptAnalyzer for {ModuleName} failed.'
    }
    $warn = Invoke-ScriptAnalyzer -Path ./*.ps1 -Settings PSScriptAnalyzerSettings.psd1
    if ($warn) {
        $warn
        throw 'Invoke-ScriptAnalyzer for ops scripts failed.'
    }
}

Task Test {
    'Test is running!'
    # TODO: add Pester tests
}
