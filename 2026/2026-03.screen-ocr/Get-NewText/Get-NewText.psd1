@{
    RootModule        = 'Get-NewText.psm1'
    ModuleVersion     = '0.1'
    GUID              = '42b2c1d0-e4f5-6789-abcd-ef0123456789'
    Author            = 'Alisson Sol'
    Description       = 'Extracts new text from screen captures by diffing against a previous frame and running OCR.'
    FunctionsToExport = @('Get-NewTextContent')
    PowerShellVersion = '7.0'
}
