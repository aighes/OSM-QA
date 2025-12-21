$InformationPreference = "Continue"

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
    param (
        [Parameter(Mandatory)]
        [string]$BBox,
        [boolean]$OmitDownload = $false
    )
    if (-not($OmitDownload)){
        Write-Debug "Downloading Overpass data for bbox $BBox"

        $OverpassQuery = "[out:json][timeout:180];(way[`"highway`"]($BBox);node[`"highway`"=`"crossing`"]($BBox);node[`"barrier`"=`"kerb`"]($BBox);node[`"kerb`"=`"no`"]($BBox););out geom;"
        try {
            Invoke-WebRequest `
                -Uri $OverpassUrl `
                -Method Post `
                -Body $OverpassQuery `
                -ContentType "application/x-www-form-urlencoded" `
                -OutFile $InputFile

            return $true
        }
        catch {
            Write-Error $_
            return $false
        }
    } else {
        return $true
    }
}
function Get-Tag {
    param (
        [Newtonsoft.Json.Linq.JObject]$Tags,
        [string]$Key
    )
    if ($null -ne $Tags -and $Tags.ContainsKey($Key)) {
        return [string]$Tags[$Key]
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
                coordinates = @(
                    $Node.Lon,  # longitude first!
                    $Node.Lat
                )
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

    $Json = [Newtonsoft.Json.JsonConvert]::SerializeObject(
        $GeoJson,
        [Newtonsoft.Json.Formatting]::Indented
    )

    [System.IO.File]::WriteAllText($OutFile, $Json, [System.Text.Encoding]::UTF8)
}
function Add-Issue {
    param (
        [hashtable]$Node,
        [string]$Issue
    )

    # Initialize issue array if missing
    if (-not $Node.ContainsKey("issue")) {
        $Node["issue"] = @()
    }

    # Add issue if not already present
    if ($Node["issue"] -notcontains $Issue) {
        $Node["issue"] += $Issue
    }

    # Store node uniquely by id
    $IssueNodes[$Node["id"]] = $Node
}
# ==============================
# Download from Overpass
# ==============================
[String]$BBox = "$MinLat,$MinLon,$MaxLat,$MaxLon"

if (-not (Get-HighwayFromOverpass $BBox $OmitDownload)) {
    throw "Overpass download failed"
}

# ==============================
# Load JSON (Unicode safe)
# ==============================
Add-Type -AssemblyName Newtonsoft.Json

[byte[]]$FileBytes = [System.IO.File]::ReadAllBytes($InputFile)
[string]$JsonText = [System.Text.Encoding]::UTF8.GetString($FileBytes)

$OverpassJson = [Newtonsoft.Json.Linq.JObject]::Parse($JsonText)

if ($OverpassJson["remark"]) {
    Write-Warning "Overpass remark: $($OverpassJson["remark"].ToString())"
    exit
}

$Osm3s = $OverpassJson['osm3s']
[string]$Copyright = $Osm3s["copyright"].ToString()
[string]$TimeStamp = $Osm3s["timestamp_osm_base"].ToString()

# ==============================
# Node map
# ==============================
[hashtable]$NodeMap = @{}

# ==============================
# 1) Parse nodes first
# ==============================
foreach ($Element in $OverpassJson["elements"]) {

    if ($Element["type"].ToString() -ne "node") { continue }

    [Int64]$NodeId = $Element["id"].ToString()

    if ($NodeMap.ContainsKey($NodeId)) {
        Write-Error "Duplicate node id $NodeId"
        continue
    }

    $Tags = $Element["tags"]

    $NodeMap[$NodeId] = @{
        Id      = $NodeId
        Lat     = [double]$Element["lat"]
        Lon     = [double]$Element["lon"]
        highway = Get-Tag $Tags "highway"
        barrier = Get-Tag $Tags "barrier"
        kerb    = Get-Tag $Tags "kerb"
    }
}

# ==============================
# 2) Parse ways
# ==============================
[string[]]$PathHighways = @("footway","cycleway","path")
[string[]]$SidewalkVal = @("sidewalk","sidepath","traffic_island")
[string[]]$CrossingVal = @("crossing")
[string[]]$LinkVal     = @("link")
[string]$RoadRegex     = "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential)(_link)?$"

foreach ($Element in $OverpassJson["elements"]) {

    if ($Element["type"].ToString() -ne "way") { continue }

    $Tags = $Element["tags"]
    if (-not $Tags) { continue }

    $Highway = Get-Tag $Tags "highway"
    if (-not $Highway) { continue }

    $IsPath = $PathHighways -contains $Highway

    [string]$PathType = $null

    $PathType = Get-Tag $Tags "footway"
    if (-not $PathType) {
        $PathType = Get-Tag $Tags "cycleway"
    }
    if (-not $PathType) {
        $PathType = Get-Tag $Tags "path"
    }

    $IsRoad = $Highway -match $RoadRegex

    #Get all way nodes
    $NodeIds  = $Element["nodes"]
    $Geometry = $Element["geometry"]
    if (-not $NodeIds -or -not $Geometry) { continue }

    for ($Index = 0; $Index -lt $NodeIds.Count; $Index++) {

        [Int64]$NodeId = $NodeIds[$Index]
        [bool]$IsEnd = ($Index -eq 0 -or $Index -eq ($NodeIds.Count - 1))

        #Get untagged way nodes to hashmap
        if (-not $NodeMap.ContainsKey($NodeId)) {
            $NodeMap[$NodeId] = @{
                Id  = $NodeId
                Lat = [double]$Geometry[$Index]["lat"]
                Lon = [double]$Geometry[$Index]["lon"]
            }
        } 
        
        $Node = $NodeMap[$NodeId]

        if ($IsPath) {
            #classify sidewalk end/mid nodes 
            if ($SidewalkVal -contains $PathType) {
                if ($IsEnd) { $Node["end_sidewalk"] = "yes" }
                else        { $Node["mid_sidewalk"] = "yes" }
            }
            #classify crossing end/mid nodes 
            if ($CrossingVal -contains $PathType) {
                if ($IsEnd) { $Node["end_crossing"] = "yes" }
                else        { $Node["mid_crossing"] = "yes" }
            }
            #classify link end/mid nodes 
            if ($LinkVal -contains $PathType) {
                if ($IsEnd) { $Node["end_link"] = "yes" }
                else        { $Node["mid_link"] = "yes" }
            }
        }
        #classify road nodes
        if ($IsRoad) {
            $Node["road"] = "yes"
        }
    }
}

# ==============================
# Filters and output
# ==============================

# Result container
$IssueNodes = @{}
$AllIssueNodes   = @() 

# Counters
[int32]$MissingKerbCount     = 0
[int32]$CrossingMissingCount = 0
[int32]$SidewalkRoadCount    = 0

# Check 1: missing kerb
$NodeMap.Values | Where-Object {
    $_["end_sidewalk"] -eq "yes" -and
    ( $_["end_crossing"] -eq "yes" -or $_["end_link"] -eq "yes" ) -and
    $_["kerb"] -ne "no" -and
    $_["barrier"] -ne "kerb"
} | ForEach-Object {
    Add-Issue $_ "missing_kerb"
    $MissingKerbCount++
}

# Check 2: crossing missing
$NodeMap.Values | Where-Object {
    $_["mid_crossing"] -eq "yes" -and
    $_["road"] -eq "yes" -and
    $_["highway"] -ne "crossing"
} | ForEach-Object {
    Add-Issue $_ "crossing_missing"
    $CrossingMissingCount++
}

# Check 3: sidewalk on road
$NodeMap.Values | Where-Object {
    ( $_["end_crossing"] -eq "yes" -or
      $_["end_sidewalk"] -eq "yes" -or
      $_["mid_sidewalk"] -eq "yes" ) -and
    $_["road"] -eq "yes"
} | ForEach-Object {
    Add-Issue $_ "sidewalk_road"
    $SidewalkRoadCount++
}
# Finalize results
$AllIssueNodes = $IssueNodes.Values

if ($AllIssueNodes) {
    Write-GeoJson -Nodes $AllIssueNodes -Outfile $OutIssueFilePath -TimeStamp $TimeStamp -Copyright $Copyright
}

# -------------------------
# Reporting
# -------------------------
Write-Host "Check results:"
Write-Host ("  missing_kerb     : {0}" -f $MissingKerbCount)
Write-Host ("  crossing_missing : {0}" -f $CrossingMissingCount)
Write-Host ("  sidewalk_road    : {0}" -f $SidewalkRoadCount)