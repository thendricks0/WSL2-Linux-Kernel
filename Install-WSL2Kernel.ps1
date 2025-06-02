#!/usr/bin/env pwsh

<#
.SYNOPSIS
WSL2 Kernel Installer - Downloads and installs custom WSL2 kernels from GitHub Actions

.DESCRIPTION
This script automatically downloads the latest WSL2 kernel builds from the 
thendricks0/WSL2-Linux-Kernel repository, presents them in a user-friendly menu,
and installs the selected kernel to the user's WSL configuration.

Features:
- Queries GitHub API for latest successful workflow runs
- Downloads artifacts using nightly.link (no authentication required)
- Extracts kernels to ~/wsl/kernels directory
- Updates ~/.wslconfig with kernel and modules configuration
- Backup and restore functionality for existing configurations

.PARAMETER Token
Optional GitHub personal access token for authenticated downloads

.PARAMETER EnableDebug
Enable verbose output for debugging

.PARAMETER Version
Specify the kernel version to install (e.g., '6.6'). If provided, the script will select the artifact whose name starts with the version string.

.EXAMPLE
./Install-WSL2Kernel.ps1

.EXAMPLE  
./Install-WSL2Kernel.ps1 -Token $env:GITHUB_TOKEN -EnableDebug

.NOTES
Requires PowerShell 5.1+ and WSL2 installed
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Token,
    
    [Parameter(Mandatory = $false)]
    [switch]$EnableDebug,

    [Parameter(Mandatory = $false)]
    [string]$Version
)

# Set verbose preference
if ($EnableDebug) {
    $VerbosePreference = "Continue"
}

# Script configuration
$script:Config = @{
    GitHubOwner = "thendricks0"
    GitHubRepo = "WSL2-Linux-Kernel"
    UserHome = $env:USERPROFILE
    WSLKernelsDir = Join-Path $env:USERPROFILE "wsl\kernels"
    WSLConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
}

Write-Host "🔧 WSL2 Kernel Installer" -ForegroundColor Cyan
Write-Host "========================" -ForegroundColor Cyan
Write-Host ""

function Get-LatestSuccessfulWorkflow {
    <#
    .SYNOPSIS
    Gets the latest successful workflow run from a GitHub repository.
    
    .DESCRIPTION
    Queries the GitHub API to find the most recent successful workflow run
    for the specified repository and workflow name.
    
    .PARAMETER Owner
    The GitHub repository owner/organization.
    
    .PARAMETER Repository
    The GitHub repository name.
    
    .PARAMETER WorkflowName
    The name of the workflow to search for (optional, defaults to any workflow).
    
    .PARAMETER Token
    GitHub personal access token for authentication (optional, but required for private repos).
    
    .EXAMPLE
    $workflow = Get-LatestSuccessfulWorkflow -Owner "thendricks0" -Repository "WSL2-Linux-Kernel"
    
    .EXAMPLE
    $workflow = Get-LatestSuccessfulWorkflow -Owner "thendricks0" -Repository "WSL2-Linux-Kernel" -Token $env:GITHUB_TOKEN
    
    .OUTPUTS
    [PSCustomObject] The workflow run object with id, status, conclusion, and other properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        
        [Parameter(Mandatory = $false)]
        [string]$WorkflowName,
        
        [Parameter(Mandatory = $false)]
        [string]$Token
    )
    
    try {
        Write-Verbose "Querying GitHub API for workflows..."
        
        # Build headers
        $headers = @{
            'Accept' = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        
        if ($Token) {
            $headers['Authorization'] = "Bearer $Token"
            Write-Verbose "Using authentication token"
        }
        
        # First, get all workflows
        $workflowsUrl = "https://api.github.com/repos/$Owner/$Repository/actions/workflows"
        Write-Verbose "Requesting workflows: $workflowsUrl"
        
        $workflowsResponse = Invoke-RestMethod -Uri $workflowsUrl -Method Get -Headers $headers -ErrorAction Stop
        
        if (-not $workflowsResponse.workflows -or $workflowsResponse.workflows.Count -eq 0) {
            Write-Warning "No workflows found for repository $Owner/$Repository"
            return $null
        }
        
        # Filter workflows by name if specified
        $targetWorkflows = $workflowsResponse.workflows
        if ($WorkflowName) {
            $targetWorkflows = $targetWorkflows | Where-Object { $_.name -eq $WorkflowName }
            if (-not $targetWorkflows) {
                Write-Warning "No workflow found with name '$WorkflowName'"
                return $null
            }
        }
        
        Write-Verbose "Found $($targetWorkflows.Count) workflow(s) to check"
        
        # Get runs for each workflow and find the latest successful one
        $latestSuccessfulRun = $null
        $latestDate = [DateTime]::MinValue
        
        foreach ($workflow in $targetWorkflows) {
            Write-Verbose "Checking runs for workflow: $($workflow.name)"
            
            $runsUrl = "https://api.github.com/repos/$Owner/$Repository/actions/workflows/$($workflow.id)/runs?status=completed&conclusion=success&per_page=1"
            Write-Verbose "Requesting runs: $runsUrl"
            
            $runsResponse = Invoke-RestMethod -Uri $runsUrl -Method Get -Headers $headers -ErrorAction Stop
        
            
            if ($runsResponse.workflow_runs -and $runsResponse.workflow_runs.Count -gt 0) {
                $run = $runsResponse.workflow_runs[0]
                $runDate = [DateTime]::Parse($run.created_at)
                
                if ($runDate -gt $latestDate) {
                    $latestDate = $runDate
                    $latestSuccessfulRun = $run
                    Write-Verbose "Found newer successful run: $($run.name) (ID: $($run.id)) from $($run.created_at)"
                }
            }
        }
        
        if (-not $latestSuccessfulRun) {
            Write-Warning "No successful workflow runs found"
            return $null
        }
        
        Write-Verbose "Latest successful workflow: $($latestSuccessfulRun.name) (ID: $($latestSuccessfulRun.id))"
        Write-Verbose "Created: $($latestSuccessfulRun.created_at), Conclusion: $($latestSuccessfulRun.conclusion)"
        
        return $latestSuccessfulRun
    }
    catch {
        Write-Error "Failed to query GitHub API: $($_.Exception.Message)"
        return $null
    }
}

function Get-WorkflowArtifacts {
    <#
    .SYNOPSIS
    Gets the artifacts for a specific workflow run.
    
    .DESCRIPTION
    Queries the GitHub API to retrieve all artifacts for a given workflow run ID.
    
    .PARAMETER Owner
    The GitHub repository owner/organization.
    
    .PARAMETER Repository
    The GitHub repository name.
    
    .PARAMETER RunId
    The workflow run ID to get artifacts for.
    
    .PARAMETER Token
    GitHub personal access token for authentication (optional, but required for private repos).
    
    .EXAMPLE
    $artifacts = Get-WorkflowArtifacts -Owner "thendricks0" -Repository "WSL2-Linux-Kernel" -RunId 12345
    
    .OUTPUTS
    [Array] Array of artifact objects with name, size, download_url, and other properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        
        [Parameter(Mandatory = $false)]
        [string]$Token
    )
    
    try {
        Write-Verbose "Querying GitHub API for workflow artifacts..."
        
        # Build headers
        $headers = @{
            'Accept' = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        
        if ($Token) {
            $headers['Authorization'] = "Bearer $Token"
            Write-Verbose "Using authentication token"
        }
        
        # Get artifacts for the workflow run
        $artifactsUrl = "https://api.github.com/repos/$Owner/$Repository/actions/runs/$RunId/artifacts"
        Write-Verbose "Requesting artifacts: $artifactsUrl"
        
        $response = Invoke-RestMethod -Uri $artifactsUrl -Method Get -Headers $headers -ErrorAction Stop
        
        if (-not $response.artifacts -or $response.artifacts.Count -eq 0) {
            Write-Warning "No artifacts found for workflow run $RunId"
            return @()
        }
        
        Write-Verbose "Found $($response.artifacts.Count) artifact(s)"
        
        foreach ($artifact in $response.artifacts) {
            Write-Verbose "  - $($artifact.name) ($([Math]::Round($artifact.size_in_bytes / 1MB, 2)) MB)"
        }
        
        return $response.artifacts
    }
    catch {
        Write-Error "Failed to query GitHub API for artifacts: $($_.Exception.Message)"
        return @()
    }
}

function Show-ArtifactMenu {
    <#
    .SYNOPSIS
    Displays a menu of artifacts for the user to choose from.
    
    .DESCRIPTION
    Presents a numbered menu of available artifacts and prompts the user to select one.
    Returns the selected artifact object.
    
    .PARAMETER Artifacts
    Array of artifact objects to display in the menu.
    
    .PARAMETER Title
    Optional title for the menu.
    
    .EXAMPLE
    $selectedArtifact = Show-ArtifactMenu -Artifacts $artifacts -Title "Choose a WSL2 Kernel"
    
    .OUTPUTS
    [PSCustomObject] The selected artifact object, or $null if cancelled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Array]$Artifacts,
        
        [Parameter(Mandatory = $false)]
        [string]$Title = "Available Artifacts"
    )
    
    if (-not $Artifacts -or $Artifacts.Count -eq 0) {
        Write-Warning "No artifacts available to display"
        return $null
    }
    
    # Display menu header
    Write-Host ""
    Write-Host "=================================="-ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Green
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Display menu items
    for ($i = 0; $i -lt $Artifacts.Count; $i++) {
        $artifact = $Artifacts[$i]
        $sizeMB = [Math]::Round($artifact.size_in_bytes / 1MB, 2)
        $createdDate = ([DateTime]::Parse($artifact.created_at)).ToString("yyyy-MM-dd HH:mm")
        
        Write-Host "$($i + 1). " -NoNewline -ForegroundColor Yellow
        Write-Host "$($artifact.name)" -ForegroundColor White
        Write-Host "    Size: $sizeMB MB" -ForegroundColor Gray
        Write-Host "    Created: $createdDate UTC" -ForegroundColor Gray
        Write-Host ""
    }
    
    # Add exit option
    Write-Host "$($Artifacts.Count + 1). " -NoNewline -ForegroundColor Yellow
    Write-Host "Cancel / Exit" -ForegroundColor Red
    Write-Host ""
    
    # Get user selection
    do {
        Write-Host "Please select an option (1-$($Artifacts.Count + 1)): " -NoNewline -ForegroundColor Cyan
        $selection = Read-Host
        
        # Validate input
        if ([string]::IsNullOrWhiteSpace($selection)) {
            Write-Host "Please enter a valid number." -ForegroundColor Red
            continue
        }
        
        if (-not [int]::TryParse($selection, [ref]$null)) {
            Write-Host "Please enter a valid number." -ForegroundColor Red
            continue
        }
        
        $selectionNum = [int]$selection
        
        # Check if user wants to exit
        if ($selectionNum -eq ($Artifacts.Count + 1)) {
            Write-Host "Operation cancelled by user." -ForegroundColor Yellow
            return $null
        }
        
        # Check valid range
        if ($selectionNum -lt 1 -or $selectionNum -gt $Artifacts.Count) {
            Write-Host "Please enter a number between 1 and $($Artifacts.Count + 1)." -ForegroundColor Red
            continue
        }
        
        # Valid selection
        $selectedArtifact = $Artifacts[$selectionNum - 1]
        Write-Host ""
        Write-Host "You selected: " -NoNewline -ForegroundColor Green
        Write-Host "$($selectedArtifact.name)" -ForegroundColor White
        Write-Host ""
        
        return $selectedArtifact
        
    } while ($true)
}

function Download-Artifact {
    <#
    .SYNOPSIS
    Downloads a GitHub workflow artifact to a specified directory.
    
    .DESCRIPTION
    Downloads the specified artifact from GitHub to the given destination path.
    The artifact will be downloaded as a ZIP file and optionally extracted.
    
    .PARAMETER Owner
    The GitHub repository owner/organization.
    
    .PARAMETER Repository
    The GitHub repository name.
    
    .PARAMETER Artifact
    The artifact object to download.
    
    .PARAMETER DestinationPath
    The directory where the artifact should be downloaded.
    
    .PARAMETER Token
    GitHub personal access token for authentication (optional).
    
    .PARAMETER Extract
    Whether to extract the ZIP file after download.
    
    .EXAMPLE
    Download-Artifact -Owner "thendricks0" -Repository "WSL2-Linux-Kernel" -Artifact $artifact -DestinationPath "C:\temp"
    
    .EXAMPLE  
    Download-Artifact -Owner "thendricks0" -Repository "WSL2-Linux-Kernel" -Artifact $artifact -DestinationPath "C:\temp" -Token $env:GITHUB_TOKEN
    
    .OUTPUTS
    [string] The path to the downloaded file or extracted directory
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Artifact,
        
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        
        [Parameter(Mandatory = $false)]
        [string]$Token,
        
        [Parameter(Mandatory = $false)]
        [switch]$Extract
    )
    
    try {
        # Ensure destination directory exists
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-Verbose "Created destination directory: $DestinationPath"
        }
        
        # Build headers
        $headers = @{
            'Accept' = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        
        if ($Token) {
            $headers['Authorization'] = "Bearer $Token"
            Write-Verbose "Using authentication token"
        }
        
        $zipFileName = "$($Artifact.name).zip"
        $zipFilePath = Join-Path $DestinationPath $zipFileName
        
        Write-Host "Downloading artifact: $($Artifact.name)" -ForegroundColor Cyan
        Write-Host "Size: $([Math]::Round($Artifact.size_in_bytes / 1MB, 2)) MB" -ForegroundColor Gray
        Write-Host "Destination: $zipFilePath" -ForegroundColor Gray
        
        # Determine download URL based on authentication
        if ($Token) {
            # Use GitHub API with authentication
            $downloadUrl = $Artifact.archive_download_url
            Write-Verbose "Using GitHub API (authenticated): $downloadUrl"
            Invoke-WebRequest -Uri $downloadUrl -Headers $headers -OutFile $zipFilePath -ErrorAction Stop
        } else {
            # Use nightly.link for public access (no authentication required)
            # Get the workflow run ID from the artifact object
            if (-not $Artifact.workflow_run -or -not $Artifact.workflow_run.id) {
                throw "Artifact does not contain workflow_run.id information required for nightly.link"
            }
            
            $runId = $Artifact.workflow_run.id
            
            # Build nightly.link URL - URL encode the artifact name
            Add-Type -AssemblyName System.Web
            $encodedArtifactName = [System.Web.HttpUtility]::UrlEncode($Artifact.name)
            $nightlyUrl = "https://nightly.link/$Owner/$Repository/actions/runs/$runId/$encodedArtifactName.zip"
            
            Write-Verbose "Using nightly.link (no authentication): $nightlyUrl"
            Write-Host "Using nightly.link service (no GitHub token required)" -ForegroundColor Yellow
            
            Invoke-WebRequest -Uri $nightlyUrl -OutFile $zipFilePath -ErrorAction Stop
        }
        
        Write-Host "✓ Download completed!" -ForegroundColor Green
        
        if ($Extract) {
            Write-Host "Extracting archive..." -ForegroundColor Cyan
            
            $extractPath = Join-Path $DestinationPath $Artifact.name
            
            # Remove existing extract directory if it exists
            if (Test-Path $extractPath) {
                Remove-Item $extractPath -Recurse -Force
            }
            
            # Extract the ZIP file
            Expand-Archive -Path $zipFilePath -DestinationPath $extractPath -Force
            Write-Verbose "Extracted to: $extractPath"
            
            # Optional: Remove the ZIP file after extraction
            Remove-Item $zipFilePath -Force
            Write-Verbose "Removed ZIP file: $zipFilePath"
            
            Write-Host "✓ Extraction completed!" -ForegroundColor Green
            return $extractPath
        }
        
        return $zipFilePath
    }
    catch {
        Write-Error "Failed to download artifact '$($Artifact.name)': $($_.Exception.Message)"
        return $null
    }
}

function Read-IniFile {
    <#
    .SYNOPSIS
    Reads an INI file and returns a hashtable with sections containing key-value pairs.
    
    .DESCRIPTION
    Parses an INI file into a hashtable where each section is a key containing another hashtable
    of key-value pairs. Comments and empty lines are ignored.
    
    .PARAMETER Path
    The path to the INI file to read.
    
    .EXAMPLE
    $config = Read-IniFile -Path "C:\Users\username\.wslconfig"
    
    .OUTPUTS
    [hashtable] A hashtable containing sections with key-value pairs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )
    
    $result = @{}
    $currentSection = $null
    
    try {
        $content = Get-Content -Path $Path -ErrorAction Stop
        
        foreach ($line in $content) {
            $line = $line.Trim()
            
            # Skip empty lines and comments
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) {
                continue
            }
            
            # Check for section header
            if ($line -match '^\[(.+)\]$') {
                $currentSection = $Matches[1].Trim()
                $result[$currentSection] = @{}
                continue
            }
            
            # Check for key-value pair
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim()

                if ($null -eq $currentSection) {
                    # Global key-value pair (no section)
                    if (-not $result.ContainsKey('_global')) {
                        $result['_global'] = @{}
                    }
                    $result['_global'][$key] = $value
                }
                else {
                    $result[$currentSection][$key] = $value
                }
            }
        }
    }
    catch {
        Write-Error "Failed to read INI file '$Path': $($_.Exception.Message)"
        return $null
    }
    
    return $result
}

function Write-IniFile {
    <#
    .SYNOPSIS
    Writes a hashtable to an INI file format.
    
    .DESCRIPTION
    Takes a hashtable with sections containing key-value pairs and writes it to an INI file.
    The '_global' section (if present) will be written without a section header at the top.
    
    .PARAMETER Path
    The path where the INI file should be written.
    
    .PARAMETER Data
    A hashtable containing sections with key-value pairs to write.
    
    .PARAMETER Force
    Overwrite existing files without prompting.
    
    .EXAMPLE
    $config = @{
        'wsl2' = @{
            'kernel' = 'C:\Users\username\wsl\kernels\bzImage-6.1.21'
            'kernelCommandLine' = 'cgroup_no_v1=all'
        }
    }
    Write-IniFile -Path "C:\Users\username\.wslconfig" -Data $config
    
    .INPUTS
    [hashtable] A hashtable containing sections with key-value pairs
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Data,
        
        [switch]$Force
    )
    
    if ((Test-Path $Path) -and -not $Force -and -not $PSCmdlet.ShouldProcess($Path, "Overwrite existing file")) {
        Write-Warning "File '$Path' already exists. Use -Force to overwrite."
        return
    }
    
    try {
        $output = @()
        
        # Write global section first (if it exists)
        if ($Data.ContainsKey('_global')) {
            foreach ($key in $Data['_global'].Keys | Sort-Object) {
                $value = $Data['_global'][$key]
                $output += "$key=$value"
            }
            $output += ""  # Empty line after global section
        }
        
        # Write other sections
        $sections = $Data.Keys | Where-Object { $_ -ne '_global' } | Sort-Object
        foreach ($section in $sections) {
            $output += "[$section]"
            
            foreach ($key in $Data[$section].Keys | Sort-Object) {
                $value = $Data[$section][$key]
                $output += "$key=$value"
            }
            
            # Add empty line between sections (except for the last one)
            if ($section -ne $sections[-1]) {
                $output += ""
            }
        }
        
        # Write to file
        $output | Out-File -FilePath $Path -Encoding UTF8 -Force:$Force
        Write-Verbose "Successfully wrote INI file to '$Path'"
    }
    catch {
        Write-Error "Failed to write INI file '$Path': $($_.Exception.Message)"
    }
}

function Initialize-WSLDirectories {
    <#
    .SYNOPSIS
    Creates the WSL kernels directory structure
    #>
    try {
        Write-Host "`n📁 Initializing WSL directories..." -ForegroundColor Yellow
        
        if (-not (Test-Path $script:Config.WSLKernelsDir)) {
            New-Item -ItemType Directory -Path $script:Config.WSLKernelsDir -Force | Out-Null
            Write-Host "✓ Created directory: $($script:Config.WSLKernelsDir)" -ForegroundColor Green
        } else {
            Write-Host "✓ Directory exists: $($script:Config.WSLKernelsDir)" -ForegroundColor Green
        }
        
        return $true
    } catch {
        Write-Error "❌ Failed to initialize directories: $($_.Exception.Message)"
        return $false
    }
}

function Get-LatestKernelArtifacts {
    <#
    .SYNOPSIS
    Gets the latest kernel artifacts from GitHub
    #>
    try {
        Write-Host "`n🔍 Querying GitHub for latest WSL2 kernels..." -ForegroundColor Yellow
        
        # Get latest successful workflow
        Write-Verbose "Getting latest successful workflow..."
        $workflow = Get-LatestSuccessfulWorkflow -Owner $script:Config.GitHubOwner -Repository $script:Config.GitHubRepo -Token $Token
        
        if (-not $workflow) {
            throw "No successful workflow runs found"
        }
        
        Write-Host "✓ Found workflow: $($workflow.name)" -ForegroundColor Green
        Write-Host "  Run ID: $($workflow.id)" -ForegroundColor Gray
        Write-Host "  Created: $($workflow.created_at)" -ForegroundColor Gray
        
        # Get artifacts for the workflow
        Write-Verbose "Getting workflow artifacts..."
        $artifacts = Get-WorkflowArtifacts -Owner $script:Config.GitHubOwner -Repository $script:Config.GitHubRepo -RunId $workflow.id -Token $Token
        
        if (-not $artifacts -or $artifacts.Count -eq 0) {
            throw "No artifacts found for the latest workflow"
        }
        
        Write-Host "✓ Found $($artifacts.Count) kernel artifact(s)" -ForegroundColor Green
        
        return $artifacts
    } catch {
        Write-Error "❌ Failed to get kernel artifacts: $($_.Exception.Message)"
        return $null
    }
}

function Install-SelectedKernel {
    <#
    .SYNOPSIS
    Downloads and installs the selected kernel artifact
    #>
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Artifact
    )
    
    try {
        Write-Host "`n💾 Installing kernel: $($Artifact.name)" -ForegroundColor Yellow
        
        # Create temporary download directory
        $tempBase = if ($env:TEMP) { $env:TEMP }
        $tempDir = Join-Path $tempBase "wsl-kernel-install-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        Write-Verbose "Created temporary directory: $tempDir"
        
        # Download and extract the artifact
        Write-Host "Downloading kernel artifact..." -ForegroundColor Cyan
        $extractedPath = Download-Artifact -Owner $script:Config.GitHubOwner -Repository $script:Config.GitHubRepo -Artifact $Artifact -DestinationPath $tempDir -Token $Token -Extract
        
        if (-not $extractedPath -or -not (Test-Path $extractedPath)) {
            throw "Failed to download or extract kernel artifact"
        }
        
        Write-Host "✓ Kernel downloaded and extracted" -ForegroundColor Green
        
        # Analyze extracted contents
        $kernelFiles = Get-ChildItem $extractedPath -File
        Write-Verbose "Found files: $($kernelFiles.Name -join ', ')"
        
        # Find kernel and modules files
        $kernelFile = $kernelFiles | Where-Object { $_.Name -match '^bzImage-' }
        $modulesFile = $kernelFiles | Where-Object { $_.Name -match '\.vhdx$' }
        
        if (-not $kernelFile) {
            throw "No kernel file (bzImage-*) found in artifact"
        }
        
        Write-Host "✓ Found kernel: $($kernelFile.Name)" -ForegroundColor Green
        if ($modulesFile) {
            Write-Host "✓ Found modules: $($modulesFile.Name)" -ForegroundColor Green
        }
        
        # Create version-specific directory in kernels folder
        $versionMatch = $kernelFile.Name -match 'bzImage-(.+)'
        $kernelVersion = if ($matches) { $matches[1] } else { "unknown-$(Get-Date -Format 'yyyyMMdd')" }
        $kernelInstallDir = $script:Config.WSLKernelsDir
        
        Write-Host "Installing to: $kernelInstallDir" -ForegroundColor Cyan
        
        New-Item -ItemType Directory -Path $kernelInstallDir -Force | Out-Null
        
        # Copy kernel files to installation directory
        Copy-Item $kernelFile.FullName $kernelInstallDir -Force
        Write-Host "✓ Installed kernel: $($kernelFile.Name)" -ForegroundColor Green
        
        if ($modulesFile) {
            Copy-Item $modulesFile.FullName $kernelInstallDir -Force
            Write-Host "✓ Installed modules: $($modulesFile.Name)" -ForegroundColor Green
        }
        
        # Clean up temporary directory
        Write-Verbose "Cleaning up temporary directory: $tempDir"
        Remove-Item $tempDir -Recurse -Force
        
        return @{
            Version = $kernelVersion
            KernelPath = Join-Path $kernelInstallDir $kernelFile.Name
            ModulesPath = if ($modulesFile) { Join-Path $kernelInstallDir $modulesFile.Name } else { $null }
            InstallDir = $kernelInstallDir
        }
    } catch {
        Write-Error "❌ Failed to install kernel: $($_.Exception.Message)"
        
        # Clean up on failure
        if ($tempDir -and (Test-Path $tempDir)) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        return $null
    }
}

function Update-WSLConfiguration {
    <#
    .SYNOPSIS
    Updates the .wslconfig file with the new kernel configuration
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$KernelInfo
    )
    
    try {
        Write-Host "`n⚙️ Updating WSL configuration..." -ForegroundColor Yellow
        
        # Backup existing config if it exists
        if (Test-Path $script:Config.WSLConfigPath) {
            $backupPath = "$($script:Config.WSLConfigPath).backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $script:Config.WSLConfigPath $backupPath -Force
            Write-Host "✓ Backed up existing config to: $backupPath" -ForegroundColor Green
        }
        
        # Read existing configuration or create new one
        $wslConfig = if (Test-Path $script:Config.WSLConfigPath) {
            Read-IniFile -Path $script:Config.WSLConfigPath
        } else {
            @{}
        }
        
        # Ensure [wsl2] section exists
        if (-not $wslConfig.ContainsKey("wsl2")) {
            $wslConfig["wsl2"] = @{}
        }
        
        # Escape backslashes in paths for WSL config
        $escapedKernelPath = $KernelInfo.KernelPath -replace '\\', '\\'
        $wslConfig["wsl2"]["kernel"] = $escapedKernelPath
        Write-Host "✓ Set kernel path: $escapedKernelPath" -ForegroundColor Green
        
        # Update modules path if available
        if ($KernelInfo.ModulesPath) {
            $escapedModulesPath = $KernelInfo.ModulesPath -replace '\\', '\\'
            $wslConfig["wsl2"]["modulesPath"] = $escapedModulesPath
            Write-Host "✓ Set modules path: $escapedModulesPath" -ForegroundColor Green
        }
        
        # Add metadata comment
        $wslConfig["wsl2"]["# Installed by WSL2-Kernel-Installer"] = "Version: $($KernelInfo.Version), Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        
        # Write updated configuration
        Write-IniFile -Data $wslConfig -Path $script:Config.WSLConfigPath
        Write-Host "✓ Updated .wslconfig successfully" -ForegroundColor Green
        
        return $true
    } catch {
        Write-Error "❌ Failed to update WSL configuration: $($_.Exception.Message)"
        return $false
    }
}

function Show-InstallationSummary {
    <#
    .SYNOPSIS
    Shows a summary of the installation
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$KernelInfo
    )
    
    Write-Host "`n🎉 Installation Complete!" -ForegroundColor Green
    Write-Host "===========================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📋 Installation Summary:" -ForegroundColor Cyan
    Write-Host "  Kernel Version: $($KernelInfo.Version)" -ForegroundColor White
    Write-Host "  Kernel Path: $($KernelInfo.KernelPath)" -ForegroundColor Gray
    if ($KernelInfo.ModulesPath) {
        Write-Host "  Modules Path: $($KernelInfo.ModulesPath)" -ForegroundColor Gray
    }
    Write-Host "  Install Directory: $($KernelInfo.InstallDir)" -ForegroundColor Gray
    Write-Host "  WSL Config: $($script:Config.WSLConfigPath)" -ForegroundColor Gray
    
    Write-Host "`n🔄 Next Steps:" -ForegroundColor Yellow
    Write-Host "1. Restart WSL to use the new kernel:" -ForegroundColor White
    Write-Host "   wsl --shutdown" -ForegroundColor Gray
    Write-Host "   wsl" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. Verify kernel version:" -ForegroundColor White
    Write-Host "   wsl -- uname -r" -ForegroundColor Gray
    Write-Host ""
    Write-Host "3. Check WSL configuration:" -ForegroundColor White
    Write-Host "   cat ~/.wslconfig" -ForegroundColor Gray
    Write-Host ""
}

# Main execution
try {
    # Initialize directories
    if (-not (Initialize-WSLDirectories)) {
        exit 1
    }
    
    # Get latest kernel artifacts
    $artifacts = Get-LatestKernelArtifacts
    if (-not $artifacts) {
        exit 1
    }

    $selectedArtifact = $null
    if ($Version) {
        # Try to match artifact name with version string
        $selectedArtifact = $artifacts | Where-Object { $_.name -like "wsl2-kernel-$Version*" }
        if (-not $selectedArtifact) {
            # Try partial match (e.g. 6.6 matches 6.6.87.1)
            $selectedArtifact = $artifacts | Where-Object { $_.name -like "wsl2-kernel-$Version*" -or $_.name -like "*-$Version*" }
        }
        if ($selectedArtifact -is [array]) {
            $selectedArtifact = $selectedArtifact[0] # Take first match if multiple
        }
        if (-not $selectedArtifact) {
            Write-Host "❌ No kernel artifact found matching version: $Version" -ForegroundColor Red
            Write-Host "Available artifacts:" -ForegroundColor Yellow
            $artifacts | ForEach-Object { Write-Host " - $($_.name)" -ForegroundColor Gray }
            exit 1
        } else {
            Write-Host "✓ Selected artifact: $($selectedArtifact.name) (matched by version: $Version)" -ForegroundColor Green
        }
    } else {
        # Show menu and get user selection
        $selectedArtifact = Show-ArtifactMenu -Artifacts $artifacts -Title "🔧 Choose a WSL2 Kernel to Install"
        if (-not $selectedArtifact) {
            Write-Host "Installation cancelled by user." -ForegroundColor Yellow
            exit 0
        }
    }
    
    # Install the selected kernel
    $kernelInfo = Install-SelectedKernel -Artifact $selectedArtifact
    if (-not $kernelInfo) {
        exit 1
    }
    
    # Update WSL configuration
    if (-not (Update-WSLConfiguration -KernelInfo $kernelInfo)) {
        exit 1
    }
    
    # Show installation summary
    Show-InstallationSummary -KernelInfo $kernelInfo
    
} catch {
    Write-Error "❌ Installation failed: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "💡 Troubleshooting:" -ForegroundColor Blue
    Write-Host "- Ensure you have write permissions to $($script:Config.UserHome)" -ForegroundColor Gray
    Write-Host "- Check your internet connection for GitHub API access" -ForegroundColor Gray
    Write-Host "- Try running with -EnableDebug for more detailed output" -ForegroundColor Gray
    exit 1
}
