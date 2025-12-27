$InformationPreference = "Continue"

# ==============================
# Script description
# ==============================
Write-Information "Identify issues (missing kerb, crossing missing, sidewalk on roads)."

# ==============================
# Configuration
# ==============================
[string]$OverpassUrl = "https://overpass-api.de/api/interpreter"
[string]$InputFilePath = Join-Path $PSScriptRoot "data\export.json"
[string]$OutIssueFilePath = Join-Path $PSScriptRoot "output\sidewalk_issues.geojson"
[string]$CsvFilePath = Join-Path $PSScriptRoot "output\statistics.csv"

# Bounding box
[Double]$MinLon = -83.3251400
[Double]$MinLat = 42.4471795
[Double]$MaxLon = -83.0833933
[Double]$MaxLat = 42.6183050

Import-Module "$PSScriptRoot\modules\GetDataFromOverpass.psm1"
Import-Module "$PSScriptRoot\modules\SidewalkHelpers.psm1"

# ==============================
# Download from Overpass
# ==============================
[string]$BBox = "$MinLat,$MinLon,$MaxLat,$MaxLon"
[string]$OverpassQuery = "[out:json][timeout:180];(way[`"highway`"]($BBox);node[`"highway`"=`"crossing`"]($BBox);node[`"barrier`"=`"kerb`"]($BBox);node[`"kerb`"=`"no`"]($BBox););out geom;"

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

$Osm3s = $OverpassJson.osm3s
[string]$Copyright = $Osm3s.copyright
[DateTime]$TimeStamp = $Osm3s.timestamp_osm_base
[string]$TimeStampString = $TimeStamp.ToString()

[DateTime]$TimeStampUtc = $TimeStamp.ToUniversalTime()
[string]$CurrentDate = $TimeStampUtc.ToString("yyyy-MM-dd")
[string]$CurrentTime = $TimeStampUtc.ToString("HH:mm:ss")

# ==============================
# Node map
# ==============================
[hashtable]$NodeMap = @{}

Write-Host "Parsing Nodes..." -NoNewline
$Nodes = $OverpassJson.elements | Where-Object { $_.type -eq "node" }
foreach ($Element in $Nodes) {
    [Int64]$NodeId = $Element.id
    if (-not $NodeMap.ContainsKey($NodeId)) {
        $Tags = $Element.tags
        $NodeMap[$NodeId] = @{
            Id                  = $NodeId
            Lat                 = [double]$Element.lat
            Lon                 = [double]$Element.lon
            highway             = Get-Tag $Tags "highway"
            barrier             = Get-Tag $Tags "barrier"
            kerb                = Get-Tag $Tags "kerb"
            crossing_signals    = Get-Tag $Tags "crossing:signals"
            crossing_markings   = Get-Tag $Tags "crossing:markings"
            crossing            = Get-Tag $Tags "crossing"
            crossing_ref        = Get-Tag $Tags "crossing_ref"
        }
    }
}
[int64]$InputNodes = $NodeMap.Count
Write-Host "`r$($InputNodes) Nodes parsed"

# ==============================
# Parse Ways
# ==============================
Write-Host "Parsing Ways..." -NoNewline
$Ways = $OverpassJson.elements | Where-Object { $_.type -eq "way" }
[string[]]$PathHighways = @("footway","cycleway","path")
[string[]]$SidewalkVal = @("sidewalk","sidepath","traffic_island")
[string[]]$CrossingVal = @("crossing")
[string[]]$LinkVal     = @("link")
[string]$RoadRegex     = "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential)(_link)?$"

foreach ($Element in $Ways) {
    $Tags = $Element.tags
    if (-not $Tags) { continue }

    $Highway = Get-Tag $Tags "highway"
    if (-not $Highway) { continue }

    $IsPath = $PathHighways -contains $Highway
    [string]$PathType = Get-Tag $Tags "footway"
    if (-not $PathType) { $PathType = Get-Tag $Tags "cycleway" }
    if (-not $PathType) { $PathType = Get-Tag $Tags "path" }

    $IsRoad = $Highway -match $RoadRegex
    $NodeIds  = $Element.nodes
    $Geometry = $Element.geometry
    if (-not $NodeIds -or -not $Geometry) { continue }

    for ([int]$Index = 0; $Index -lt $NodeIds.Count; $Index++) {
        [Int64]$NodeId = $NodeIds[$Index]
        [bool]$IsEnd = ($Index -eq 0 -or $Index -eq ($NodeIds.Count - 1))

        if (-not $NodeMap.ContainsKey($NodeId)) {
            $NodeMap[$NodeId] = @{
                Id  = $NodeId
                Lat = [double]$Geometry[$Index].lat
                Lon = [double]$Geometry[$Index].lon
            }
        }
        $Node = $NodeMap[$NodeId]

        if ($IsPath) {
            if ($SidewalkVal -contains $PathType) { 
                if ($IsEnd) {
                    $Node["end_sidewalk"]="yes"
                } else {
                    $Node["mid_sidewalk"]="yes"
                }
            }
            if ($CrossingVal -contains $PathType) {
                if ($IsEnd) {
                    if (($Node["end_crossing"] -eq "yes") -and ($Node["highway"] -eq "crossing")) {
                        $Node["mid_crossing"]="yes"
                        $null = $Node.Remove("end_crossing")
                    } else {
                        $Node["end_crossing"]="yes"
                    }
                } else {
                    $Node["mid_crossing"]="yes"
                }
            }
            if ($LinkVal -contains $PathType) {
                if ($IsEnd) {
                    $Node["end_link"]="yes"
                } else {
                    $Node["mid_link"]="yes"
                }
            }
        }
        if ($IsRoad) { $Node["road"]="yes" }
    }
}
[int64]$InputWays = $Ways.Count
Write-Host "`r$($InputWays) Ways parsed"

# ==============================
# Filters and output
# ==============================
[hashtable]$IssueNodes = @{}
[array]$AllIssueNodes = @()
[int32]$MissingKerbCount     = 0
[int32]$CrossingMissingCount = 0
[int32]$SidewalkRoadCount    = 0
[int32]$CrossingTagsCount    = 0

Write-Host "Checking for issues..." -NoNewline
$FilterNodes = $NodeMap.Values
foreach ($Node in $FilterNodes) {
    # missing kerb, red circle
    if (($Node.end_sidewalk -eq "yes" -or $Node.mid_sidewalk -eq "yes") -and ($Node.end_crossing -eq "yes" -or $Node.mid_crossing -eq "yes" -or$Node.end_link -eq "yes") -and $Node.kerb -ne "no" -and $Node.barrier -ne "kerb") {
        Add-Issue $Node "missing_kerb"
        $MissingKerbCount++
    }

    # crossing missing, orange circle
    if ($Node.mid_crossing -eq "yes" -and $Node.road -eq "yes" -and $Node.highway -ne "crossing") {
        Add-Issue $Node "crossing_missing"
        $CrossingMissingCount++
    }

    # sidewalk on road, blue circle
    if (($Node.end_crossing -eq "yes" -or $Node.end_sidewalk -eq "yes" -or $Node.mid_sidewalk -eq "yes") -and $Node.road -eq "yes") {      
        Add-Issue $Node "sidewalk_road"
        $SidewalkRoadCount++
    }
    # crossing tags, green circle
    if($Node.highway -eq "crossing") {
        if (($null -ne $Node.crossing) -or ($null -ne $Node.crossing_markings) -or ($null -ne $Node.crossing_ref) -or ($null -eq $Node.crossing_signals)){
            Add-Issue $Node "crossing_tags"
            $CrossingTagsCount++ 
        }
    }
}
Write-Host "`r$($IssueNodes.Count) issues found"

# Write GeoJSON
if ($IssueNodes.Count -gt 0) {
    $AllIssueNodes = $IssueNodes.Values
    Write-GeoJson -Nodes $AllIssueNodes -OutFile $OutIssueFilePath -TimeStamp $TimeStampString -Copyright $Copyright
}

# ==============================
# Reporting
# ==============================
Write-Host "Check results:" -ForegroundColor Yellow
Write-Host ("  missing_kerb     : {0}" -f $MissingKerbCount) -ForegroundColor Yellow
Write-Host ("  crossing_missing : {0}" -f $CrossingMissingCount) -ForegroundColor Yellow
Write-Host ("  sidewalk_road    : {0}" -f $SidewalkRoadCount) -ForegroundColor Yellow
Write-Host ("  crossing_tags    : {0}" -f $CrossingTagsCount) -ForegroundColor Yellow

# Build the data object
$CsvObject = New-Object PSObject
$CsvObject | Add-Member -MemberType NoteProperty -Name "Date" -Value $CurrentDate
$CsvObject | Add-Member -MemberType NoteProperty -Name "Time" -Value $CurrentTime
$CsvObject | Add-Member -MemberType NoteProperty -Name "nodes" -Value $InputNodes
$CsvObject | Add-Member -MemberType NoteProperty -Name "ways" -Value $Ways.Count
$CsvObject | Add-Member -MemberType NoteProperty -Name "missing_kerb" -Value $MissingKerbCount
$CsvObject | Add-Member -MemberType NoteProperty -Name "crossing_missing" -Value $CrossingMissingCount
$CsvObject | Add-Member -MemberType NoteProperty -Name "sidewalk_road" -Value $SidewalkRoadCount
$CsvObject | Add-Member -MemberType NoteProperty -Name "crossing_tags" -Value $CrossingTagsCount
# Check if CSV exists
[bool]$FileExists = Test-Path -Path $CsvFilePath

if ($FileExists -eq $true)
{
    # Append without header
    $CsvObject |
        Export-Csv -Path $CsvFilePath -Delimiter ";" -NoTypeInformation -Append
}
else
{
    # Create file with header
    $CsvObject |
        Export-Csv -Path $CsvFilePath -Delimiter ";" -NoTypeInformation
}

# Pause only if not in VS Code
if ($Host.Name -ne 'Visual Studio Code Host') {
    Write-Host "Press any key to continue..."
    [System.Console]::ReadKey($true) | Out-Null
}