[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ModuleName')]
param()
Properties {
    $ModuleName = Get-ChildItem ./*/*.psd1 | Select-Object -ExpandProperty BaseName
    $ModuleSrcPath = Resolve-Path "./${ModuleName}"
    $PsakeFilePath = Resolve-Path "./psakefile.ps1"
}

Task default -Depends TestAll

Task TestAll -Depends Lint, Test

Task Lint {
    $ModuleSrcPath, $PsakeFilePath | ForEach-Object {
        Write-Host "Linting ${_}..."
        $warn = Invoke-ScriptAnalyzer -Path $_ -Settings PSScriptAnalyzerSettings.psd1
        if ($warn) {
            $warn
            throw "Invoke-ScriptAnalyzer for ${_} failed."
        }
    }
}

Task Test {
    'Test is running!'
    # TODO: add Pester tests
}
