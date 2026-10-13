#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$Models,
    [string]$OutputDirectory,
    [int]$TimeoutSeconds = 600
)
. "$PSScriptRoot/Common.ps1"
if (!$OutputDirectory) { $OutputDirectory = "$script:Repo/build.noindex/windows/media-smoke-$([Guid]::NewGuid().ToString('N'))" }
$testRoot = [IO.Path]::GetFullPath($OutputDirectory)
$package = [IO.Path]::GetFullPath($PackageDirectory)
$cli = Join-Path $package 'helper/digup.exe'
$ffmpeg = Join-Path $package 'helper/ffmpeg.exe'
foreach ($file in @($cli, $ffmpeg)) { if (!(Test-Path -LiteralPath $file)) { throw "Missing packaged runtime: $file" } }
$fixture = Join-Path $testRoot 'Медиа и документы café 🦀'
$source = Join-Path $testRoot 'Исходный код'
$index = Join-Path $testRoot 'index'
New-Item -ItemType Directory -Force $fixture, $source | Out-Null

function Invoke-MediaProcess {
    param([string]$Program, [string[]]$Arguments, [string]$Label, [string]$InputText)
    $start = [Diagnostics.ProcessStartInfo]::new($Program)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($InputText) { $start.RedirectStandardInput = $true; $start.StandardInputEncoding = [Text.Encoding]::UTF8 }
    foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
    $start.Environment['PATH'] = "$env:SystemRoot/System32;$env:SystemRoot"
    $start.Environment['DIGUP_MODELS'] = [IO.Path]::GetFullPath($Models)
    $start.Environment['DIGUP_CPU_ONLY'] = '1'
    foreach ($variable in @('DIGUP_WORKER_DIR', 'DIGUP_BACKENDS', 'DIGUP_FFMPEG')) { $start.Environment.Remove($variable) | Out-Null }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.WriteLine($InputText); $process.StandardInput.Close() }
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill($true); throw "$Label timed out." }
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw "$Label left output handles open." }
        $text = $stdout.GetAwaiter().GetResult()
        $text | Set-Content -LiteralPath "$testRoot/$Label.stdout.txt" -Encoding utf8NoBOM
        $stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$testRoot/$Label.stderr.txt" -Encoding utf8NoBOM
        if ($process.ExitCode -ne 0) { throw "$Label failed (exit $($process.ExitCode)); inspect $testRoot." }
        return $text
    } finally {
        if (!$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Write-TextPDF {
    param([string]$Path, [string[]]$Pages)
    $output = [Text.StringBuilder]::new("%PDF-1.4`n")
    $offsets = [Collections.Generic.List[int]]::new()
    function Add-PDFObject([string]$Body) {
        $offsets.Add([Text.Encoding]::ASCII.GetByteCount($output.ToString()))
        $null = $output.Append("$($offsets.Count) 0 obj`n$Body`nendobj`n")
    }
    Add-PDFObject '<< /Type /Catalog /Pages 2 0 R >>'
    $kids = (0..($Pages.Count - 1) | ForEach-Object { "$(4 + 2 * $_) 0 R" }) -join ' '
    Add-PDFObject "<< /Type /Pages /Kids [$kids] /Count $($Pages.Count) >>"
    Add-PDFObject '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'
    for ($page = 0; $page -lt $Pages.Count; $page++) {
        $lines = [Collections.Generic.List[string]]::new()
        $line = ''
        foreach ($word in $Pages[$page].Split(' ')) {
            if ($line.Length + $word.Length -gt 75) { $lines.Add($line); $line = '' }
            $line += $(if ($line) { ' ' } else { '' }) + $word
        }
        if ($line) { $lines.Add($line) }
        $commands = ($lines | ForEach-Object { '(' + $_.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)') + ') Tj T*' }) -join "`n"
        $stream = "BT /F1 12 Tf 14 TL 50 720 Td`n$commands`nET"
        Add-PDFObject "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents $(5 + 2 * $page) 0 R >>"
        Add-PDFObject "<< /Length $([Text.Encoding]::ASCII.GetByteCount($stream)) >>`nstream`n$stream`nendstream"
    }
    $xref = [Text.Encoding]::ASCII.GetByteCount($output.ToString())
    $null = $output.Append("xref`n0 $($offsets.Count + 1)`n0000000000 65535 f `n")
    foreach ($offset in $offsets) { $null = $output.Append(('{0:D10} 00000 n ' -f $offset) + "`n") }
    $null = $output.Append("trailer`n<< /Size $($offsets.Count + 1) /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n")
    [IO.File]::WriteAllText($Path, $output.ToString(), [Text.Encoding]::ASCII)
}

function Write-XMLDocument {
    param([string]$Path, [hashtable]$Entries)
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $names = @($Entries.Keys | Where-Object { $_ -ne 'mimetype' } | Sort-Object)
        if ($Entries.ContainsKey('mimetype')) { $names = @('mimetype') + $names }
        foreach ($name in $names) {
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression)
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write($Entries[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
}

Write-TextPDF (Join-Path $fixture 'Две страницы.pdf') @(
    'The lighthouse guide describes a coastal beacon. LIGHTHOUSEPDF742 is the searchable reference on the first page. The keeper checks the light each evening and records the wind direction, visibility, sea temperature, and wave height. This log helps passing ships navigate safely through the narrow channel.',
    'The second page records the harbor navigation schedule. SECONDPAGE953 identifies the harbor timetable and its tide measurements. The ferry leaves after sunrise when the water reaches the marked depth. Passengers meet at the wooden pier and the crew checks the ropes before departure.'
)
Write-XMLDocument (Join-Path $fixture 'План экспедиции.docx') @{
    '[Content_Types].xml' = '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
    '_rels/.rels' = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
    'word/document.xml' = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>The Arctic expedition records ice measurements and polar weather. ARCTICDOCX742 is its field notebook identifier.</w:t></w:r></w:p></w:body></w:document>'
}
Write-XMLDocument (Join-Path $fixture 'Заметки сада.odt') @{
    'mimetype' = 'application/vnd.oasis.opendocument.text'
    'META-INF/manifest.xml' = '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>'
    'content.xml' = '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>The orchard grows apples and pears with rainwater irrigation. ORCHARDODT742 identifies the gardeners notebook.</text:p></office:text></office:body></office:document-content>'
}
$reference = Join-Path $script:Repo 'Tests/LlamaRuntimeTests/Reference'
Copy-Item -LiteralPath "$reference/photo.jpg" -Destination "$fixture/Фотография.jpg"
Copy-Item -LiteralPath "$reference/screen.png" -Destination "$fixture/Screenshot интерфейс.png"
Copy-Item -LiteralPath "$reference/speech.wav" -Destination "$fixture/Запись речи.wav"
Invoke-MediaProcess $ffmpeg @('-v', 'error', '-nostdin', '-y', '-loop', '1', '-framerate', '1', '-i', "$reference/photo.jpg",
    '-i', "$reference/speech.wav", '-t', '5', '-c:v', 'mpeg4', '-q:v', '4', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
    "$fixture/Короткий фильм.mp4") 'make-video' | Out-Null
foreach ($name in @('Повреждённый.pdf', 'Повреждённый.docx', 'Повреждённый.jpg')) {
    [IO.File]::WriteAllBytes((Join-Path $fixture $name), [byte[]](0, 1, 2, 3, 255))
}
'Unsupported data remains harmless.' | Set-Content -LiteralPath "$fixture/unknown.unsupported" -Encoding utf8NoBOM
@'
from pathlib import Path
# DANGERCODE742: this file is indexed as source text and must NEVER run.
Path(__file__).with_name("EXECUTED.txt").write_text("Indexing executed a user file")
def describe_temperature():
    return "The temperature sensor records the greenhouse climate"
'@ | Set-Content -LiteralPath "$source/не выполнять.py" -Encoding utf8NoBOM

$indexed = Invoke-MediaProcess $cli @('index', $fixture, '--index', $index) 'index-media'
foreach ($name in @('Две страницы.pdf', 'План экспедиции.docx', 'Заметки сада.odt', 'Фотография.jpg',
        'Screenshot интерфейс.png', 'Запись речи.wav', 'Короткий фильм.mp4')) {
    if ($indexed -notmatch "(?m)^.*\bdone\s+.*$([regex]::Escape($name))") { throw "$name did not index successfully." }
}
foreach ($name in @('Повреждённый.pdf', 'Повреждённый.docx', 'Повреждённый.jpg')) {
    if ($indexed -notmatch "(?m)^.*\bfailed\s+.*$([regex]::Escape($name))") { throw "$name was not rejected safely." }
}

function Search-Words([string]$Query, [string]$Name, [string]$Label) {
    $request = @{ id = 1; op = 'search'; q = $Query; meaning = $false } | ConvertTo-Json -Compress
    $text = Invoke-MediaProcess $cli @('search-service', $fixture, '--index', $index) $Label $request
    $reply = @($text -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 1 })
    if ($reply.Count -ne 1 -or $reply[0].meaning -or !$reply[0].PSObject.Properties['hits']) {
        throw "$Label did not return one complete FTS response."
    }
    $hits = @($reply[0].hits | Where-Object { [IO.Path]::GetFileName($_.path) -eq $Name -and $_.keyword_rank })
    if (!$hits.Count) { throw "$Label did not produce the expected FTS hit." }
    return $hits[0]
}
$page = Search-Words 'SECONDPAGE953' 'Две страницы.pdf' 'pdf-page-two'
if ($page.segment -ne 'page' -or $page.loc -ne 2) { throw 'PDF search lost its page number.' }
Search-Words 'ARCTICDOCX742' 'План экспедиции.docx' 'docx-words' | Out-Null
Search-Words 'ORCHARDODT742' 'Заметки сада.odt' 'odt-words' | Out-Null

foreach ($kind in @('image', 'screenshot', 'audio', 'video')) {
    $hits = @(Invoke-MediaProcess $cli @('search', 'recorded scene or spoken conversation', '--kind', $kind,
        '--index', $index, '--json', '--zgate', '-100', '--word-weight', '0') "meaning-$kind" | ConvertFrom-Json)
    if (!$hits.Count -or !$hits[0].PSObject.Properties['cosine']) { throw "$kind has no real embedding search result." }
    if ($kind -in @('audio', 'video') -and !$hits[0].PSObject.Properties['loc']) { throw "$kind search lost its timestamp." }
}
Invoke-MediaProcess $cli @('index', $source, '--code', '--index', $index) 'index-source' | Out-Null
$codeHits = @(Invoke-MediaProcess $cli @('search', 'code: DANGERCODE742', '--index', $index, '--json') 'search-source' | ConvertFrom-Json)
if (!($codeHits | Where-Object { [IO.Path]::GetFileName($_.path) -eq 'не выполнять.py' -and $_.segment -eq 'lines' })) {
    throw 'The source index did not preserve searchable code lines.'
}
if (Test-Path -LiteralPath "$source/EXECUTED.txt") { throw 'The indexer executed a source fixture.' }
$status = Invoke-MediaProcess $cli @('status', '--index', $index) 'status'
if ($status -notmatch 'vectors: ([1-9][0-9, ]*) in ([1-9][0-9, ]*) segments') { throw 'No actual media vectors were persisted.' }
@{ result = 'passed'; realModel = $true; cpuOnly = $true; path = 'System32 and Windows only';
   checks = @('PDF text and page', 'DOCX', 'ODT', 'image', 'screenshot', 'audio timestamp', 'video timestamp',
       'FTS', 'real multimodal embeddings', 'source lines without execution', 'corrupt files do not crash') } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$testRoot/result.json" -Encoding utf8NoBOM
Write-Host "Real packaged multimodal smoke passed. Evidence: $testRoot"
