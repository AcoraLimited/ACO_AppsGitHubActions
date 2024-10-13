$AcoraFolderName = '.Acora'
$AcoraSettingsFile = Join-Path '.Acora' 'settings.json'
$RepoSettingsFile = Join-Path '.github' 'Acora-Settings.json'
$defaultBcContainerHelperVersion = "latest" # Must be double quotes. Will be replaced by BcContainerHelperVersion if necessary in the deploy step - ex. "https://github.com/organization/navcontainerhelper/archive/refs/heads/branch.zip"



function CloneIntoNewFolder {
    Param(
        [string] $actor,
        [string] $token,
        [string] $updateBranch = $env:GITHUB_REF_NAME,
        [string] $newBranchPrefix = '',
        [bool] $directCommit
    )

    $baseFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    New-Item $baseFolder -ItemType Directory | Out-Null
    Set-Location $baseFolder
    $serverUri = [Uri]::new($env:GITHUB_SERVER_URL)
    $serverUrl = "$($serverUri.Scheme)://$($actor):$($token)@$($serverUri.Host)/$($env:GITHUB_REPOSITORY)"

    # Environment variables for hub commands
    $env:GITHUB_USER = $actor
    $env:GITHUB_TOKEN = $token

    # Configure git
    invoke-git config --global user.email "$actor@users.noreply.github.com"
    invoke-git config --global user.name "$actor"
    invoke-git config --global hub.protocol https
    invoke-git config --global core.autocrlf false

    invoke-git clone $serverUrl

    Set-Location *
    invoke-git checkout $updateBranch

    $branch = "$newBranchPrefix/$updateBranch/$((Get-Date).ToUniversalTime().ToString(`"yyMMddHHmmss`"))" # e.g. create-development-environment/main/210101120000
    if (!$directCommit) {
        invoke-git checkout -b $branch
    }

    $serverUrl
    $branch
}

function CommitFromNewFolder {
    Param(
        [string] $serverUrl,
        [string] $commitMessage,
        [string] $body = $commitMessage,
        [string] $branch
    )

    invoke-git add *
    $status = invoke-git -returnValue status --porcelain=v1
    if ($status) {
        if ($commitMessage.Length -gt 250) {
            $commitMessage = "$($commitMessage.Substring(0,250))...)"
        }
        invoke-git commit --allow-empty -m "$commitMessage"
        $activeBranch = invoke-git -returnValue -silent name-rev --name-only HEAD
        # $branch is the name of the branch to be used when creating a Pull Request
        # $activeBranch is the name of the branch that is currently checked out
        # If activeBranch and branch are the same - we are creating a PR
        if ($activeBranch -ne $branch) {
            try {
                invoke-git push $serverUrl
                return $true
            }
            catch {
                OutputWarning("Direct Commit wasn't allowed, trying to create a Pull Request instead")
                invoke-git reset --soft HEAD~
                invoke-git checkout -b $branch
                invoke-git commit --allow-empty -m "$commitMessage"
            }
        }
        invoke-git push -u $serverUrl $branch
        try {
            invoke-gh pr create --fill --head $branch --repo $env:GITHUB_REPOSITORY --base $ENV:GITHUB_REF_NAME --body "$body"
        }
        catch {
            OutputError("GitHub actions are not allowed to create Pull Requests (see GitHub Organization or Repository Actions Settings). You can create the PR manually by navigating to $($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/tree/$branch")
        }
        return $true
    }
    else {
        Write-Host "No changes detected in files"
        return $false
    }
}

# This function will check and create the project folder if needed
# If project is not specified (or '.'), the root folder is used and the repository is single project
# If project is specified, check whether project folder exists and create it if it doesn't
# If no apps has been added to the repository, move the .AL-Go folder to the project folder (Convert to multi-project repository)
function CheckAndCreateProjectFolder {
    Param(
        [string] $project
    )

    if (-not $project) { $project = "." }
    if ($project -eq ".") {
        if (!(Test-Path $AcoraSettingsFile)) {
            throw "Repository is setup as a multi-project repository, but no project has been specified."
        }
    }
    else {
        $createCodeWorkspace = $false
        if (Test-Path $AcoraSettingsFile) {
            $appCount = @(Get-ChildItem -Path '.' -Filter 'app.json' -Recurse -File).Count
            if ($appCount -eq 0) {
                OutputWarning "Converting the repository to a multi-project repository as no other apps have been added previously."
                New-Item $project -ItemType Directory | Out-Null
                Move-Item -path $ALGoFolderName -Destination $project
                Set-Location $project
                $createCodeWorkspace = $true
            }
            else {
                throw "Repository is setup for a single project, cannot add a project. Move all appFolders, testFolders and the .AL-Go folder to a subdirectory in order to convert to a multi-project repository."
            }
        }
        else {
            if (!(Test-Path $project)) {
                New-Item -Path (Join-Path $project $ALGoFolderName) -ItemType Directory | Out-Null
                Set-Location $project
                OutputWarning "Project folder doesn't exist, creating a new project folder and a default settings file with country gb. Please modify if needed."
                [ordered]@{
                    "country"     = "gb"
                    "appFolders"  = @()
                    "testFolders" = @()
                } | Set-JsonContentLF -path $AcoraSettingsFile
                $createCodeWorkspace = $true
            }
            else {
                Set-Location $project
            }
        }
        if ($createCodeWorkspace) {
            [ordered]@{
                "folders"  = @( @{ "path" = $AcoraFolderName } )
                "settings" = @{}
            } | Set-JsonContentLF -path "$project.code-workspace"
        }
    }
}

#
# Get Path to BcContainerHelper module (download if necessary)
#
# If $env:BcContainerHelperPath is set, it will be reused (ignoring the ContainerHelperVersion)
#
# ContainerHelperVersion can be:
# - preview (or dev), which will use the preview version downloaded from bccontainerhelper blob storage
# - latest, which will use the latest version downloaded from bccontainerhelper blob storage
# - a specific version, which will use the specific version downloaded from bccontainerhelper blob storage
# - none, which will use the BcContainerHelper module installed on the build agent
# - https://... - direct download url to a zip file containing the BcContainerHelper module
#
# When using direct download url, the module will be downloaded to a temp folder and will not be cached
# When using none, the module will be located in modules and used from there
# When using preview, latest or a specific version number, the module will be downloaded to a cache folder and will be reused if the same version is requested again
# This is to avoid filling up the temp folder with multiple identical versions of BcContainerHelper
# The cache folder is C:\ProgramData\BcContainerHelper on Windows and /home/<username>/.BcContainerHelper on Linux
# A Mutex will be used to ensure multiple agents aren't fighting over the same cache folder
#
# This function will set $env:BcContainerHelperPath, which is the path to the BcContainerHelper.ps1 file for reuse in subsequent calls
#
function GetBcContainerHelperPath([string] $bcContainerHelperVersion) {
    if ("$env:BcContainerHelperPath" -and (Test-Path -Path $env:BcContainerHelperPath -PathType Leaf)) {
        return $env:BcContainerHelperPath
    }

    if ($bcContainerHelperVersion -eq 'None') {
        $module = Get-Module BcContainerHelper
        if (-not $module) {
            OutputError "When setting BcContainerHelperVersion to none, you need to ensure that BcContainerHelper is installed on the build agent"
        }
        $bcContainerHelperPath = Join-Path (Split-Path $module.Path -parent) "BcContainerHelper.ps1" -Resolve
    }
    else {
        if ($isWindows) {
            $bcContainerHelperRootFolder = 'C:\ProgramData\BcContainerHelper'
        }
        else {
            $myUsername = (whoami)
            $bcContainerHelperRootFolder = "/home/$myUsername/.BcContainerHelper"
        }
        if (!(Test-Path $bcContainerHelperRootFolder)) {
            New-Item -Path $bcContainerHelperRootFolder -ItemType Directory | Out-Null
        }

        $webclient = New-Object System.Net.WebClient
        if ($bcContainerHelperVersion -like "https://*") {
            # Use temp space for private versions
            $tempName = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
            Write-Host "Downloading BcContainerHelper developer version from $bcContainerHelperVersion"
            try {
                $webclient.DownloadFile($bcContainerHelperVersion, "$tempName.zip")
            }
            catch {
                $tempName = Join-Path $bcContainerHelperRootFolder ([Guid]::NewGuid().ToString())
                $bcContainerHelperVersion = "preview"
                Write-Host "Download failed, downloading BcContainerHelper $bcContainerHelperVersion version from Blob Storage"
                $webclient.DownloadFile("https://bccontainerhelper.blob.core.windows.net/public/$($bcContainerHelperVersion).zip", "$tempName.zip")
            }
        }
        else {
            $tempName = Join-Path $bcContainerHelperRootFolder ([Guid]::NewGuid().ToString())
            if ($bcContainerHelperVersion -eq "dev") {
                # For backwards compatibility, use preview when dev is specified
                $bcContainerHelperVersion = 'preview'
            }
            Write-Host "Downloading BcContainerHelper $bcContainerHelperVersion version from Blob Storage"
            $webclient.DownloadFile("https://bccontainerhelper.blob.core.windows.net/public/$($bcContainerHelperVersion).zip", "$tempName.zip")
        }
        Expand-7zipArchive -Path "$tempName.zip" -DestinationPath $tempName
        $bcContainerHelperPath = (Get-Item -Path (Join-Path $tempName "*\BcContainerHelper.ps1")).FullName
        Remove-Item -Path "$tempName.zip" -ErrorAction SilentlyContinue
        if ($bcContainerHelperVersion -notlike "https://*") {
            # Check whether the version is already available in the cache
            $version = ([System.IO.File]::ReadAllText((Join-Path $tempName 'BcContainerHelper/Version.txt'), [System.Text.Encoding]::UTF8)).Trim()
            $cacheFolder = Join-Path $bcContainerHelperRootFolder $version
            # To avoid two agents on the same machine downloading the same version at the same time, use a mutex
            $buildMutexName = "DownloadAndImportBcContainerHelper"
            $buildMutex = New-Object System.Threading.Mutex($false, $buildMutexName)
            try {
                try {
                    if (!$buildMutex.WaitOne(1000)) {
                        Write-Host "Waiting for other process loading BcContainerHelper"
                        $buildMutex.WaitOne() | Out-Null
                        Write-Host "Other process completed loading BcContainerHelper"
                    }
                }
                catch [System.Threading.AbandonedMutexException] {
                    Write-Host "Other process terminated abnormally"
                }
                if (Test-Path $cacheFolder) {
                    Remove-Item $tempName -Recurse -Force
                }
                else {
                    Rename-Item -Path $tempName -NewName $version
                }
            }
            finally {
                $buildMutex.ReleaseMutex()
            }
            $bcContainerHelperPath = Join-Path $cacheFolder "BcContainerHelper/BcContainerHelper.ps1"
        }
    }
    $env:BcContainerHelperPath = $bcContainerHelperPath
    if ($ENV:GITHUB_ENV) {
        Add-Content -Encoding UTF8 -Path $ENV:GITHUB_ENV "BcContainerHelperPath=$bcContainerHelperPath"
    }
    return $bcContainerHelperPath
}

#
# Download and import the BcContainerHelper module based on repository settings
# baseFolder is the repository baseFolder
#
function DownloadAndImportBcContainerHelper([string] $baseFolder = $ENV:GITHUB_WORKSPACE) {
    $params = @{ "ExportTelemetryFunctions" = $true }
    $repoSettingsPath = Join-Path $baseFolder $repoSettingsFile

    # Default BcContainerHelper Version is hardcoded in AL-Go-Helper (replaced during AL-Go deploy)
    $bcContainerHelperVersion = $defaultBcContainerHelperVersion
    if (Test-Path $repoSettingsPath) {
        # Read Repository Settings file (without applying organization variables, repository variables or project settings files)
        # Override default BcContainerHelper version from AL-Go-Helper only if new version is specifically specified in repo settings file
        $repoSettings = Get-Content $repoSettingsPath -Encoding UTF8 | ConvertFrom-Json | ConvertTo-HashTable
        if ($repoSettings.Keys -contains "BcContainerHelperVersion") {
            $bcContainerHelperVersion = $repoSettings.BcContainerHelperVersion
            Write-Host "Using BcContainerHelper $bcContainerHelperVersion version"
            if ($bcContainerHelperVersion -like "https://*") {
                throw "Setting BcContainerHelperVersion to a URL in settings is not allowed. Fork the AL-Go repository and use direct AL-Go development instead."
            }
            if ($bcContainerHelperVersion -ne 'latest' -and $bcContainerHelperVersion -ne 'preview') {
                Write-Host "::Warning::Using a specific version of BcContainerHelper is not recommended and will lead to build failures in the future. Consider removing the setting."
            }
        }
        $params += @{ "bcContainerHelperConfigFile" = $repoSettingsPath }
    }

    if ($bcContainerHelperVersion -eq '') {
        $bcContainerHelperVersion = "latest"
    }

    if ($bcContainerHelperVersion -eq 'private') {
        throw "ContainerHelperVersion private is no longer supported. Use direct AL-Go development and a direct download url instead."
    }

    $bcContainerHelperPath = GetBcContainerHelperPath -bcContainerHelperVersion $bcContainerHelperVersion

    Write-Host "Import from $bcContainerHelperPath"
    . $bcContainerHelperPath @params
}

function GetUniqueFolderName {
    Param(
        [string] $baseFolder,
        [string] $folderName
    )

    $i = 2
    $name = $folderName
    while (Test-Path (Join-Path $baseFolder $name)) {
        $name = "$folderName($i)"
        $i++
    }
    $name
}