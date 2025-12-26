@{
    RootModule        = 'Get-DataFromOverpass.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e6a8f8b0-3d6f-4f3a-9b7b-9c5e8c1a7e01'
    Author            = 'Henning Scholland'
    CompanyName       = ''
    Copyright         = ''
    Description       = 'Downloads OSM data from Overpass API.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-DataFromOverpass'
    )

    CmdletsToExport   = @()
    VariablesToExport = '*'
    AliasesToExport   = @()

    PrivateData       = @{}
}
