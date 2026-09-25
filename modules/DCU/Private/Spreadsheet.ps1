<#
    Reading device lists out of the files an administrator actually has.

    CSV   Import-Csv with the delimiter sniffed from the header line, because
          a Dutch Excel export is ";" separated and everything else is ",".
    XLSX  read straight out of the package (it is a zip with XML in it), so
          neither Excel nor the ImportExcel module has to be installed. Only
          what is needed here: the used range of one sheet as rows of strings.

    Both come back as an array of ordered hashtables (header -> cell text), the
    same shape Import-Csv rows have, so Import-DCUDeviceList treats them alike.
#>

function Get-DCUCsvDelimiter {
    <# ; , or tab - whichever occurs most in the header line. #>
    param([Parameter(Mandatory)][string]$Path)
    $line = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
    if (-not $line) { return ',' }
    $counts = @{
        ';'    = ([regex]::Matches($line, ';')).Count
        ','    = ([regex]::Matches($line, ',')).Count
        "`t"   = ([regex]::Matches($line, "`t")).Count
    }
    $best = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    if ($best.Value -eq 0) { return ',' }
    $best.Key
}

function Import-DCUSpreadsheet {
    <#
        .SYNOPSIS
            Read a CSV or XLSX file into rows of ordered hashtables.
        .DESCRIPTION
            The file type is taken from the extension. For .xlsx the sheet can
            be picked by name; without one the first sheet is used.
        .EXAMPLE
            Import-DCUSpreadsheet -Path .\laptops.xlsx -Sheet 'Uit dienst'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Sheet,
        [string]$Delimiter
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()

    switch ($ext) {
        '.xlsx' { return (Import-DCUXlsx -Path $Path -Sheet $Sheet) }
        '.xlsm' { return (Import-DCUXlsx -Path $Path -Sheet $Sheet) }
        '.xls'  { throw "The old .xls format is not supported. Save it as .xlsx or .csv first." }
        default {
            if (-not $Delimiter) { $Delimiter = Get-DCUCsvDelimiter -Path $Path }
            $rows = @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter)
            $out = foreach ($r in $rows) {
                $h = [ordered]@{}
                foreach ($p in $r.PSObject.Properties) { $h[[string]$p.Name] = [string]$p.Value }
                $h
            }
            return @($out)
        }
    }
}

function Import-DCUXlsx {
    <#
        Minimal .xlsx reader: opens the package, resolves the sheet, and returns
        the used range with the first row as headers. Values come back as the
        raw stored text, so a long numeric serial is never mangled into
        scientific notation the way a cast would do it.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Sheet
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        # --- shared strings ---------------------------------------------------
        $shared = @()
        $ssEntry = $zip.Entries | Where-Object { $_.FullName -eq 'xl/sharedStrings.xml' } | Select-Object -First 1
        if ($ssEntry) {
            $x = [xml](Read-DCUZipText $ssEntry)
            $shared = foreach ($si in $x.DocumentElement.ChildNodes) {
                (($si.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText }) -join '')
            }
            $shared = @($shared)
        }

        # --- which sheet ------------------------------------------------------
        $wbEntry = $zip.Entries | Where-Object { $_.FullName -eq 'xl/workbook.xml' } | Select-Object -First 1
        if (-not $wbEntry) { throw "Not a valid .xlsx file (no xl/workbook.xml): $Path" }
        $wb = [xml](Read-DCUZipText $wbEntry)
        $sheets = @($wb.SelectNodes('//*[local-name()="sheet"]'))
        if (-not $sheets.Count) { throw "The workbook has no sheets: $Path" }

        $want = $null
        if ($Sheet) {
            $want = $sheets | Where-Object { $_.GetAttribute('name') -eq $Sheet } | Select-Object -First 1
            if (-not $want) {
                $names = ($sheets | ForEach-Object { $_.GetAttribute('name') }) -join ', '
                throw "Sheet '$Sheet' not found. This workbook has: $names"
            }
        }
        else { $want = $sheets[0] }

        $rid = $want.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $target = 'worksheets/sheet1.xml'
        $relEntry = $zip.Entries | Where-Object { $_.FullName -eq 'xl/_rels/workbook.xml.rels' } | Select-Object -First 1
        if ($relEntry -and $rid) {
            $rels = [xml](Read-DCUZipText $relEntry)
            $rel = $rels.SelectNodes('//*[local-name()="Relationship"]') | Where-Object { $_.GetAttribute('Id') -eq $rid } | Select-Object -First 1
            if ($rel) { $target = $rel.GetAttribute('Target') }
        }
        $target = $target -replace '^/xl/', '' -replace '^\./', ''
        $sheetPath = if ($target -like 'xl/*') { $target } else { "xl/$target" }

        $shEntry = $zip.Entries | Where-Object { $_.FullName -eq $sheetPath } | Select-Object -First 1
        if (-not $shEntry) { throw "Sheet part not found in the workbook: $sheetPath" }

        # --- cells ------------------------------------------------------------
        $sx = [xml](Read-DCUZipText $shEntry)
        $rowNodes = @($sx.SelectNodes('//*[local-name()="row"]'))
        $grid = [System.Collections.Generic.List[string[]]]::new()
        $width = 0

        foreach ($rn in $rowNodes) {
            $cells = @{}
            foreach ($cn in $rn.SelectNodes('./*[local-name()="c"]')) {
                $ref = $cn.GetAttribute('r')
                $col = Convert-DCUColumnRef $ref
                if ($col -lt 0) { continue }
                $t = $cn.GetAttribute('t')
                $text = ''
                if ($t -eq 's') {
                    $vn = $cn.SelectSingleNode('./*[local-name()="v"]')
                    if ($vn) {
                        $idx = 0
                        if ([int]::TryParse($vn.InnerText, [ref]$idx) -and $idx -lt $shared.Count) { $text = [string]$shared[$idx] }
                    }
                }
                elseif ($t -eq 'inlineStr') {
                    $text = (($cn.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText }) -join '')
                }
                else {
                    $vn = $cn.SelectSingleNode('./*[local-name()="v"]')
                    if ($vn) { $text = [string]$vn.InnerText }
                }
                $cells[$col] = $text
                if ($col + 1 -gt $width) { $width = $col + 1 }
            }
            $max = if ($cells.Keys.Count) { ($cells.Keys | Measure-Object -Maximum).Maximum + 1 } else { 0 }
            $arr = New-Object 'string[]' $max
            foreach ($k in $cells.Keys) { $arr[$k] = $cells[$k] }
            [void]$grid.Add($arr)
        }

        if ($grid.Count -eq 0) { return @() }

        # --- header + rows ----------------------------------------------------
        $headerRow = $grid[0]
        $headers = New-Object 'string[]' $width
        for ($i = 0; $i -lt $width; $i++) {
            $h = if ($i -lt $headerRow.Count -and $headerRow[$i]) { [string]$headerRow[$i] } else { '' }
            if (-not $h.Trim()) { $h = "Column$($i + 1)" }
            $headers[$i] = $h.Trim()
        }

        $out = for ($r = 1; $r -lt $grid.Count; $r++) {
            $row = $grid[$r]
            $h = [ordered]@{}
            $any = $false
            for ($i = 0; $i -lt $width; $i++) {
                $v = if ($i -lt $row.Count -and $null -ne $row[$i]) { [string]$row[$i] } else { '' }
                $h[$headers[$i]] = $v
                if ($v.Trim()) { $any = $true }
            }
            if ($any) { $h }
        }
        return @($out)
    }
    finally { $zip.Dispose() }
}

function Read-DCUZipText {
    param([Parameter(Mandatory)]$Entry)
    $sr = [System.IO.StreamReader]::new($Entry.Open())
    try { $sr.ReadToEnd() } finally { $sr.Dispose() }
}

function Convert-DCUColumnRef {
    <# "BC12" -> 54 (0-based column index). -1 when the reference is unusable. #>
    param([string]$Ref)
    if (-not $Ref) { return -1 }
    $letters = ($Ref -replace '\d', '').ToUpperInvariant()
    if (-not $letters) { return -1 }
    $n = 0
    foreach ($ch in $letters.ToCharArray()) {
        $v = [int][char]$ch - 64
        if ($v -lt 1 -or $v -gt 26) { return -1 }
        $n = $n * 26 + $v
    }
    $n - 1
}
