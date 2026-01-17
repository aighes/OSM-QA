#Requires -Version 5.1
<#
.SYNOPSIS
    JSON-driven build script.

.DESCRIPTION
    Processes build items defined in BuildConfig.json.

    For each item:
      - Detects whether Source is a file or folder
      - Supports relative and absolute paths
      - Optionally zips files or folder contents
      - Copies output to the configured destination
      - Emits warnings if an item cannot be processed

    No JSON schema validation is performed.
    The script assumes configuration correctness and
    handles runtime issues gracefully.

.NOTES
    PowerShell 5.1 compatible
#>

# --------------------------------------------------
# Script Paths
# --------------------------------------------------
[string]$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
[string]$ConfigFilePath = Join-Path -Path $ScriptDirectory -ChildPath 'buildConfig.json'

# --------------------------------------------------
# Load Configuration
# --------------------------------------------------
if (-not (Test-Path -Path $ConfigFilePath -PathType Leaf)) {
    throw "buildConfig.json not found at: $ConfigFilePath"
}

[string]$JsonContent = Get-Content -Path $ConfigFilePath -Raw
[pscustomobject]$BuildConfig = $JsonContent | ConvertFrom-Json

# --------------------------------------------------
# Process Build Items
# --------------------------------------------------
foreach ($BuildItem in $BuildConfig.BuildItems) {

    [pscustomobject]$TypedBuildItem = $BuildItem

    [string]$SourceValue = $TypedBuildItem.Source
    [bool]$Compress = $TypedBuildItem.Compress
    [string]$DestinationValue = $TypedBuildItem.Destination

    # --------------------------------------------------
    # Resolve Source Path (Relative / Absolute)
    # --------------------------------------------------
    [string]$SourcePath = if ([System.IO.Path]::IsPathRooted($SourceValue)) {
        $SourceValue
    }
    else {
        Join-Path -Path $ScriptDirectory -ChildPath $SourceValue
    }

    # --------------------------------------------------
    # Resolve Destination Path (Relative / Absolute)
    # --------------------------------------------------
    [string]$DestinationPath = if ([System.IO.Path]::IsPathRooted($DestinationValue)) {
        $DestinationValue
    }
    else {
        Join-Path -Path $ScriptDirectory -ChildPath $DestinationValue
    }

    # Ensure destination directory exists
    if (-not (Test-Path -Path $DestinationPath -PathType Container)) {
        try {
            [System.IO.DirectoryInfo]$Null = New-Item -Path $DestinationPath -ItemType Directory -Force
        }
        catch {
            Write-Warning "Failed to create destination directory '$DestinationPath'. Skipping item."
            continue
        }
    }

    # --------------------------------------------------
    # File Handling
    # --------------------------------------------------
    if (Test-Path -Path $SourcePath -PathType Leaf) {

        [string]$FileName = [System.IO.Path]::GetFileName($SourcePath)

        try {
            if ($Compress) {
                [string]$ZipFilePath = Join-Path -Path $DestinationPath -ChildPath "$FileName.zip"

                if (Test-Path -Path $ZipFilePath) {
                    Remove-Item -Path $ZipFilePath -Force
                }

                Compress-Archive -Path $SourcePath -DestinationPath $ZipFilePath -Force
            }
            else {
                Copy-Item -Path $SourcePath -Destination (Join-Path $DestinationPath $FileName) -Force
            }
        }
        catch {
            Write-Warning "Failed to process file '$SourcePath'. Reason: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------
    # Folder Handling
    # --------------------------------------------------
    elseif (Test-Path -Path $SourcePath -PathType Container) {

        [string]$FolderName = Split-Path -Path $SourcePath -Leaf

        try {
            if ($Compress) {
                [string]$ZipFilePath = Join-Path -Path $DestinationPath -ChildPath "$FolderName.zip"

                if (Test-Path -Path $ZipFilePath) {
                    Remove-Item -Path $ZipFilePath -Force
                }

                Compress-Archive `
                    -Path (Join-Path -Path $SourcePath -ChildPath '*') `
                    -DestinationPath $ZipFilePath `
                    -Force
            }
            else {
                Copy-Item `
                    -Path $SourcePath `
                    -Destination $DestinationPath `
                    -Recurse `
                    -Force
            }
        }
        catch {
            Write-Warning "Failed to process folder '$SourcePath'. Reason: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------
    # Invalid Source
    # --------------------------------------------------
    else {
        Write-Warning "Source path does not exist or is unsupported: $SourcePath"
    }
}
