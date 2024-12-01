Param(
    [Parameter(HelpMessage = "The repository of the action", Mandatory = $false)]
    [string] $actionsRepo,
    [Parameter(HelpMessage = "The ref of the action", Mandatory = $false)]
    [string] $actionsRef
)

. (Join-Path -Path $PSScriptRoot -ChildPath "..\Acora-Apps-Helper.ps1" -Resolve)
. (Join-Path -Path $PSScriptRoot -ChildPath "..\Acora-TestRepoHelper.ps1" -Resolve)

if ($actionsRepo -eq 'AcoraLimited/ACO_AppsGitHubActions') {
    Write-Host "Using Acora Actions for GitHub {$actionsRef}"
    $verstr = $actionsRef
}
elseif ($actionsRepo -eq 'AcoraLimited/AC_AppsBCTemplate') {
    Write-Host "Using Acora for GitHub Preview ($actionsRef)"
    $verstr = "p"
}
else {
    Write-Host "Using direct Acora development ($($actionsRepo)@$actionsRef)"
    $verstr = "d"
}

Write-Big -str "a$verstr"

# Test the Acora repository is set up correctly
TestAcoraRepository

# Test the prerequisites for the test runner
TestRunnerPrerequisites

# Create a json object that contains an entry for the workflowstarttime
$scopeJson = @{
    "workflowStartTime" = [DateTime]::UtcNow
} | ConvertTo-Json -Compress

Add-Content -Encoding UTF8 -Path $env:GITHUB_OUTPUT -Value "telemetryScopeJson=$scopeJson"
