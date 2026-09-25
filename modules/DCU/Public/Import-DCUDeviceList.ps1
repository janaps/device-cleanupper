<#
    Getting the list of devices in, in the four shapes an administrator
    actually has it:

      -Path       a CSV or Excel export from the asset system
      -Text       whatever was copied out of a mail, a portal or a Word table
      -Rows       rows typed into the grid in the wizard
      (all three end up in the same normalised record)

    Column detection is on purpose forgiving: Dutch and English headers, with
    or without spaces. A single-column list is left "unclassified" - the value
    goes into Raw and the lookup tries it as a serial number first and as a
    device name second, which beats guessing wrong here.
#>

$script:DCUSerialHeaders = @(
    'serial', 'serialnumber', 'serial number', 'serial no', 'serialno', 'sn', 's/n'
    'serienummer', 'serie nummer', 'serienr', 'serie', 'servicetag', 'service tag'
)
$script:DCUNameHeaders = @(
    'devicename', 'device name', 'device', 'computername', 'computer name', 'hostname', 'host name'
    'apparaatnaam', 'apparaat', 'computernaam', 'naam', 'name', 'machine', 'machinename', 'pcname'
)
$script:DCUNoteHeaders = @(
    'note', 'notes', 'opmerking', 'opmerkingen', 'omschrijving', 'description', 'school', 'locatie', 'location'
)

function Import-DCUDeviceList {
    <#
        .SYNOPSIS
            Build the device working set from a file, pasted text or typed rows.
        .DESCRIPTION
            Returns { Step; Rows; Total; Duplicates; Unclassified; Source;
            Columns } where Rows is the normalised device list. Duplicates are
            removed - the same laptop listed twice must not be deleted twice.
        .EXAMPLE
            Import-DCUDeviceList -Path .\leavers.xlsx -Sheet 'Laptops'
        .EXAMPLE
            Import-DCUDeviceList -Text (Get-Clipboard -Raw)
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Text')][string]$Text,
        [Parameter(Mandatory, ParameterSetName = 'Rows')][object[]]$Rows,

        [string]$Sheet,
        [string]$Delimiter,
        [string]$SerialColumn,
        [string]$NameColumn,
        [string]$NoteColumn,

        # Add to an existing list instead of replacing it.
        [object[]]$Existing = @(),

        [pscustomobject]$Session
    )

    if ($Session) { Initialize-DCUContext -Session $Session }

    $records = @()
    $source  = ''
    $columns = @()

    switch ($PSCmdlet.ParameterSetName) {
        'Path' {
            if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
            $source = [IO.Path]::GetFileName($Path)
            $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
            $kind = if ($ext -in '.xlsx', '.xlsm') { 'excel' } else { 'csv' }
            Write-DCULog -Category 'Input' -Message "Reading $kind file: $Path"

            $rows = @(Import-DCUSpreadsheet -Path $Path -Sheet $Sheet -Delimiter $Delimiter)
            if (-not $rows.Count) { throw "No data rows in $Path." }
            $columns = @($rows[0].Keys)

            $map = Resolve-DCUColumnMap -Columns $columns -SerialColumn $SerialColumn -NameColumn $NameColumn -NoteColumn $NoteColumn
            Write-DCULog -Category 'Input' -Message ("Columns: {0}. Using serial='{1}', name='{2}', note='{3}'." -f `
                ($columns -join ', '),
                $(if ($map.Serial) { $map.Serial } else { '-' }),
                $(if ($map.Name) { $map.Name } else { '-' }),
                $(if ($map.Note) { $map.Note } else { '-' }))

            if (-not $map.Serial -and -not $map.Name) {
                # single unnamed column, or headers we do not recognise: take the
                # first column and let the lookup decide what it is
                $first = $columns[0]
                Write-DCULog -Level Warn -Category 'Input' -Message "No serial or device-name column recognised - using the first column ('$first') as an unclassified identifier."
                foreach ($row in $rows) {
                    $v = [string]$row[$first]
                    if (-not $v.Trim()) { continue }
                    $records += New-DCUDeviceRecord -Raw $v.Trim() -Source $kind
                }
            }
            else {
                foreach ($row in $rows) {
                    $serial = if ($map.Serial) { ([string]$row[$map.Serial]).Trim() } else { '' }
                    $name   = if ($map.Name)   { ([string]$row[$map.Name]).Trim() }   else { '' }
                    $note   = if ($map.Note)   { ([string]$row[$map.Note]).Trim() }   else { '' }
                    if (-not $serial -and -not $name) { continue }
                    $records += New-DCUDeviceRecord -Serial $serial -Name $name -Note $note -Source $kind
                }
            }
        }
        'Text' {
            $source = 'pasted text'
            $records = @(ConvertFrom-DCUPastedText -Text $Text)
        }
        'Rows' {
            $source = 'typed in'
            foreach ($row in $Rows) {
                $serial = [string]$row.Serial
                $name   = [string]$row.Name
                $note   = [string]$row.Note
                $raw    = [string]$row.Raw
                if (-not ($serial.Trim() -or $name.Trim() -or $raw.Trim())) { continue }
                $records += New-DCUDeviceRecord -Serial $serial.Trim() -Name $name.Trim() -Note $note.Trim() -Raw $raw.Trim() -Source 'manual'
            }
        }
    }

    # --- merge with what is already there, de-duplicate ---------------------
    # Matching is on the VALUES, not on the record key: the same laptop pasted
    # as a bare serial gets an unclassified R: key while the spreadsheet row got
    # an S: key, and deleting it twice is exactly what must not happen.
    $all = @()
    $claimed = @{}
    $claim = {
        param($Record)
        foreach ($t in @($Record.Serial, $Record.Name, $Record.Raw)) {
            $n = Get-DCUNormalSerial $t
            if ($n) { $claimed[$n] = $true }
        }
    }
    $isDupe = {
        param($Record)
        foreach ($t in @($Record.Serial, $Record.Name, $Record.Raw)) {
            $n = Get-DCUNormalSerial $t
            if ($n -and $claimed.ContainsKey($n)) { return $true }
        }
        $false
    }

    # a caller passing $null lands here as @($null), so skip empties rather than
    # blowing up on a null key
    foreach ($e in @($Existing)) {
        if ($null -eq $e) { continue }
        $r = $e | ConvertTo-DCUDeviceRecord
        if (-not $r -or -not $r.Key) { continue }
        if (& $isDupe $r) { continue }
        & $claim $r
        $all += $r
    }

    $dupes = 0
    foreach ($r in $records) {
        if (& $isDupe $r) { $dupes++; continue }
        & $claim $r
        $all += $r
    }

    $unclassified = @($records | Where-Object { -not $_.Serial -and -not $_.Name -and $_.Raw }).Count

    Write-DCULog -Level Success -Category 'Input' -Message ("{0} device(s) added from {1}{2}. List now holds {3}." -f `
        ($records.Count - $dupes), $source, $(if ($dupes) { " ($dupes duplicate(s) skipped)" } else { '' }), $all.Count)
    if ($unclassified) {
        Write-DCULog -Level Info -Category 'Input' -Message "$unclassified entr(y/ies) have no explicit serial/name column - they will be matched on serial number first, then device name."
    }

    [pscustomobject]@{
        Step         = 'DeviceInput'
        Source       = $source
        Columns      = $columns
        Added        = $records.Count - $dupes
        Duplicates   = $dupes
        Unclassified = $unclassified
        Total        = $all.Count
        Rows         = $all
    }
}

function ConvertFrom-DCUPastedText {
    <#
        .SYNOPSIS
            Turn a pasted block into device records.
        .DESCRIPTION
            Handles one device per line, with the fields separated by a tab,
            semicolon, comma or two-or-more spaces - which covers a copy out of
            Excel, out of a portal table and out of a mail. A first line that
            looks like a header is used to work out which column is which;
            otherwise a two-column paste is read as "serial, name" when the
            first column looks like a serial.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = @(($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^[-=_\s]+$' })
    if (-not $lines.Count) { return @() }

    $split = { param($l) @($l -split "`t|;|,|\s{2,}") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } }

    # header?
    $first = @(& $split $lines[0])
    $headerMap = $null
    if ($first.Count -ge 1) {
        $norm = @($first | ForEach-Object { ($_ -replace '[^a-zA-Z0-9/ ]', '').Trim().ToLowerInvariant() })
        $looksHeader = @($norm | Where-Object { $_ -in $script:DCUSerialHeaders -or $_ -in $script:DCUNameHeaders -or $_ -in $script:DCUNoteHeaders }).Count -gt 0
        if ($looksHeader) {
            $headerMap = @{ Serial = -1; Name = -1; Note = -1 }
            for ($i = 0; $i -lt $norm.Count; $i++) {
                if ($headerMap.Serial -lt 0 -and $norm[$i] -in $script:DCUSerialHeaders) { $headerMap.Serial = $i }
                elseif ($headerMap.Name -lt 0 -and $norm[$i] -in $script:DCUNameHeaders) { $headerMap.Name = $i }
                elseif ($headerMap.Note -lt 0 -and $norm[$i] -in $script:DCUNoteHeaders) { $headerMap.Note = $i }
            }
            $lines = @($lines | Select-Object -Skip 1)
        }
    }

    $out = foreach ($line in $lines) {
        $parts = @(& $split $line)
        if (-not $parts.Count) { continue }

        if ($headerMap) {
            $serial = if ($headerMap.Serial -ge 0 -and $headerMap.Serial -lt $parts.Count) { $parts[$headerMap.Serial] } else { '' }
            $name   = if ($headerMap.Name   -ge 0 -and $headerMap.Name   -lt $parts.Count) { $parts[$headerMap.Name] }   else { '' }
            $note   = if ($headerMap.Note   -ge 0 -and $headerMap.Note   -lt $parts.Count) { $parts[$headerMap.Note] }   else { '' }
            if (-not $serial -and -not $name) { continue }
            New-DCUDeviceRecord -Serial $serial -Name $name -Note $note -Source 'paste'
        }
        elseif ($parts.Count -eq 1) {
            New-DCUDeviceRecord -Raw $parts[0] -Source 'paste'
        }
        else {
            # two or more columns without a header: whichever of the first two
            # looks most like a serial number is the serial
            $a = $parts[0]; $b = $parts[1]
            if ((Test-DCULooksLikeSerial $a) -and -not (Test-DCULooksLikeSerial $b)) {
                New-DCUDeviceRecord -Serial $a -Name $b -Note (($parts | Select-Object -Skip 2) -join ' ') -Source 'paste'
            }
            elseif ((Test-DCULooksLikeSerial $b) -and -not (Test-DCULooksLikeSerial $a)) {
                New-DCUDeviceRecord -Serial $b -Name $a -Note (($parts | Select-Object -Skip 2) -join ' ') -Source 'paste'
            }
            else {
                New-DCUDeviceRecord -Serial $a -Name $b -Note (($parts | Select-Object -Skip 2) -join ' ') -Source 'paste'
            }
        }
    }
    @($out)
}

function Test-DCULooksLikeSerial {
    <#
        A rough shape test, only used to decide which of two unlabelled columns
        is the serial number. Getting it wrong is not fatal - the lookup tries
        every value it has against both the serial and the device-name index -
        it only affects how the row reads on screen.

        Serials are short, unbroken alphanumerics with at least one digit.
        Windows device names in this tenant look like LT-0001 or NKA-LAP07, so
        a separator is the strongest signal that a value is a name.
    #>
    param([string]$Value)
    if (-not $Value) { return $false }
    $v = $Value.Trim()
    if ($v.Length -lt 4 -or $v.Length -gt 24) { return $false }
    if ($v -match '[-_\s\.@\\/]') { return $false }
    if ($v -match '^[0-9]+$') { return $true }
    ($v -match '^[A-Za-z0-9]+$') -and ($v -match '[0-9]')
}

function Resolve-DCUColumnMap {
    <# Which spreadsheet column holds what. Explicit names win over detection. #>
    param(
        [Parameter(Mandatory)][string[]]$Columns,
        [string]$SerialColumn, [string]$NameColumn, [string]$NoteColumn
    )
    $norm = @{}
    foreach ($c in $Columns) { $norm[($c -replace '[^a-zA-Z0-9/ ]', '').Trim().ToLowerInvariant()] = $c }

    $pick = {
        param($explicit, $candidates)
        if ($explicit) {
            $match = $Columns | Where-Object { $_ -eq $explicit } | Select-Object -First 1
            if ($match) { return $match }
            $match = $Columns | Where-Object { $_.Trim().ToLowerInvariant() -eq $explicit.Trim().ToLowerInvariant() } | Select-Object -First 1
            if ($match) { return $match }
            throw "Column '$explicit' is not in the file. Available columns: $($Columns -join ', ')"
        }
        foreach ($cand in $candidates) { if ($norm.ContainsKey($cand)) { return $norm[$cand] } }
        ''
    }

    @{
        Serial = & $pick $SerialColumn $script:DCUSerialHeaders
        Name   = & $pick $NameColumn   $script:DCUNameHeaders
        Note   = & $pick $NoteColumn   $script:DCUNoteHeaders
    }
}
