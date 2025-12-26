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
        [string]$TimeStampString
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
            timestamp_osm_base = $TimeStampString
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

Export-ModuleMember -Function Get-Tag, Write-GeoJson, Add-Issue
