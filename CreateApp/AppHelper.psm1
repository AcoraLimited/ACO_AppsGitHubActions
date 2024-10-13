<#
This module contains some useful functions for working with app manifests.
#>

. (Join-Path -path $PSScriptRoot -ChildPath "..\Acora-Apps-Helper.ps1" -Resolve)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$alTemplatePath = Join-Path -Path $here -ChildPath "AppTemplate"


$validRanges = @{
    "PTE"                  = "50000..69999";
    "AppSource App"        = "100000..$([int32]::MaxValue)";
    "Test App"             = "70000..89999" ;
    "Performance Test App" = "50000..$([int32]::MaxValue)" ;
};

<#
.SYNOPSIS
Check that the IdRange is valid for the template type.
#>
function ConfirmIdRanges([string] $templateType, [string]$idrange ) {
    $validRange = $validRanges.$templateType.Replace('..', '-').Split("-")
    $validStart = [int] $validRange[0]
    $validEnd = [int] $validRange[1]

    $ids = $idrange.Replace('..', '-').Split("-")
    $idStart = [int] $ids[0]
    $idEnd = [int] $ids[1]

    if ($ids.Count -ne 2 -or ($idStart) -lt $validStart -or $idStart -gt $idEnd -or $idEnd -lt $validStart -or $idEnd -gt $validEnd -or $idStart -gt $idEnd) {
        throw "IdRange should be formatted as fromId..toId, and the Id range must be in $($validRange[0]) and $($validRange[1])"
    }

    return $ids
}

<#
.SYNOPSIS
Creates a simple app.
#>
function NewSampleApp
(
    [string] $destinationPath,
    [string] $name,
    [string] $publisher,
    [string] $version,
    [string[]] $idrange,
    [bool] $sampleCode
)
{
    Write-Host "Creating a new sample app in: $destinationPath"
    New-Item  -Path $destinationPath -ItemType Directory -Force | Out-Null
    New-Item  -Path "$($destinationPath)\.vscode" -ItemType Directory -Force | Out-Null
    Copy-Item -path "$($alTemplatePath)\.vscode\launch.json" -Destination "$($destinationPath)\.vscode\launch.json"

    UpdateManifest -appJsonFile "$($destinationPath)\app.json" -name $name-idrange $idrange -version $version
    if ($sampleCode) {
        UpdateALFile -destinationFolder $destinationPath -alFileName "HelloWorld.al" -startId $idrange[0]
    }
}


<#
.SYNOPSIS
Creates a test app.
#>
function NewSampleTestApp
(
    [string] $destinationPath,
    [string] $name,
    [string] $version,
    [string[]] $idrange,
    [bool] $sampleCode
)
{
    Write-Host "Creating a new test app in: $destinationPath"
    New-Item  -Path $destinationPath -ItemType Directory -Force | Out-Null
    New-Item  -Path "$($destinationPath)\.vscode" -ItemType Directory -Force | Out-Null
    Copy-Item -path "$($alTemplatePath)\.vscode\launch.json" -Destination "$($destinationPath)\.vscode\launch.json"

    UpdateManifest -appJsonFile "$($destinationPath)\app.json" -name $name -idrange $idrange -version $version -AddTestDependencies
    if ($sampleCode) {
        UpdateALFile -destinationFolder $destinationPath -alFileName "HelloWorld.Test.al" -startId $idrange[0]
    }
}

<#
.SYNOPSIS
Creates a performance test app.
#>
function NewSamplePerformanceTestApp
(
    [string] $destinationPath,
    [string] $name,
    [string] $version,
    [string[]] $idrange,
    [bool] $sampleCode,
    [bool] $sampleSuite,
    [string] $appSourceFolder
)
{
    Write-Host "Creating a new performance test app in: $destinationPath"
    New-Item  -Path $destinationPath -ItemType Directory -Force | Out-Null
    New-Item  -Path "$($destinationPath)\.vscode" -ItemType Directory -Force | Out-Null
    New-Item  -Path "$($destinationPath)\src" -ItemType Directory -Force | Out-Null
    Copy-Item -path "$($alTemplatePath)\.vscode\launch.json" -Destination "$($destinationPath)\.vscode\launch.json"

    UpdateManifest -sourceFolder $appSourceFolder -appJsonFile "$($destinationPath)\app.json" -name $name-idrange $idrange -version $version

    if ($sampleCode) {
        Get-ChildItem -Path "$appSourceFolder\src" -Recurse -Filter "*.al" | ForEach-Object {
            Write-Host $_.Name
            UpdateALFile -sourceFolder $_.DirectoryName -destinationFolder "$($destinationPath)\src" -alFileName $_.name -fromId 149100 -toId 149200 -startId $idrange[0]
        }
    }
    if ($sampleSuite) {
        UpdateALFile -sourceFolder $alTemplatePath -destinationFolder $destinationPath -alFileName bcptSuite.json -fromId 149100 -toId 149200 -startId $idrange[0]
    }
}

function UpdateManifest
(
    [string] $sourceFolder = $alTemplatePath,
    [string] $appJsonFile,
    [string] $name,
    [string] $description,
    [string] $version,
    [string[]] $idrange,
    [switch] $AddTestDependencies
)
{
    #Modify app.json
    $appJson = Get-Content (Join-Path $sourceFolder "app.json") -Encoding UTF8 | ConvertFrom-Json

    $appJson.id = [Guid]::NewGuid().ToString()
    $appJson.Publisher = 'Acora Limited'
    $appJson.Name = $name
    $appJson.Description = $description
    $appJson.Version = $version
    $appJson.Logo = "./logo/icon.png"
    $appJson.url = "https://www.acora.com/extensions-support-2"
    $appJson.EULA = "https://www.acora.com/terms-conditions"
    $appJson.privacyStatement = "https://www.acora.com/privacy-policy"
    $appJson.help = "https://www.acora.com/extensions-support-2"
    "contextSensitiveHelpUrl" | ForEach-Object {
        if ($appJson.PSObject.Properties.Name -eq $_) { $appJson.PSObject.Properties.Remove($_) }
    }
    $appJson.idRanges[0].from = [int]$idrange[0]
    $appJson.idRanges[0].to = [int]$idrange[1]
    if ($AddTestDependencies) {
        $appJson.dependencies += @(
            @{
                "id" = "dd0be2ea-f733-4d65-bb34-a28f4624fb14"
                "publisher" = "Microsoft"
                "name" = "Library Assert"
                "version" = $appJson.Application
            },
            @{
                "id" = "5095f467-0a01-4b99-99d1-9ff1237d286f"
                "publisher" = "Microsoft"
                "name" = "Library Variable Storage"
                "version" = $appJson.Application
            },
            @{
                "id" = "5d86850b-0d76-4eca-bd7b-951ad998e997"
                "publisher" = "Microsoft"
                "name" = "Tests-TestLibraries"
                "version" = $appJson.Application
            },
            @{
                "id" = "e7320ebb-08b3-4406-b1ec-b4927d3e280b"
                "publisher" = "Microsoft"
                "name" = "Any"
                "version" = $appJson.Application
            }
        )

    }
    $appJson | Set-JsonContentLF -path $appJsonFile
}

<#
.SYNOPSIS
Update workspace file
#>
function UpdateWorkspaces
(
    [string] $projectFolder,
    [string] $appName
)
{
    Get-ChildItem -Path $projectFolder -Filter "*.code-workspace" |
        ForEach-Object {
            try {
                $workspaceFileName = $_.Name
                $workspaceFile = $_.FullName
                $workspace = Get-Content $workspaceFile -Encoding UTF8 | ConvertFrom-Json
                if (-not ($workspace.folders | Where-Object { $_.Path -eq $appName })) {
                    $workspace.folders = AddNewAppFolderToWorkspaceFolders $workspace.folders $appName
                }
                $workspace | Set-JsonContentLF -Path $workspaceFile
            }
            catch {
                throw "Updating the workspace file $workspaceFileName failed.$([environment]::Newline) $($_.Exception.Message)"
            }
        }
}

<#
.SYNOPSIS
Add new App Folder to Workspace file
#>
function AddNewAppFolderToWorkspaceFolders
(
    [PSCustomObject[]] $workspaceFolders,
    [string] $appFolder
)
{
    $newAppFolder = [PSCustomObject]@{ "path" = $appFolder }

    if (-not $workspaceFolders){
        return  @($newAppFolder)
    }

    $afterFolder = $workspaceFolders | Where-Object { $_.path -ne '.github' -and $_.path -ne '.AL-Go' } | Select-Object -Last 1

    if ($afterFolder) {
        $workspaceFolders = @($workspaceFolders | ForEach-Object {
            $_
            if ($afterFolder -and $_.path -eq $afterFolder.path) {
                Write-Host "Adding new path to workspace folders after $($afterFolder.Path)"
                $newAppFolder
                $afterFolder = $null
            }
        })
    }
    else {
        Write-Host "Inserting new path in workspace folders"
        $workspaceFolders = @($newAppFolder) + $workspaceFolders
    }
    $workspaceFolders
}

Export-ModuleMember -Function ConfirmIdRanges
Export-ModuleMember -Function NewSampleApp
Export-ModuleMember -Function NewSampleTestApp
Export-ModuleMember -Function NewSamplePerformanceTestApp
Export-ModuleMember -Function UpdateWorkspaces
Export-ModuleMember -Function AddNewAppFolderToWorkspaceFolders