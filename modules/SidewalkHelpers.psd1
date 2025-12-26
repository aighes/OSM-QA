@{
    RootModule        = 'SidewalkHelpers.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b9f4a9d2-6c0d-4a6a-8a61-5f1b0f8c3b44'
    Author            = 'Henning Scholland'
    CompanyName       = ''
    Copyright         = ''
    Description       = 'Helper functions for sidewalk and crossing analysis.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-Tag',
        'Write-GeoJson',
        'Add-Issue'
    )

    CmdletsToExport   = @()
    VariablesToExport = '*'
    AliasesToExport   = @()

    PrivateData       = @{}
}
