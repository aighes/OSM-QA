function Get-DataFromOverpass {
    [CmdletBinding()]
    param(
        [string]$OverpassUrl,
        [string]$OverpassQuery,
        [string]$FilePath,
        [bool]$OmitDownload = $false,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySec = 5
    )

    if ($OmitDownload) { return $true }

    if (Test-Path $FilePath) {
        Remove-Item -Path $FilePath -Force
    }

    $Attempt = 0
    while ($Attempt -lt $MaxRetries) {
        try {
            Write-Host "`rDownloading Overpass data (attempt $($Attempt + 1))..." -NoNewline

            $old = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'

            Invoke-WebRequest `
                -Uri $OverpassUrl `
                -Method Post `
                -Body $OverpassQuery `
                -ContentType "application/x-www-form-urlencoded" `
                -OutFile $FilePath

            $ProgressPreference = $old
            Write-Host "`rDownload complete.                        "
            return $true
        }
        catch {
            Write-Warning "Download failed: $($_.Exception.Message)"
            Start-Sleep -Seconds $RetryDelaySec
            $Attempt++
        }
    }

    Write-Warning "Failed to download Overpass data after $MaxRetries attempts."
    return $false
}

Export-ModuleMember -Function Get-DataFromOverpass
