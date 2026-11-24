#Requires -Version 5.1
<#
.SYNOPSIS
    Zet alle PDF's in een map opnieuw om met Ghostscript (pdfwrite, PDF 1.7).

.DESCRIPTION
    Per bestand:
      1. Ghostscript schrijft naar een tijdelijk bestand in dezelfde map.
      2. Het origineel wordt hernoemd naar original_<naam>.
      3. Het tijdelijke bestand krijgt de originele naam.

    Gaat stap 3 mis (of wordt het script afgebroken), dan wordt stap 2
    teruggedraaid. Het origineel blijft dus altijd bewaard.

    Overgeslagen worden: submappen, symlinks, verborgen bestanden, bestanden
    die al met original_ beginnen en PDF's waarvoor al een original_ bestaat.

    Werkt met Windows PowerShell 5.1 en PowerShell 7 (Windows, macOS, Linux).

.PARAMETER Path
    Map met PDF-bestanden.

.PARAMETER TimeoutSeconds
    Maximale tijd per bestand in seconden (standaard 300).

.PARAMETER GhostscriptPath
    Volledig pad naar de Ghostscript-executable. Zonder deze parameter wordt
    gezocht in PATH en daarna in "Program Files\gs\*\bin".

.EXAMPLE
    .\ConvertPdf.ps1 -Path 'C:\Scans'

.EXAMPLE
    .\ConvertPdf.ps1 'C:\Scans' -TimeoutSeconds 600 -GhostscriptPath 'C:\Tools\gs\bin\gswin64c.exe'

.NOTES
    Exit codes: 0 alles gelukt, 1 minstens een bestand mislukt of een fout vooraf,
    2 geen map opgegeven.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 300,

    [string]$GhostscriptPath
)

function Write-ErrorLine {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Find-Ghostscript {
    <# Geeft het volledige pad naar Ghostscript terug, of $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($name in 'gswin64c', 'gswin32c', 'gs') {
        $cmd = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $cmd) {
            return $cmd.Path
        }
    }

    # De Windows-installer zet Ghostscript niet in PATH
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $roots) {
        $gsRoot = Join-Path -Path $root -ChildPath 'gs'
        $versions = Get-ChildItem -LiteralPath $gsRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Descending -Property {
                $parsed = $null
                if ([version]::TryParse(($_.Name -replace '^gs', ''), [ref]$parsed)) { $parsed } else { [version]'0.0' }
            }
        foreach ($dir in $versions) {
            foreach ($exe in 'gswin64c.exe', 'gswin32c.exe') {
                $candidate = Join-Path -Path (Join-Path -Path $dir.FullName -ChildPath 'bin') -ChildPath $exe
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return $candidate
                }
            }
        }
    }
    return $null
}

function Get-PdfToConvert {
    <# Zoekt PDF's in de map die nog niet verwerkt zijn. #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param([Parameter(Mandatory)][string]$Folder)

    Get-ChildItem -LiteralPath $Folder -File |
        Where-Object {
            $_.Extension -ieq '.pdf' -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -and
            -not $_.Name.StartsWith('.') -and
            -not $_.Name.StartsWith('original_', [System.StringComparison]::Ordinal)
        } |
        Sort-Object -Property Name
}

function Get-GhostscriptArgument {
    <# Bouwt de Ghostscript-argumenten. Paden moeten absoluut zijn. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    @(
        '-dSAFER',
        '-dBATCH',
        '-dNOPAUSE',
        '-dQUIET',
        '-sDEVICE=pdfwrite',
        '-dCompatibilityLevel=1.7',
        '-dAutoRotatePages=/None',
        # '%' in de uitvoernaam is voor Ghostscript een opmaakteken
        ('-sOutputFile=' + $Target.Replace('%', '%%')),
        # Absoluut pad, zodat een bestandsnaam als '-x.pdf' nooit als optie telt
        $Source
    )
}

function ConvertTo-CommandLineArgument {
    <#
    Quote een argument volgens de Windows-regels (CommandLineToArgvW).
    Alleen nodig op Windows PowerShell 5.1; PowerShell 7 gebruikt ArgumentList.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $backslash = [char]92
    $sb = New-Object -TypeName System.Text.StringBuilder
    [void]$sb.Append('"')
    $pending = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq $backslash) {
            $pending++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append($backslash, (2 * $pending) + 1)
        }
        elseif ($pending -gt 0) {
            [void]$sb.Append($backslash, $pending)
        }
        [void]$sb.Append($ch)
        $pending = 0
    }
    if ($pending -gt 0) {
        [void]$sb.Append($backslash, 2 * $pending)
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

function Invoke-ExternalProcess {
    <# Start een proces zonder shell, met time-out. Geeft ExitCode, StdOut en StdErr terug. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $ErrorActionPreference = 'Stop'

    $psi = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    if ($null -ne $psi.GetType().GetProperty('ArgumentList')) {
        foreach ($arg in $ArgumentList) {
            $psi.ArgumentList.Add($arg)
        }
    }
    else {
        $psi.Arguments = ($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }) -join ' '
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $proc.Kill()
            }
            catch {
                Write-Verbose "Proces was al gestopt: $($_.Exception.Message)"
            }
            [void]$proc.WaitForExit(5000)
            throw "time-out na $TimeoutSeconds s."
        }
        $proc.WaitForExit()  # wacht tot de uitvoer volledig is gelezen

        [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdout.Result
            StdErr   = $stderr.Result
        }
    }
    finally {
        $proc.Dispose()
    }
}

function Rename-PdfFile {
    <# Hernoemt een bestand; faalt als het doel al bestaat. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    [System.IO.File]::Move($Source, $Destination)
}

function Convert-PdfFile {
    <# Zet een PDF om. Geeft het pad van het bewaarde origineel terug. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Ghostscript,
        [Parameter(Mandatory)][string]$File,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300
    )
    $ErrorActionPreference = 'Stop'

    $pdf = Convert-Path -LiteralPath $File
    $dir = [System.IO.Path]::GetDirectoryName($pdf)
    $name = [System.IO.Path]::GetFileName($pdf)
    $original = Join-Path -Path $dir -ChildPath ('original_' + $name)

    if (Test-Path -LiteralPath $original) {
        throw "'original_$name' bestaat al, overgeslagen."
    }

    $temp = Join-Path -Path $dir -ChildPath ('.pdfconvert-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $renamed = $false
    $placed = $false
    try {
        $gsArgs = Get-GhostscriptArgument -Source $pdf -Target $temp
        $result = Invoke-ExternalProcess -FilePath $Ghostscript -ArgumentList $gsArgs -TimeoutSeconds $TimeoutSeconds

        if ($result.ExitCode -ne 0) {
            $detail = if ($result.StdErr.Trim()) { $result.StdErr } else { $result.StdOut }
            $lines = @($detail -split '\r?\n' | Where-Object { $_.Trim() })
            $message = "Ghostscript exit code $($result.ExitCode)"
            if ($lines.Count -gt 0) {
                $message += ': ' + $lines[-1].Trim()
            }
            throw $message
        }

        $output = New-Object -TypeName System.IO.FileInfo -ArgumentList $temp
        if (-not $output.Exists -or $output.Length -eq 0) {
            throw 'Ghostscript leverde een leeg bestand op.'
        }

        Rename-PdfFile -Source $pdf -Destination $original
        $renamed = $true
        Rename-PdfFile -Source $temp -Destination $pdf
        $placed = $true
    }
    finally {
        # Loopt ook bij Ctrl+C: origineel terugzetten en tijdelijk bestand opruimen
        if ($renamed -and -not $placed) {
            try {
                Rename-PdfFile -Source $original -Destination $pdf
            }
            catch {
                Write-Warning "Kon origineel niet terugzetten, het staat in '$original'."
            }
        }
        if ([System.IO.File]::Exists($temp)) {
            [System.IO.File]::Delete($temp)
        }
    }

    return $original
}

function Convert-PdfFolder {
    <# Verwerkt alle PDF's in de map. Geeft het aantal mislukte bestanden terug. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Ghostscript,
        [Parameter(Mandatory)][string]$Folder,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300
    )

    $pdfs = @(Get-PdfToConvert -Folder $Folder)
    if ($pdfs.Count -eq 0) {
        Write-Host "Geen nieuwe PDF's gevonden om om te zetten."
        return 0
    }

    $failed = 0
    foreach ($pdf in $pdfs) {
        Write-Host "Omzetten: $($pdf.Name)"
        try {
            $original = Convert-PdfFile -Ghostscript $Ghostscript -File $pdf.FullName -TimeoutSeconds $TimeoutSeconds
            Write-Host "Klaar: '$([System.IO.Path]::GetFileName($original))' (origineel) en '$($pdf.Name)' (nieuw)."
        }
        catch {
            $failed++
            Write-ErrorLine "Mislukt bij '$($pdf.Name)': $($_.Exception.Message) Origineel is niet aangepast."
        }
    }

    Write-Host "Afgerond: $($pdfs.Count - $failed) omgezet, $failed mislukt."
    return $failed
}

function Invoke-ConvertPdf {
    <# Hoofdfunctie. Geeft de exit code terug. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$Path,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300,
        [string]$GhostscriptPath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-ErrorLine 'Gebruik: .\ConvertPdf.ps1 -Path "C:\pad\naar\map" [-TimeoutSeconds 300] [-GhostscriptPath <pad>]'
        return 2
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-ErrorLine "Fout: '$Path' is geen bestaande map."
        return 1
    }
    $folder = Convert-Path -LiteralPath $Path

    if ($GhostscriptPath) {
        if (-not (Test-Path -LiteralPath $GhostscriptPath -PathType Leaf)) {
            Write-ErrorLine "Fout: Ghostscript niet gevonden op '$GhostscriptPath'."
            return 1
        }
        $gs = Convert-Path -LiteralPath $GhostscriptPath
    }
    else {
        $gs = Find-Ghostscript
    }

    if (-not $gs) {
        Write-ErrorLine 'Fout: Ghostscript niet gevonden. Installeer het of geef -GhostscriptPath op.'
        return 1
    }

    $failed = Convert-PdfFolder -Ghostscript $gs -Folder $folder -TimeoutSeconds $TimeoutSeconds
    if ($failed -gt 0) {
        return 1
    }
    return 0
}

# Alleen uitvoeren als het script wordt gestart, niet bij dot-sourcen (tests)
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version 3.0
    exit (Invoke-ConvertPdf -Path $Path -TimeoutSeconds $TimeoutSeconds -GhostscriptPath $GhostscriptPath)
}
