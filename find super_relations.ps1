# Define the Overpass API URL and query
[string]$OverpassUrl = "https://overpass-api.de/api/interpreter"
[string]$OverpassQuery = "[out:json][timeout:180];rel[`"cycle_network`"=`"US:US`"][`"type`"=`"route`"];(._; >;);out body;"

[string]$CsvFilePath = Join-Path $PSScriptRoot "output\filtered_relations.csv"
[string]$InputFilePath = Join-Path $PSScriptRoot "data\relations.json"

Import-Module "$PSScriptRoot\modules\GetDataFromOverpass.psm1"
Import-Module "$PSScriptRoot\modules\SidewalkHelpers.psm1"

# Send the query to the Overpass API

[string]$Response = Read-Host "Do you want to download data from OverpassAPI? (y/n)"
[boolean]$OmitDownload = -not($response -match '^(y|yes)$')

[boolean]$DownloadSuccess = Get-DataFromOverpass -OverpassUrl $OverpassUrl -OverpassQuery $OverpassQuery -FilePath $InputFilePath -OmitDownload $OmitDownload
if (-not $DownloadSuccess) {
    throw "Overpass download failed"
} else {
    if ($OmitDownload) {
        Write-Host "Download skipped (using existing file)"
    }
}
# ==============================
# Load JSON
# ==============================
Write-Host "Loading JSON..." -NoNewline
[byte[]]$FileBytes = [System.IO.File]::ReadAllBytes($InputFilePath)
[string]$JsonText = [System.Text.Encoding]::UTF8.GetString($FileBytes)
$OverpassJson = $JsonText | ConvertFrom-Json
Write-Host "`rJSON loaded            "

if ($OverpassJson.remark) {
    Write-Warning "Overpass remark: $($OverpassJson.remark)"
    if ($Host.Name -ne 'Visual Studio Code Host') {
        Write-Host "Press any key to continue..."
        [System.Console]::ReadKey($true) | Out-Null
    }
    exit
}

# Process the JSON response
$FilteredRelations = @()
foreach ($Element in $OverpassJson.elements) {
    if ($Element.type -eq "relation") {
        [boolean]$OnlyRelations = $true
        foreach ($Member in $Element.members) {
            if ($Member.type -ne "relation") {
                $OnlyRelations = $false
                break
            }
        }
        if ($OnlyRelations) {
            $FilteredRelations += [PSCustomObject]@{
                id = [int64]$Element.id
                name = [string]$Element.tags.description
            }
        }
    }
}

# Output filtered relations to a CSV file
$FilteredRelations |
    ForEach-Object {
        "$($_.id);$($_.name)"
    } |
    Set-Content -Path $CsvFilePath -Encoding UTF8

# Pause only if not in VS Code
if ($Host.Name -ne 'Visual Studio Code Host') {
    Write-Host "Press any key to continue..."
    [System.Console]::ReadKey($true) | Out-Null
}