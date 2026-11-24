#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester-tests voor ConvertPdf.ps1.

    De meeste tests vervangen Ghostscript door een mock. De integratietests
    onderaan gebruiken de echte Ghostscript en worden overgeslagen als die
    niet gevonden wordt.
#>

BeforeDiscovery {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'ConvertPdf.ps1')
    $hasGhostscript = [bool](Find-Ghostscript)
}

BeforeAll {
    $script:ScriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'ConvertPdf.ps1'
    . $script:ScriptPath

    $script:MinimalPdf = [System.Text.Encoding]::ASCII.GetBytes(
        "%PDF-1.4`n" +
        "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj`n" +
        "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj`n" +
        "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj`n" +
        "trailer << /Root 1 0 R >>`n" +
        "%%EOF`n"
    )
    $script:PowerShellExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    function Initialize-TestFolder {
        param([string]$Name = [guid]::NewGuid().ToString('N'))
        $folder = Join-Path -Path $TestDrive -ChildPath $Name
        [void](New-Item -ItemType Directory -Path $folder)
        $folder
    }

    function Write-TestPdf {
        param([string]$Path, [byte[]]$Bytes = $script:MinimalPdf)
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
    }

    function Get-TempFileCount {
        param([string]$Folder)
        @(Get-ChildItem -LiteralPath $Folder -Force | Where-Object { $_.Name -like '.pdfconvert-*' }).Count
    }

    function Test-StartsWithConverted {
        param([string]$Path)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(9, $bytes.Length)) -eq 'CONVERTED'
    }

    # Nep-Ghostscript: schrijft 'CONVERTED' + invoer naar het uitvoerbestand
    $script:FakeGhostscriptOk = {
        $outArg = $ArgumentList | Where-Object { $_ -like '-sOutputFile=*' } | Select-Object -First 1
        $target = $outArg.Substring(13).Replace('%%', '%')
        $source = $ArgumentList[-1]
        $bytes = [System.Text.Encoding]::ASCII.GetBytes('CONVERTED') + [System.IO.File]::ReadAllBytes($source)
        [System.IO.File]::WriteAllBytes($target, [byte[]]$bytes)
        [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
    }
}

Describe 'Get-PdfToConvert' {
    It 'geeft alleen nieuwe, gewone PDF-bestanden terug' {
        $folder = Initialize-TestFolder
        Write-TestPdf (Join-Path $folder 'b.pdf')
        Write-TestPdf (Join-Path $folder 'A.PDF')
        Write-TestPdf (Join-Path $folder 'original_c.pdf')
        Write-TestPdf (Join-Path $folder '.hidden.pdf')
        Set-Content -LiteralPath (Join-Path $folder 'notes.txt') -Value 'x'
        [void](New-Item -ItemType Directory -Path (Join-Path $folder 'sub.pdf'))

        $names = @(Get-PdfToConvert -Folder $folder | ForEach-Object { $_.Name })

        $names | Should -Be @('A.PDF', 'b.pdf')
    }

    It 'slaat symlinks over' {
        $folder = Initialize-TestFolder
        $outside = Join-Path $TestDrive 'buiten.pdf'
        Write-TestPdf $outside
        try {
            [void](New-Item -ItemType SymbolicLink -Path (Join-Path $folder 'link.pdf') -Value $outside -ErrorAction Stop)
        }
        catch {
            Set-ItResult -Skipped -Because "symlink maken is hier niet toegestaan: $($_.Exception.Message)"
            return
        }

        @(Get-PdfToConvert -Folder $folder).Count | Should -Be 0
    }
}

Describe 'Get-GhostscriptArgument' {
    It 'gebruikt -dSAFER, zet de bron als laatste en escapet %' {
        $gsArgs = Get-GhostscriptArgument -Source '/map/-x.pdf' -Target '/map/uit%d.tmp'

        $gsArgs | Should -Contain '-dSAFER'
        $gsArgs | Should -Contain '-sOutputFile=/map/uit%%d.tmp'
        $gsArgs[-1] | Should -Be '/map/-x.pdf'
    }
}

Describe 'ConvertTo-CommandLineArgument' {
    It 'quote <Name> correct' -TestCases @(
        @{ Name = 'eenvoudig'; In = 'abc'; Out = 'abc' }
        @{ Name = 'spatie'; In = 'a b'; Out = '"a b"' }
        @{ Name = 'slash aan het eind'; In = 'C:\a b\'; Out = '"C:\a b\\"' }
        @{ Name = 'aanhalingsteken'; In = 'x"y'; Out = '"x\"y"' }
        @{ Name = 'slash voor aanhalingsteken'; In = 'a\"b'; Out = '"a\\\"b"' }
        @{ Name = 'leeg'; In = ''; Out = '""' }
        @{ Name = 'slashes in pad'; In = 'C:\p q\r.pdf'; Out = '"C:\p q\r.pdf"' }
    ) {
        ConvertTo-CommandLineArgument -Argument $In | Should -BeExactly $Out
    }
}

Describe 'Invoke-ExternalProcess' {
    It 'geeft exit code en stderr terug' {
        $result = Invoke-ExternalProcess -FilePath $script:PowerShellExe -TimeoutSeconds 60 -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-Command', "[Console]::Error.WriteLine('boem'); exit 3"
        )

        $result.ExitCode | Should -Be 3
        $result.StdErr | Should -Match 'boem'
    }

    It 'geeft argumenten met spaties ongeschonden door' {
        $echo = Join-Path $TestDrive 'echo.ps1'
        Set-Content -LiteralPath $echo -Value '$args | ForEach-Object { [Console]::Out.WriteLine("<$_>") }'

        $result = Invoke-ExternalProcess -FilePath $script:PowerShellExe -TimeoutSeconds 60 -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $echo,
            'a b', 'C:\p q\r.pdf', 'eind\'
        )

        $result.ExitCode | Should -Be 0
        @($result.StdOut -split '\r?\n' | Where-Object { $_ }) | Should -Be @('<a b>', '<C:\p q\r.pdf>', '<eind\>')
    }

    It 'stopt het proces na de time-out' {
        $start = Get-Date
        {
            Invoke-ExternalProcess -FilePath $script:PowerShellExe -TimeoutSeconds 2 -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60'
            )
        } | Should -Throw '*time-out na 2 s.*'
        ((Get-Date) - $start).TotalSeconds | Should -BeLessThan 30
    }
}

Describe 'Convert-PdfFile' {
    BeforeEach {
        $folder = Initialize-TestFolder
        $pdf = Join-Path $folder 'doc.pdf'
        Write-TestPdf $pdf
    }

    It 'zet om en bewaart het origineel' {
        Mock Invoke-ExternalProcess $script:FakeGhostscriptOk

        $original = Convert-PdfFile -Ghostscript 'gs' -File $pdf

        $original | Should -Be (Join-Path (Convert-Path -LiteralPath $folder) 'original_doc.pdf')
        [System.IO.File]::ReadAllBytes($original) | Should -Be $script:MinimalPdf
        Test-StartsWithConverted $pdf | Should -BeTrue
        Get-TempFileCount $folder | Should -Be 0
    }

    It 'laat het origineel staan als Ghostscript faalt' {
        Mock Invoke-ExternalProcess {
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "Error: /syntaxerror in pdf`n" }
        }

        { Convert-PdfFile -Ghostscript 'gs' -File $pdf } | Should -Throw '*exit code 1: Error: /syntaxerror*'

        [System.IO.File]::ReadAllBytes($pdf) | Should -Be $script:MinimalPdf
        Test-Path -LiteralPath (Join-Path $folder 'original_doc.pdf') | Should -BeFalse
        Get-TempFileCount $folder | Should -Be 0
    }

    It 'gebruikt stdout als stderr leeg is' {
        Mock Invoke-ExternalProcess {
            [pscustomobject]@{ ExitCode = 1; StdOut = "regel 1`r`nUnrecoverable error`r`n"; StdErr = '' }
        }

        { Convert-PdfFile -Ghostscript 'gs' -File $pdf } | Should -Throw '*Unrecoverable error*'
    }

    It 'faalt bij een leeg uitvoerbestand' {
        Mock Invoke-ExternalProcess {
            $outArg = $ArgumentList | Where-Object { $_ -like '-sOutputFile=*' } | Select-Object -First 1
            [System.IO.File]::WriteAllBytes($outArg.Substring(13), [byte[]]@())
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }

        { Convert-PdfFile -Ghostscript 'gs' -File $pdf } | Should -Throw '*leeg bestand*'

        [System.IO.File]::ReadAllBytes($pdf) | Should -Be $script:MinimalPdf
        Get-TempFileCount $folder | Should -Be 0
    }

    It 'slaat over als original_ al bestaat' {
        Mock Invoke-ExternalProcess $script:FakeGhostscriptOk
        Set-Content -LiteralPath (Join-Path $folder 'original_doc.pdf') -Value 'ouder' -NoNewline

        { Convert-PdfFile -Ghostscript 'gs' -File $pdf } | Should -Throw '*bestaat al*'

        Get-Content -LiteralPath (Join-Path $folder 'original_doc.pdf') -Raw | Should -Be 'ouder'
        Should -Invoke Invoke-ExternalProcess -Times 0
    }

    It 'geeft een time-out door' {
        Mock Invoke-ExternalProcess { throw 'time-out na 1 s.' }

        { Convert-PdfFile -Ghostscript 'gs' -File $pdf -TimeoutSeconds 1 } | Should -Throw '*time-out*'

        [System.IO.File]::ReadAllBytes($pdf) | Should -Be $script:MinimalPdf
        Get-TempFileCount $folder | Should -Be 0
    }

    It 'zet het origineel terug als het nieuwe bestand niet geplaatst kan worden' {
        Mock Invoke-ExternalProcess $script:FakeGhostscriptOk
        Mock Rename-PdfFile { throw 'schijf vol' } -ParameterFilter { $Source -like '*.pdfconvert-*' }

        { Convert-PdfFile -Ghostscript 'gs' -File $pdf } | Should -Throw '*schijf vol*'

        [System.IO.File]::ReadAllBytes($pdf) | Should -Be $script:MinimalPdf
        Test-Path -LiteralPath (Join-Path $folder 'original_doc.pdf') | Should -BeFalse
        Get-TempFileCount $folder | Should -Be 0
    }

    It 'geeft absolute paden door, ook bij een relatieve naam met streepje' {
        Mock Invoke-ExternalProcess $script:FakeGhostscriptOk
        Write-TestPdf (Join-Path $folder '-dNOSAFER.pdf')

        Push-Location -LiteralPath $folder
        try {
            [void](Convert-PdfFile -Ghostscript 'gs' -File '-dNOSAFER.pdf')
        }
        finally {
            Pop-Location
        }

        Should -Invoke Invoke-ExternalProcess -Times 1 -ParameterFilter {
            [System.IO.Path]::IsPathRooted($ArgumentList[-1]) -and $ArgumentList[-1].EndsWith('-dNOSAFER.pdf')
        }
        [System.IO.File]::ReadAllBytes((Join-Path $folder 'original_-dNOSAFER.pdf')) | Should -Be $script:MinimalPdf
    }
}

Describe 'Convert-PdfFolder' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-ErrorLine { }
        Mock Invoke-ExternalProcess $script:FakeGhostscriptOk
    }

    It 'telt mislukte bestanden en gaat door met de rest' {
        $folder = Initialize-TestFolder
        Write-TestPdf (Join-Path $folder 'a.pdf')
        Write-TestPdf (Join-Path $folder 'b.pdf')
        Set-Content -LiteralPath (Join-Path $folder 'original_b.pdf') -Value 'ouder'

        Convert-PdfFolder -Ghostscript 'gs' -Folder $folder | Should -Be 1

        Test-Path -LiteralPath (Join-Path $folder 'original_a.pdf') | Should -BeTrue
        Should -Invoke Write-ErrorLine -Times 1 -ParameterFilter { $Message -like "*'b.pdf'*" }
        Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Afgerond: 1 omgezet, 1 mislukt.' }
    }

    It 'meldt een lege map' {
        $folder = Initialize-TestFolder

        Convert-PdfFolder -Ghostscript 'gs' -Folder $folder | Should -Be 0

        Should -Invoke Write-Host -ParameterFilter { $Object -like "Geen nieuwe PDF's*" }
    }

    It 'verwerkt een bestand bij een tweede run niet opnieuw' {
        $folder = Initialize-TestFolder
        Write-TestPdf (Join-Path $folder 'a.pdf')

        Convert-PdfFolder -Ghostscript 'gs' -Folder $folder | Should -Be 0
        Convert-PdfFolder -Ghostscript 'gs' -Folder $folder | Should -Be 1

        [System.IO.File]::ReadAllBytes((Join-Path $folder 'original_a.pdf')) | Should -Be $script:MinimalPdf
    }
}

Describe 'Invoke-ConvertPdf' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-ErrorLine { }
    }

    It 'geeft 2 zonder map' {
        Invoke-ConvertPdf | Should -Be 2
    }

    It 'geeft 1 bij een niet-bestaande map' {
        Invoke-ConvertPdf -Path (Join-Path $TestDrive 'bestaat-niet') | Should -Be 1
        Should -Invoke Write-ErrorLine -ParameterFilter { $Message -like '*geen bestaande map*' }
    }

    It 'geeft 1 als Ghostscript ontbreekt' {
        Mock Find-Ghostscript { $null }
        Invoke-ConvertPdf -Path (Initialize-TestFolder) | Should -Be 1
        Should -Invoke Write-ErrorLine -ParameterFilter { $Message -like '*Ghostscript niet gevonden*' }
    }

    It 'geeft 1 bij een ongeldig -GhostscriptPath' {
        Invoke-ConvertPdf -Path (Initialize-TestFolder) -GhostscriptPath (Join-Path $TestDrive 'geen-gs.exe') |
            Should -Be 1
    }

    It 'geeft 0 als alles lukt' {
        Mock Invoke-ExternalProcess $script:FakeGhostscriptOk
        $folder = Initialize-TestFolder
        Write-TestPdf (Join-Path $folder 'a.pdf')
        $fakeGs = Join-Path $TestDrive 'gs.exe'
        Set-Content -LiteralPath $fakeGs -Value ''

        Invoke-ConvertPdf -Path $folder -GhostscriptPath $fakeGs | Should -Be 0
        Should -Invoke Invoke-ExternalProcess -Times 1 -ParameterFilter { $FilePath -eq $fakeGs }
    }

    It 'geeft 1 als een bestand mislukt' {
        Mock Find-Ghostscript { 'gs' }
        Mock Invoke-ExternalProcess { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fout' } }
        $folder = Initialize-TestFolder
        Write-TestPdf (Join-Path $folder 'a.pdf')

        Invoke-ConvertPdf -Path $folder | Should -Be 1
    }
}

Describe 'Script als programma' {
    It 'geeft exit code <Code> bij <Name>' -TestCases @(
        @{ Name = 'een niet-bestaande map'; Code = 1; Extra = @('-Path', 'map-die-echt-niet-bestaat-123') }
        @{ Name = 'geen argumenten'; Code = 2; Extra = @() }
    ) {
        $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:ScriptPath) + $Extra
        $null = & $script:PowerShellExe @psArgs 2>&1
        $LASTEXITCODE | Should -Be $Code
    }
}

Describe 'Integratie met echte Ghostscript' -Skip:(-not $hasGhostscript) {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-ErrorLine { }
    }

    It 'zet een PDF om in een map met spatie en % in de naam' {
        $folder = Initialize-TestFolder -Name 'map met spatie 100%'
        $pdf = Join-Path $folder 'echt bestand.pdf'
        Write-TestPdf $pdf

        Invoke-ConvertPdf -Path $folder | Should -Be 0

        [System.IO.File]::ReadAllBytes((Join-Path $folder 'original_echt bestand.pdf')) | Should -Be $script:MinimalPdf
        $header = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($pdf), 0, 8)
        $header | Should -Be '%PDF-1.7'
        Get-TempFileCount $folder | Should -Be 0
    }

    It 'laat een kapotte PDF ongemoeid' {
        $folder = Initialize-TestFolder
        $pdf = Join-Path $folder 'kapot.pdf'
        Write-TestPdf $pdf -Bytes ([System.Text.Encoding]::ASCII.GetBytes('dit is geen pdf'))

        Invoke-ConvertPdf -Path $folder | Should -Be 1

        [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($pdf)) | Should -Be 'dit is geen pdf'
        Test-Path -LiteralPath (Join-Path $folder 'original_kapot.pdf') | Should -BeFalse
        Get-TempFileCount $folder | Should -Be 0
    }
}
