@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Consoletool: meldingen horen op het scherm, niet in de pipeline
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
