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
                issue = if($Node.ContainsKey('issue')){$Node.issue -join ';'} else {"no"}
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
        $Node,
        [string]$Issue
    )

    [int64]$id = $Node.Id

    if ($IssueNodes.ContainsKey($id)) {
        # Node already tracked → append issue
        if ($null -eq $IssueNodes[$id].issue) {
            $IssueNodes[$id].issue = $Issue
        }
        else {
            $IssueNodes[$id].issue += $Issue
        }
    }
    else {
        # First time this node is seen
        $Node.issue = @($Issue)
        $IssueNodes[$id] = $Node
    }
}

Export-ModuleMember -Function Get-Tag, Write-GeoJson, Add-Issue
