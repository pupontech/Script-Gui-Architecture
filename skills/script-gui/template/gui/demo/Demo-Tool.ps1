<#
  Demo-Tool.ps1 - a stand-in "engine" so a freshly scaffolded window runs out of the box and
  tests\gui\Test-Gui.ps1 has something real to drive. It only writes into -OutDir.
  DELETE this folder once gui\steps.json points at the tool's real scripts.

  It shows the two things a script must do to work under the window:
    * print its question itself, without a line end, then call Read-Host with no argument
      (Windows PowerShell 5.1 does not print Read-Host's own prompt when stdin is redirected);
    * report through its exit code and through files, not only through console text.
  Windows PowerShell 5.1, pure ASCII, no BOM.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('Check', 'Change', 'Report')][string]$Action,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [switch]$Thorough,
    [string]$Note = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

switch ($Action) {
    'Check' {
        Write-Host 'Checking (read-only)...'
        Start-Sleep -Milliseconds 400
        '{ "Items": 3 }' | Set-Content -LiteralPath (Join-Path $OutDir 'check.json') -Encoding ASCII
        Write-Host 'Check finished: 3 items found.'
        exit 0
    }
    'Change' {
        Write-Host ('About to change 3 items.' + $(if ($Thorough) { ' Thorough mode.' } else { '' }))
        Write-Host 'Apply the change? [y/N]' -NoNewline
        $answer = Read-Host
        if ($null -eq $answer -or $answer.Trim() -notmatch '^(?i:y|yes)$') {
            Write-Host 'Not applied.'
            exit 3
        }
        ('applied' + $(if ($Thorough) { ' thorough' } else { '' }) + $(if ($Note) { ' note=' + $Note } else { '' })) | Set-Content -LiteralPath (Join-Path $OutDir 'change.txt') -Encoding ASCII
        Write-Host 'Change applied.'
        exit 0
    }
    'Report' {
        $changed = Test-Path -LiteralPath (Join-Path $OutDir 'change.txt')
        $text = 'Demo report. Changed: ' + $changed
        $text | Set-Content -LiteralPath (Join-Path $OutDir 'report.txt') -Encoding ASCII
        Write-Host ('SUMMARY: ' + $(if ($changed) { '3 items changed' } else { 'nothing changed' }))
        exit 0
    }
}
