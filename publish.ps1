Param (
    [string]
    $ApiKey,
    [string]
    [ValidateSet('Publish', 'DryRun')]
    $Mode = 'DryRun'
)

$ModuleName = Get-ChildItem -File -Path ./ -Recurse -Name '*.psd1' | Split-Path -Parent
$ArtifactPath = ".\$ModuleName\"
Write-Host "Checking modules under $ArtifactPath"

$report = Invoke-ScriptAnalyzer -Path "$ArtifactPath" -Recurse -Settings PSGallery
if ($report) {
    Write-Host 'Violation found.'
    $report
    exit
}
Write-Host 'Check OK.'

$Params = @{
    Path = $ArtifactPath
    ApiKey = $ApiKey
    Verbose = $true
    WhatIf = switch ($Mode) {
        'Publish' {
            Write-Host "Publishing module: $ModuleName"
            $false
        }
        'DryRun' {
            Write-Host "[DRY-RUN]Publishing module: $ModuleName"
            $true
        }
    }
}

Publish-PSResource @Params

if ($?) {
    Write-Host 'publishing succeed.'
}
else {
    Write-Error 'publishing failed.'
}
