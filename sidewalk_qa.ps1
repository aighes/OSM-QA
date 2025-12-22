$InformationPreference = "Continue"

# ==============================
# Script description
# ==============================
Write-Information "Identify issues (missing kerb, crossing missing, sidewalk on roads)."

# ==============================
# Configuration
# ==============================
[string]$OverpassUrl = "https://overpass-api.de/api/interpreter"
[boolean]$OmitDownload = $false
[string]$InputFile = Join-Path $PSScriptRoot "data\export.json"
[string]$OutIssueFilePath = Join-Path $PSScriptRoot "output\sidewalk_issues.geojson"

# Bounding box
[Double]$MinLon = -83.3251400
[Double]$MinLat = 42.4471795
[Double]$MaxLon = -83.0833933
[Double]$MaxLat = 42.6183050

# ==============================
# Helper functions
# ==============================
function Get-HighwayFromOverpass {
    [CmdletBinding()]
    param(
        [string]$BBox,
        [bool]$OmitDownload = $false,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySec = 5
    )

    if ($OmitDownload) { return $true }

    $OverpassQuery = "[out:json][timeout:180];(way[`"highway`"]($BBox);node[`"highway`"=`"crossing`"]($BBox);node[`"barrier`"=`"kerb`"]($BBox);node[`"kerb`"=`"no`"]($BBox););out geom;"
    
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            Write-Information "Downloading Overpass data (attempt $($attempt+1))..."
            Invoke-WebRequest -Uri $OverpassUrl -Method Post -Body $OverpassQuery -ContentType "application/x-www-form-urlencoded" -OutFile $InputFile
            return $true
        } catch {
            Write-Warning "Download failed: $($_.Exception.Message)"
            Start-Sleep -Seconds $RetryDelaySec
            $attempt++
        }
    }
    Write-Warning "Failed to download Overpass data after $MaxRetries attempts."
    return $false
}
function Get-Tag {
    param (
        $Tags,
        [string]$Key
    )
    if ($null -ne $Tags) {
        if ($Tags.PSObject.Properties.Name -contains $Key) {
            return [string]$Tags.$Key
        }
    }
    return $null
}
function Write-GeoJson {
    param (
        [Parameter(Mandatory)]
        [array]$Nodes,
        [Parameter(Mandatory)]
        [string]$OutFile,
        [Parameter(Mandatory)]
        [string]$Copyright,
        [Parameter(Mandatory)]
        [string]$TimeStamp
    )

    $Features = foreach ($Node in $Nodes) {
        [ordered]@{
            type = "Feature"
            geometry = [ordered]@{
                type = "Point"
                coordinates = @($Node.Lon, $Node.Lat)
            }
            properties = @{
                issue = if($Node.ContainsKey('issue')){$Node.issue} else {"no"}
                end_crossing = if($Node.ContainsKey('end_crossing')){$Node.end_crossing} else {"no"}
                mid_crossing = if($Node.ContainsKey('mid_crossing')){$Node.mid_crossing} else {"no"}
                end_link = if($Node.ContainsKey('end_link')){$Node.end_link} else {"no"}
                mid_link = if($Node.ContainsKey('mid_link')){$Node.mid_link} else {"no"}
                end_sidewalk = if($Node.ContainsKey('end_sidewalk')){$Node.end_sidewalk} else {"no"}
                mid_sidewalk = if($Node.ContainsKey('mid_sidewalk')){$Node.mid_sidewalk} else {"no"}
                road = if($Node.ContainsKey('road')){$Node.road} else {"no"}
            }
        }
    }

    $GeoJson = [ordered]@{
        osm3s = [ordered]@{
            timestamp_osm_base = $TimeStamp
            copyright = $Copyright
        }
        type = "FeatureCollection"
        features = $Features
    }

    $Json = $GeoJson | ConvertTo-Json -Depth 10 -Compress
    [System.IO.File]::WriteAllText($OutFile, $Json, [System.Text.Encoding]::UTF8)
    $OutFileName = Split-Path $OutIssueFilePath -Leaf
    Write-Host "$OutFileName written"
}
function Add-Issue {
    param (
        [hashtable]$Node,
        [string]$Issue
    )
    if (-not $Node.ContainsKey("issue")) {
        $Node["issue"] = @()
    }
    if ($Node["issue"] -notcontains $Issue) {
        $Node["issue"] += $Issue
    }
    $IssueNodes[$Node["Id"]] = $Node
}

# ==============================
# Download from Overpass
# ==============================
[string]$BBox = "$MinLat,$MinLon,$MaxLat,$MaxLon"

$DownloadSuccess = Get-HighwayFromOverpass $BBox $OmitDownload
if (-not $DownloadSuccess) {
    throw "Overpass download failed"
} else {
    if ($OmitDownload) {
        Write-Host "Download skipped (using existing file)"
    } else {
        Write-Host "Download complete"
    }
}

# ==============================
# Load JSON
# ==============================
Write-Host "Loading JSON..." -NoNewline
[byte[]]$FileBytes = [System.IO.File]::ReadAllBytes($InputFile)
[string]$JsonText = [System.Text.Encoding]::UTF8.GetString($FileBytes)
$OverpassJson = $JsonText | ConvertFrom-Json
Write-Host "`rJSON loaded            "

if ($OverpassJson.remark) {
    Write-Warning "Overpass remark: $($OverpassJson.remark)"
    exit
}

$Osm3s = $OverpassJson.osm3s
[string]$Copyright = $Osm3s.copyright
[string]$TimeStamp = $Osm3s.timestamp_osm_base

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
            Id      = $NodeId
            Lat     = [double]$Element.lat
            Lon     = [double]$Element.lon
            highway = Get-Tag $Tags "highway"
            barrier = Get-Tag $Tags "barrier"
            kerb    = Get-Tag $Tags "kerb"
        }
    }
}
Write-Host "`r$($NodeMap.Count) Nodes parsed"

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
            if ($SidewalkVal -contains $PathType) { if ($IsEnd){$Node["end_sidewalk"]="yes"} else{$Node["mid_sidewalk"]="yes"} }
            if ($CrossingVal -contains $PathType) { if ($IsEnd){$Node["end_crossing"]="yes"} else{$Node["mid_crossing"]="yes"} }
            if ($LinkVal -contains $PathType) { if ($IsEnd){$Node["end_link"]="yes"} else{$Node["mid_link"]="yes"} }
        }

        if ($IsRoad) { $Node["road"]="yes" }
    }
}
Write-Host "`r$($Ways.Count) Ways parsed"

# ==============================
# Filters and output
# ==============================
[hashtable]$IssueNodes = @{}
[array]$AllIssueNodes = @()
[int32]$MissingKerbCount     = 0
[int32]$CrossingMissingCount = 0
[int32]$SidewalkRoadCount    = 0

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
        if ($Node['id'] -eq 9829048177) {
            Write-Host 'mid_sidewalk = '$Node["mid_sidewalk"]
            Write-Host 'road = '$Node["road"]
        }
        
        Add-Issue $Node "sidewalk_road"
        $SidewalkRoadCount++
    }
}
Write-Host "`r$($IssueNodes.Count) issues found"

# Write GeoJSON
if ($IssueNodes.Count -gt 0) {
    $AllIssueNodes = $IssueNodes.Values
    Write-GeoJson -Nodes $AllIssueNodes -OutFile $OutIssueFilePath -TimeStamp $TimeStamp -Copyright $Copyright
}

# ==============================
# Reporting
# ==============================
Write-Host "Check results:" -ForegroundColor Yellow
Write-Host ("  missing_kerb     : {0}" -f $MissingKerbCount) -ForegroundColor Yellow
Write-Host ("  crossing_missing : {0}" -f $CrossingMissingCount) -ForegroundColor Yellow
Write-Host ("  sidewalk_road    : {0}" -f $SidewalkRoadCount) -ForegroundColor Yellow

# Pause only if not in VS Code
if ($Host.Name -ne 'Visual Studio Code Host') {
    Write-Host "Press any key to continue..."
    [System.Console]::ReadKey($true) | Out-Null
}