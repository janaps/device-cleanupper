#requires -Version 7.2
<#
    Builds a minimal but real .xlsx (a zip of XML parts, shared strings and
    all) so the smoke tests can exercise the built-in reader without Excel or
    any module being installed.

        .\New-TestWorkbook.ps1 -Path .\devices.xlsx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$SheetName = 'Laptops'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# the strings, in the order they are referenced from the sheet
$strings = @('Serienummer', 'Apparaatnaam', '5CD1111AAA', 'LT-0001', '5CD2222BBB', 'LT-0002')

$contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
</Types>
'@

$rootRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
'@

$workbook = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="$SheetName" sheetId="1" r:id="rId1"/></sheets>
</workbook>
"@

$workbookRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>
'@

$si = ($strings | ForEach-Object { "<si><t>$_</t></si>" }) -join ''
$sharedStrings = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="$($strings.Count)" uniqueCount="$($strings.Count)">$si</sst>
"@

# row 1 = headers, rows 2-3 = data; all cells are shared-string references
$sheet = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
    <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row>
    <row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" t="s"><v>5</v></c></row>
  </sheetData>
</worksheet>
'@

$parts = [ordered]@{
    '[Content_Types].xml'        = $contentTypes
    '_rels/.rels'                = $rootRels
    'xl/workbook.xml'            = $workbook
    'xl/_rels/workbook.xml.rels' = $workbookRels
    'xl/sharedStrings.xml'       = $sharedStrings
    'xl/worksheets/sheet1.xml'   = $sheet
}

if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $parts.Keys) {
        $entry = $zip.CreateEntry($name)
        $sw = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
        try { $sw.Write($parts[$name]) } finally { $sw.Dispose() }
    }
}
finally { $zip.Dispose() }

$Path
