[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string[]] $SourceName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell session.'
}

$messageResource = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\EventLogMessages.dll"
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\EventLogMessages.dll"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $messageResource) {
    throw 'The Windows .NET Framework event-message resource could not be found.'
}

$applicationKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application'

foreach ($source in $SourceName) {
    $source = $source.Trim()
    if ([string]::IsNullOrWhiteSpace($source)) {
        throw 'An event source name cannot be empty.'
    }
    if ($source.Contains('\')) {
        throw "The event source name '$source' cannot contain a backslash."
    }

    if ([Diagnostics.EventLog]::SourceExists($source)) {
        $registeredLog = [Diagnostics.EventLog]::LogNameFromSourceName($source, '.')
        if ($registeredLog -ne 'Application') {
            throw "The event source '$source' is already registered for the '$registeredLog' log."
        }
    }
    else {
        New-EventLog -LogName Application -Source $source -MessageResourceFile $messageResource
    }

    $sourceKey = Join-Path -Path $applicationKey -ChildPath $source
    New-ItemProperty -LiteralPath $sourceKey -Name EventMessageFile -Value $messageResource `
        -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -LiteralPath $sourceKey -Name TypesSupported -Value 7 `
        -PropertyType DWord -Force | Out-Null

    Write-Output "Registered '$source' for the Windows Application log."
}
