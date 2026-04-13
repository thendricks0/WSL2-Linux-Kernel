#!/usr/bin/env pwsh

<#
.SYNOPSIS
WSL2 Kernel Installer - Downloads and installs custom WSL2 kernels from GitHub Releases

.DESCRIPTION
This script automatically downloads the latest WSL2 kernel builds from the 
thendricks0/WSL2-Linux-Kernel repository releases, presents them in a user-friendly menu,
and installs the selected kernel to the user's WSL configuration.

Features:
- Queries GitHub Releases API for available kernel builds
- Downloads release assets (kernel zip packages) with optional authentication
- Extracts kernels to ~/wsl/kernels/{version} directory
- Updates ~/.wslconfig with kernel and modules configuration
- Backup and restore functionality for existing configurations

.PARAMETER Token
Optional GitHub personal access token for authenticated downloads (required for private repositories)

.PARAMETER EnableDebug
Enable verbose output for debugging

.PARAMETER Version
Specify the kernel version to install (e.g., '6.6'). If provided, the script will select the release whose name starts with the version string.

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
    GitHubOwner   = "thendricks0"
    GitHubRepo    = "WSL2-Linux-Kernel"
    UserHome      = $env:USERPROFILE
    WSLKernelsDir = Join-Path $env:USERPROFILE "wsl\kernels"
    WSLConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
}

Write-Host "WSL2 Kernel Installer" -ForegroundColor Cyan
Write-Host "========================" -ForegroundColor Cyan
Write-Host ""

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
        $sizeMB = [Math]::Round($artifact.size_in_bytes / (1024 * 1024), 2)
        $createdDate = ([DateTime]$artifact.created_at).ToString("yyyy-MM-dd HH:mm")
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

function Download-ReleaseAssets {
    <#
    .SYNOPSIS
    Downloads and extracts GitHub release zip assets to a specified directory.
    
    .DESCRIPTION
    Downloads the kernel zip file from a GitHub release asset and extracts it.
    
    .PARAMETER Asset
    The transformed asset object containing the zip asset information.
    
    .PARAMETER DestinationPath
    The directory where the assets should be downloaded and extracted.
    
    .PARAMETER Token
    GitHub personal access token for authentication (optional).
    
    .EXAMPLE
    Download-ReleaseAssets -Asset $asset -DestinationPath "C:\temp"
    
    .OUTPUTS
    [string] The path to the extracted files directory
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Asset,
        
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        
        [Parameter(Mandatory = $false)]
        [string]$Token
    )
    
    try {
        # Ensure destination directory exists
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-Verbose "Created destination directory: $DestinationPath"
        }
        
        # Build headers
        $headers = @{
            'Accept' = 'application/octet-stream'
        }
        if ($Token) {
            $headers['Authorization'] = "Bearer $Token"
            Write-Verbose "Using authentication token"
        }
        
        Write-Host "Downloading kernel package: $($Asset.name)" -ForegroundColor Cyan
        
        # Download zip file
        $zipFileName = $Asset.zip_asset.name
        $zipFilePath = Join-Path $DestinationPath $zipFileName
        $downloadUrl = $Asset.zip_asset.url
        
        Write-Host "  Downloading: $zipFileName" -ForegroundColor Gray
        Write-Host "  Download URL: $downloadUrl" -ForegroundColor Gray
        $sizeMB = [Math]::Round($Asset.zip_asset.size / (1024 * 1024), 2)
        Write-Host "  Size: $sizeMB MB" -ForegroundColor Gray
        
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -Headers $headers -OutFile $zipFilePath -ErrorAction Stop
        $ProgressPreference = 'Continue'
        Write-Host "  Downloaded successfully" -ForegroundColor Green
        
        # Extract zip file
        Write-Host "  Extracting kernel package..." -ForegroundColor Gray
        $extractPath = Join-Path $DestinationPath "extracted"
        
        # Remove existing extract directory if it exists
        if (Test-Path $extractPath) {
            Remove-Item $extractPath -Recurse -Force
        }
        
        # Extract the ZIP file
        Expand-Archive -Path $zipFilePath -DestinationPath $extractPath -Force
        Write-Verbose "Extracted to: $extractPath"
        
        # Remove the ZIP file after extraction
        Remove-Item $zipFilePath -Force
        Write-Verbose "Removed ZIP file: $zipFilePath"
        
        Write-Host "  Extraction completed" -ForegroundColor Green
        
        # List extracted contents
        $extractedFiles = Get-ChildItem $extractPath -File
        Write-Verbose "Extracted files: $($extractedFiles.Name -join ', ')"
        
        return $extractPath
    }
    catch {
        Write-Error "Failed to download release assets '$($Asset.name)': $($_.Exception.Message)"
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
        Write-Host "`nInitializing WSL directories..." -ForegroundColor Yellow
        
        if (-not (Test-Path $script:Config.WSLKernelsDir)) {
            New-Item -ItemType Directory -Path $script:Config.WSLKernelsDir -Force | Out-Null
            Write-Host "Created directory: $($script:Config.WSLKernelsDir)" -ForegroundColor Green
        }
        else {
            Write-Host "Directory exists: $($script:Config.WSLKernelsDir)" -ForegroundColor Green
        }
        
        return $true
    }
    catch {
        Write-Error "❌ Failed to initialize directories: $($_.Exception.Message)"
        return $false
    }
}

function Get-LatestKernelAssets {
    <#
    .SYNOPSIS
    Gets the latest kernel assets from GitHub releases
    #>
    try {
        Write-Host "`nQuerying GitHub for latest WSL2 kernels..." -ForegroundColor Yellow
        
        # Build headers
        $headers = @{
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        
        if ($Token) {
            $headers['Authorization'] = "Bearer $Token"
            Write-Verbose "Using authentication token"
        }
        
        # Get all releases (not just latest)
        $releasesUrl = "https://api.github.com/repos/$($script:Config.GitHubOwner)/$($script:Config.GitHubRepo)/releases"
        Write-Verbose "Requesting releases: $releasesUrl"
        
        # Paginate through all releases
        $allReleases = @()
        $page = 1
        do {
            $pageUrl = "${releasesUrl}?per_page=100&page=$page"
            Write-Verbose "Requesting releases page $page"
            try {
                $pageReleases = Invoke-RestMethod -Uri $pageUrl -Method Get -Headers $headers -ErrorAction Stop
            }
            catch {
                throw "Failed to get releases (page $page): $($_.Exception.Message)"
            }
            $allReleases += $pageReleases
            $page++
        } while ($pageReleases.Count -eq 100)
        
        $releases = $allReleases
        
        if (-not $releases -or $releases.Count -eq 0) {
            throw "No releases found in the repository"
        }
        
        Write-Host "Found $($releases.Count) total release(s)" -ForegroundColor Green
        
        # Filter releases that have kernel zip assets (wsl2-kernel-*.zip)
        $kernelReleases = @()
        foreach ($release in $releases) {
            Write-Verbose "Processing release $($release.tag_name):"
            Write-Verbose "Assets in release:"
            foreach ($asset in $release.assets) {
                Write-Verbose "  - Asset name: '$($asset.name)'"
            }
            
            $zipAssets = $release.assets | Where-Object { $_.name -match '^wsl2-kernel-.+\.zip$' }
            
            # Convert to array and check count properly
            $zipAssetsArray = @($zipAssets)
            Write-Verbose "Kernel assets found: $($zipAssetsArray.Count)"
            
            if ($zipAssetsArray.Count -gt 0) {
                Write-Verbose "Found kernel zip assets in release: $($release.tag_name)"
                $kernelReleases += $release
            } else {
                Write-Verbose "No matching zip assets found in release: $($release.tag_name)"
            }
        }
        
        if ($kernelReleases.Count -eq 0) {
            throw "No kernel releases found (releases with wsl2-kernel-*.zip assets)"
        }
        
        Write-Host "Found $($kernelReleases.Count) kernel release(s)" -ForegroundColor Green
        
        # Transform releases to create synthetic artifact objects for each zip asset
        $transformedAssets = @()
        foreach ($release in $kernelReleases) {
            $zipAssets = $release.assets | Where-Object { $_.name -match '^wsl2-kernel-.+\.zip$' }
            
            foreach ($zipAsset in $zipAssets) {
                # Extract version from zip filename: wsl2-kernel-6.6.36.zip -> 6.6.36
                if ($zipAsset.name -match '^wsl2-kernel-(.+)\.zip$') {
                    $version = $matches[1]
                } else {
                    $version = "unknown"
                }
                
                Write-Verbose "Processing zip asset: $($zipAsset.name)"
                Write-Verbose "  Asset ID: $($zipAsset.id)"
                Write-Verbose "  Asset URL: $($zipAsset.url)"
                Write-Verbose "  Browser download URL: $($zipAsset.browser_download_url)"
                Write-Verbose "  Asset size: $($zipAsset.size)"
                
                # Create a synthetic artifact object
                $transformedAsset = [PSCustomObject]@{
                    name = "wsl2-kernel-$version"
                    version = $version
                    prerelease = $release.prerelease
                    size_in_bytes = $zipAsset.size
                    created_at = $release.published_at
                    download_url = $zipAsset.browser_download_url
                    asset_url = $zipAsset.url
                    zip_asset = $zipAsset
                    release_info = @{
                        tag_name = $release.tag_name
                        name = $release.name
                        published_at = $release.published_at
                    }
                }
                
                $transformedAssets += $transformedAsset
            }
        }
        
        if ($transformedAssets.Count -eq 0) {
            throw "No kernel zip assets found in releases"
        }
        
        Write-Host "Found $($transformedAssets.Count) kernel package(s) total" -ForegroundColor Green
        
        # Group by major.minor kernel line and keep only the latest stable per line
        # Version format: major.minor.patch[.subpatch][-rcN]
        $grouped = @{}
        foreach ($asset in $transformedAssets) {
            # Extract major.minor from version string (e.g., "6.18" from "6.18.22", "7.0" from "7.0.0")
            if ($asset.version -match '^(\d+\.\d+)') {
                $kernelLine = $Matches[1]
            } else {
                $kernelLine = "unknown"
            }
            
            if (-not $grouped.ContainsKey($kernelLine)) {
                $grouped[$kernelLine] = @()
            }
            $grouped[$kernelLine] += $asset
        }
        
        # For each kernel line, pick the latest stable release (or latest pre-release if no stable exists)
        $latestPerLine = @()
        foreach ($line in $grouped.Keys) {
            $lineAssets = $grouped[$line]
            
            # Prefer stable releases
            $stableAssets = @($lineAssets | Where-Object { -not $_.prerelease })
            
            if ($stableAssets.Count -gt 0) {
                # Sort stable by date descending, take the newest
                $latest = $stableAssets | Sort-Object { [DateTime]$_.created_at } -Descending | Select-Object -First 1
            } else {
                # No stable release for this line — take the newest pre-release
                $latest = $lineAssets | Sort-Object { [DateTime]$_.created_at } -Descending | Select-Object -First 1
            }
            
            $latestPerLine += $latest
        }
        
        # Sort by version descending (newest kernel line first)
        $latestPerLine = $latestPerLine | Sort-Object { [System.Version]($_.version -replace '-.*$', '' -replace '^(\d+\.\d+)$', '$1.0') } -Descending
        
        Write-Host "Showing $($latestPerLine.Count) latest kernel(s) (one per kernel line)" -ForegroundColor Green
        
        return $latestPerLine
    }
    catch {
        Write-Error "Failed to get kernel assets: $($_.Exception.Message)"
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
        Write-Host "`nInstalling kernel: $($Artifact.name)" -ForegroundColor Yellow
        
        # Create temporary download directory
        $tempBase = if ($env:TEMP) { $env:TEMP }
        $tempDir = Join-Path $tempBase "wsl-kernel-install-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        Write-Verbose "Created temporary directory: $tempDir"
        
        # Download the release assets
        Write-Host "Downloading kernel package..." -ForegroundColor Cyan
        $extractedPath = Download-ReleaseAssets -Asset $Artifact -DestinationPath $tempDir -Token $Token
        
        if (-not $extractedPath -or -not (Test-Path $extractedPath)) {
            throw "Failed to download and extract kernel package"
        }
        
        Write-Host "Kernel package downloaded and extracted successfully" -ForegroundColor Green
        
        # Find the versioned subdirectory (zip structure: {version}/bzImage, {version}/config, {version}/modules.vhdx)
        $versionDirs = Get-ChildItem $extractedPath -Directory
        if (-not $versionDirs -or $versionDirs.Count -eq 0) {
            throw "No versioned subdirectory found in extracted package"
        }
        
        $versionDir = $versionDirs[0]
        $kernelVersion = $versionDir.Name
        Write-Verbose "Found versioned directory: $kernelVersion"
        
        # Find kernel and modules files inside the versioned directory
        $kernelFile = Get-Item (Join-Path $versionDir.FullName "bzImage") -ErrorAction SilentlyContinue
        $modulesFile = Get-Item (Join-Path $versionDir.FullName "modules.vhdx") -ErrorAction SilentlyContinue
        
        if (-not $kernelFile) {
            throw "No kernel file (bzImage) found in extracted package under $kernelVersion/"
        }
        
        Write-Host "Found kernel: $($kernelFile.Name)" -ForegroundColor Green
        if ($modulesFile) {
            Write-Host "Found modules: $($modulesFile.Name)" -ForegroundColor Green
        }
        
        # Create version-specific directory in kernels folder
        $kernelInstallDir = Join-Path $script:Config.WSLKernelsDir $kernelVersion
        
        Write-Host "Installing to: $kernelInstallDir" -ForegroundColor Cyan
        
        New-Item -ItemType Directory -Path $kernelInstallDir -Force | Out-Null
        
        # Copy kernel files to installation directory
        Copy-Item $kernelFile.FullName $kernelInstallDir -Force
        Write-Host "Installed kernel: $($kernelFile.Name)" -ForegroundColor Green
        
        if ($modulesFile) {
            Copy-Item $modulesFile.FullName $kernelInstallDir -Force
            Write-Host "Installed modules: $($modulesFile.Name)" -ForegroundColor Green
        }
        
        # Clean up temporary directory
        Write-Verbose "Cleaning up temporary directory: $tempDir"
        Remove-Item $tempDir -Recurse -Force
        
        return @{
            Version       = $kernelVersion
            KernelPath    = Join-Path $kernelInstallDir $kernelFile.Name
            KernelModules = if ($modulesFile) { Join-Path $kernelInstallDir $modulesFile.Name } else { $null }
            InstallDir    = $kernelInstallDir
        }
    }
    catch {
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
        Write-Host "`nUpdating WSL configuration..." -ForegroundColor Yellow
        
        # Backup existing config if it exists
        if (Test-Path $script:Config.WSLConfigPath) {
            $backupPath = "$($script:Config.WSLConfigPath).backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $script:Config.WSLConfigPath $backupPath -Force
            Write-Host "Backed up existing config to: $backupPath" -ForegroundColor Green
        }
        
        # Read existing configuration or create new one
        $wslConfig = if (Test-Path $script:Config.WSLConfigPath) {
            Read-IniFile -Path $script:Config.WSLConfigPath
        }
        else {
            @{}
        }
        
        # Ensure [wsl2] section exists
        if (-not $wslConfig.ContainsKey("wsl2")) {
            $wslConfig["wsl2"] = @{}
        }
        
        # Escape backslashes in paths for WSL config
        $escapedKernelPath = $KernelInfo.KernelPath -replace '\\', '\\'
        $wslConfig["wsl2"]["kernel"] = $escapedKernelPath
        Write-Host "Set kernel path: $escapedKernelPath" -ForegroundColor Green
        
        # Update modules path if available
        if ($KernelInfo.KernelModules) {
            $escapedKernelModules = $KernelInfo.KernelModules -replace '\\', '\\'
            $wslConfig["wsl2"]["kernelModules"] = $escapedKernelModules
            Write-Host "Set modules path: $escapedKernelModules" -ForegroundColor Green
        }
        
        # Add metadata comment
        $wslConfig["wsl2"]["# Installed by WSL2-Kernel-Installer"] = "Version: $($KernelInfo.Version), Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        
        # Write updated configuration
        Write-IniFile -Data $wslConfig -Path $script:Config.WSLConfigPath
        Write-Host "Updated .wslconfig successfully" -ForegroundColor Green
        
        return $true
    }
    catch {
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
    
    Write-Host "`nInstallation Complete!" -ForegroundColor Green
    Write-Host "===========================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Installation Summary:" -ForegroundColor Cyan
    Write-Host "  Kernel Version: $($KernelInfo.Version)" -ForegroundColor White
    Write-Host "  Kernel Path: $($KernelInfo.KernelPath)" -ForegroundColor Gray
    if ($KernelInfo.KernelModules) {
        Write-Host "  Modules Path: $($KernelInfo.KernelModules)" -ForegroundColor Gray
    }
    Write-Host "  Install Directory: $($KernelInfo.InstallDir)" -ForegroundColor Gray
    Write-Host "  WSL Config: $($script:Config.WSLConfigPath)" -ForegroundColor Gray
    
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
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
    
    # Get latest kernel assets from release
    $artifacts = Get-LatestKernelAssets
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
        }
        else {
            Write-Host "Selected artifact: $($selectedArtifact.name) (matched by version: $Version)" -ForegroundColor Green
        }
    }
    else {
        # Show menu and get user selection (already sorted newest first)
        $selectedArtifact = Show-ArtifactMenu -Artifacts $artifacts -Title "Choose a WSL2 Kernel to Install"
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
    
}
catch {
    Write-Error "❌ Installation failed: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Blue
    Write-Host "- Ensure you have write permissions to $($script:Config.UserHome)" -ForegroundColor Gray
    Write-Host "- Check your internet connection for GitHub API access" -ForegroundColor Gray
    Write-Host "- Try running with -EnableDebug for more detailed output" -ForegroundColor Gray
    exit 1
}
