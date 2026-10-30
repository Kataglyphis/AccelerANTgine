#requires -Version 7.0
# Real ZIP/MSIX archives and MSI cabinet/database; PE and license bytes are synthetic.
param([Parameter(Mandatory)][string]$Scratch)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$root = Join-Path $Scratch "gst-gpu-$([guid]::NewGuid().ToString('N'))"
if (Test-Path -LiteralPath $root) { throw 'Fixture root already exists' }
$null = New-Item -ItemType Directory -Path $root
function New-FixtureCabinet([string]$Ddf, [string]$Directory) {
    Push-Location $Directory
    try {
        & makecab.exe /F $Ddf | Out-Null
        if ($LASTEXITCODE) { throw 'makecab failed creating fixture cabinet' }
    } finally { Pop-Location }
}
Import-Module (Join-Path $fixture 'third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') -Function New-TestPeFile
$image = Join-Path $root 'ort\bin'; $wheelDir = Join-Path $root 'wheels'; $bundle = Join-Path $root 'bundle'
$bin = Join-Path $bundle 'bin'; $licenses = Join-Path $bundle 'licenses\onnxruntime'; $packages = Join-Path $root 'packages'
$null = New-Item -ItemType Directory -Path $image, $wheelDir, $bin, $licenses, $packages -Force
$gpuNames = @('onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll', 'DirectML.dll')
$appNames = @('AccelerANTgine.exe', 'AccelerANTgine_demo.exe', 'AccelerANTgine.dll')
$pluginDir = Join-Path $bundle 'lib\gstreamer-1.0'; $null = New-Item -ItemType Directory -Force -Path $pluginDir
$pluginNames = @('gstcoreelements.dll', 'gstwebrtc.dll')
foreach ($name in $pluginNames) { New-TestPeFile -Path (Join-Path $pluginDir $name) -Tag $name }
foreach ($name in $gpuNames) {
    New-TestPeFile -Path (Join-Path $image $name) -Tag $name
    Copy-Item -LiteralPath (Join-Path $image $name) -Destination $bin
}
foreach ($name in $appNames) { New-TestPeFile -Path (Join-Path $bin $name) -Tag $name }
foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') { Set-Content -LiteralPath (Join-Path $licenses $name) -Value "original $name" }
$wheel = Join-Path $wheelDir 'onnxruntime_gpu-1.0.0-cp315-cp315-win_amd64.whl'
$zip = [IO.Compression.ZipFile]::Open($wheel, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $gpuNames) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $image $name), "onnxruntime/capi/$name") | Out-Null
    }
    foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $licenses $name), "onnxruntime/$name") | Out-Null
    }
} finally { $zip.Dispose() }
$zipPath = Join-Path $packages 'candidate.zip'
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $gpuNames + $appNames) { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $bin $name), "candidate/bin/$name") | Out-Null }
    foreach ($name in $pluginNames) { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $pluginDir $name), "candidate/lib/gstreamer-1.0/$name") | Out-Null }
} finally { $zip.Dispose() }

# Build an embedded cabinet and MSI directory/file tables with the CPack install-root shape.
$items = @(); $index = 0
foreach ($name in $gpuNames + $appNames) { $items += @{ Id = "f$index"; Source = Join-Path $bin $name; Name = $name; Dir = 'bin' }; $index++ }
foreach ($name in $pluginNames) { $items += @{ Id = "f$index"; Source = Join-Path $pluginDir $name; Name = $name; Dir = 'gst' }; $index++ }
foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') { $items += @{ Id = "f$index"; Source = Join-Path $licenses $name; Name = $name; Dir = 'ort' }; $index++ }
$ddf = Join-Path $root 'payload.ddf'
$lines = @('.OPTION EXPLICIT', '.Set CabinetNameTemplate=payload.cab', ".Set DiskDirectoryTemplate=$root", '.Set MaxDiskSize=0', '.Set Compress=ON')
foreach ($item in $items) { $lines += "`"$($item.Source)`" $($item.Id)" }
[IO.File]::WriteAllLines($ddf, $lines)
New-FixtureCabinet -Ddf $ddf -Directory $root
$cab = Join-Path $root 'payload.cab'; $msi = Join-Path $packages 'candidate.msi'
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.OpenDatabase($msi, 3)
try {
    $sql = @(
        'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL PRIMARY KEY `Directory`)',
        'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `Directory_` CHAR(72) NOT NULL PRIMARY KEY `Component`)',
        'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL, `Component_` CHAR(72) NOT NULL, `Sequence` SHORT NOT NULL PRIMARY KEY `File`)',
        'CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` SHORT NOT NULL, `Cabinet` CHAR(255) PRIMARY KEY `DiskId`)',
        'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''TARGETDIR'', NULL, ''SourceDir'')',
        'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''INSTALL_ROOT'', ''TARGETDIR'', ''AccelerANTgine'')',
        'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''bin'', ''INSTALL_ROOT'', ''bin'')',
        'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''lib'', ''INSTALL_ROOT'', ''lib'')',
        'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''gst'', ''lib'', ''gstreamer-1.0'')',
        'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''licenses'', ''INSTALL_ROOT'', ''licenses'')',
        'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''ort'', ''licenses'', ''onnxruntime'')',
        "INSERT INTO `Media` (`DiskId`, `LastSequence`, `Cabinet`) VALUES (1, $($items.Count), '#payload.cab')"
    )
    # Use format strings because backticks are PowerShell escapes in double-quoted strings.
    $sql[-1] = 'INSERT INTO `Media` (`DiskId`, `LastSequence`, `Cabinet`) VALUES (1, {0}, ''#payload.cab'')' -f $items.Count
    $seq = 0
    foreach ($item in $items) {
        $seq++
        $sql += 'INSERT INTO `Component` (`Component`, `Directory_`) VALUES (''c{0}'', ''{1}'')' -f $seq, $item.Dir
        $sql += 'INSERT INTO `File` (`File`, `FileName`, `Component_`, `Sequence`) VALUES (''{0}'', ''{1}'', ''c{2}'', {2})' -f $item.Id, $item.Name, $seq
    }
    foreach ($statement in $sql) { $view = $db.OpenView($statement); try { $null = $view.Execute(); $null = $view.Close() } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) } }
    $view = $db.OpenView('INSERT INTO `_Streams` (`Name`, `Data`) VALUES (?, ?)')
    $record = $installer.CreateRecord(2)
    try { $record.StringData(1) = 'payload.cab'; $record.SetStream(2, $cab); $null = $view.Execute($record); $null = $view.Close() }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
    $null = $db.Commit()
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }

$proof = Join-Path $fixture 'scripts\windows\Test-WindowsGpuPackages.ps1'
$stage = Join-Path $root 'msix-stage'; $null = New-Item -ItemType Directory -Path $stage
foreach ($name in $gpuNames + $appNames) { Copy-Item -LiteralPath (Join-Path $bin $name) -Destination $stage }
$null = New-Item -ItemType Directory -Force -Path (Join-Path $stage 'lib\gstreamer-1.0')
foreach ($name in $pluginNames) { Copy-Item -LiteralPath (Join-Path $pluginDir $name) -Destination (Join-Path $stage 'lib\gstreamer-1.0') }
$msix = Join-Path $root 'candidate.msix'
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $msix)
& $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages -MsixPath $msix
$backup = Join-Path $root 'original.msix'; Copy-Item -LiteralPath $msix -Destination $backup
$archive = [IO.Compression.ZipFile]::Open($msix, [IO.Compression.ZipArchiveMode]::Update)
try {
    $entry = $archive.GetEntry('lib/gstreamer-1.0/gstwebrtc.dll'); $entry.Delete()
    $entry = $archive.CreateEntry('lib/gstreamer-1.0/gstwebrtc.dll')
    $writer = [IO.StreamWriter]::new($entry.Open()); try { $writer.Write('tampered') } finally { $writer.Dispose() }
} finally { $archive.Dispose() }
$rejected = $false
try { & $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages -MsixPath $msix }
catch { if ($_.Exception.Message -notmatch 'package binary verification failed') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Modified MSIX GStreamer plugin was accepted' }
Copy-Item -LiteralPath $backup -Destination $msix -Force
# Replace the embedded MSI cabinet with one whose GStreamer plugin bytes differ.
$msiBackup = Join-Path $root 'original.msi'; Copy-Item -LiteralPath $msi -Destination $msiBackup
$badDir = Join-Path $root 'tampered-cab'; $null = New-Item -ItemType Directory -Path $badDir
$badProvider = Join-Path $badDir 'tampered.dll'; New-TestPeFile -Path $badProvider -Tag 'tampered'
$badLines = @('.OPTION EXPLICIT', '.Set CabinetNameTemplate=payload.cab', ".Set DiskDirectoryTemplate=$badDir", '.Set MaxDiskSize=0', '.Set Compress=ON')
foreach ($item in $items) {
    $source = if ($item.Name -eq 'gstwebrtc.dll') { $badProvider } else { $item.Source }
    $badLines += "`"$source`" $($item.Id)"
}
$badDdf = Join-Path $badDir 'payload.ddf'; [IO.File]::WriteAllLines($badDdf, $badLines)
New-FixtureCabinet -Ddf $badDdf -Directory $badDir
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.OpenDatabase($msi, 1)
try {
    $view = $db.OpenView('UPDATE `_Streams` SET `Data` = ? WHERE `Name` = ''payload.cab''')
    $record = $installer.CreateRecord(1)
    try { $record.SetStream(1, (Join-Path $badDir 'payload.cab')); $null = $view.Execute($record); $null = $view.Close() }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
    $null = $db.Commit()
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
$rejected = $false
try { & $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages }
catch { if ($_.Exception.Message -notmatch 'package binary verification failed') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Modified MSI GStreamer plugin was accepted' }
Copy-Item -LiteralPath $msiBackup -Destination $msi -Force
# Alter the CPack ZIP provider while preserving its other entries.
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Update)
try {
    $entry = $zip.GetEntry('candidate/lib/gstreamer-1.0/gstwebrtc.dll'); $entry.Delete()
    $entry = $zip.CreateEntry('candidate/lib/gstreamer-1.0/gstwebrtc.dll')
    $writer = [IO.StreamWriter]::new($entry.Open()); try { $writer.Write('tampered') } finally { $writer.Dispose() }
} finally { $zip.Dispose() }
$rejected = $false
try { & $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages }
catch { if ($_.Exception.Message -notmatch 'package binary verification failed') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Modified ZIP GStreamer plugin was accepted' }
Write-Host 'PASS: synthetic GPU ZIP, MSI and MSIX byte proof and mutated-plugin rejection'


$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Update)
try {
    $archive.GetEntry('candidate/lib/gstreamer-1.0/gstwebrtc.dll').Delete()
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $pluginDir 'gstwebrtc.dll'), 'candidate/lib/gstreamer-1.0/gstwebrtc.dll') | Out-Null
} finally { $archive.Dispose() }
$originalZip = Join-Path $root 'original.zip'; Copy-Item $zipPath $originalZip
foreach ($case in @(@{ Path=$zipPath; Member='candidate/bin/AccelerANTgine_demo.exe' }, @{ Path=$msix; Member='AccelerANTgine_demo.exe' })) {
    $archive = [IO.Compression.ZipFile]::Open($case.Path, [IO.Compression.ZipArchiveMode]::Update)
    try { $archive.GetEntry($case.Member).Delete() } finally { $archive.Dispose() }
    $rejected = $false
    try { & $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages -MsixPath $msix }
    catch { if ($_.Exception.Message -notmatch 'package binary verification failed') { throw }; $rejected = $true }
    if (-not $rejected) { throw "Missing inference demo accepted: $($case.Path)" }
    Copy-Item $originalZip $zipPath -Force; Copy-Item $backup $msix -Force
}
foreach ($case in @(@{ Path=$zipPath; Member='candidate/lib/gstreamer-1.0/gstwebrtc.dll' }, @{ Path=$msix; Member='lib/gstreamer-1.0/gstwebrtc.dll' })) {
    $archive = [IO.Compression.ZipFile]::Open($case.Path, [IO.Compression.ZipArchiveMode]::Update)
    try { $archive.GetEntry($case.Member).Delete() } finally { $archive.Dispose() }
    $rejected = $false
    try { & $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages -MsixPath $msix }
    catch { if ($_.Exception.Message -notmatch 'package binary verification failed') { throw }; $rejected = $true }
    if (-not $rejected) { throw "Missing plugin accepted: $($case.Path)" }
    Copy-Item $originalZip $zipPath -Force; Copy-Item $backup $msix -Force
}
$missingDir = Join-Path $root 'missing-cab'; $null = New-Item -ItemType Directory -Path $missingDir
$missingLines = @('.OPTION EXPLICIT', '.Set CabinetNameTemplate=payload.cab', ".Set DiskDirectoryTemplate=$missingDir", '.Set MaxDiskSize=0', '.Set Compress=ON')
foreach ($item in $items) { if ($item.Name -ne 'gstwebrtc.dll') { $missingLines += "`"$($item.Source)`" $($item.Id)" } }
$missingDdf = Join-Path $missingDir 'payload.ddf'; [IO.File]::WriteAllLines($missingDdf, $missingLines)
New-FixtureCabinet -Ddf $missingDdf -Directory $missingDir
$installer = New-Object -ComObject WindowsInstaller.Installer; $db = $installer.OpenDatabase($msi, 1)
try {
    $view = $db.OpenView('UPDATE `_Streams` SET `Data` = ? WHERE `Name` = ''payload.cab'''); $record = $installer.CreateRecord(1)
    try { $record.SetStream(1, (Join-Path $missingDir 'payload.cab')); $null = $view.Execute($record); $null = $view.Close() }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
    $null = $db.Commit()
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
$rejected = $false
try { & $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages }
catch { if ($_.Exception.Message -notmatch 'package binary verification failed') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Missing MSI plugin was accepted' }
Write-Host 'PASS: missing GStreamer plugin rejected in ZIP, MSI and MSIX'

foreach ($mutation in 'missing', 'altered') {
    Copy-Item -LiteralPath $msiBackup -Destination $msi -Force
    $demoDir = Join-Path $root "demo-$mutation"; $null = New-Item -ItemType Directory -Path $demoDir
    $demoLines = @('.OPTION EXPLICIT', '.Set CabinetNameTemplate=payload.cab', ".Set DiskDirectoryTemplate=$demoDir", '.Set MaxDiskSize=0', '.Set Compress=ON')
    foreach ($item in $items) {
        if ($item.Name -eq 'AccelerANTgine_demo.exe' -and $mutation -eq 'missing') { continue }
        $itemSource = if ($item.Name -eq 'AccelerANTgine_demo.exe') { $badProvider } else { $item.Source }
        $demoLines += "`"$itemSource`" $($item.Id)"
    }
    $demoDdf = Join-Path $demoDir 'payload.ddf'; [IO.File]::WriteAllLines($demoDdf, $demoLines)
    New-FixtureCabinet -Ddf $demoDdf -Directory $demoDir
    $installer = New-Object -ComObject WindowsInstaller.Installer; $db = $installer.OpenDatabase($msi, 1)
    try {
        $view = $db.OpenView('UPDATE `_Streams` SET `Data` = ? WHERE `Name` = ''payload.cab'''); $record = $installer.CreateRecord(1)
        try { $record.SetStream(1, (Join-Path $demoDir 'payload.cab')); $null = $view.Execute($record); $null = $view.Close() }
        finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
        $null = $db.Commit()
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
    $rejected = $false
    try { & $proof -Variant nvidia -OnnxRoot (Split-Path $image -Parent) -WheelDir $wheelDir -Bundle $bundle -PackageDir $packages -MsixPath $msix }
    catch { if ($_.Exception.Message -notmatch 'package binary verification failed') { throw }; $rejected = $true }
    if (-not $rejected) { throw "$mutation MSI inference demo was accepted" }
}
Copy-Item -LiteralPath $msiBackup -Destination $msi -Force
Write-Host 'PASS: missing or altered MSI inference demo rejected'
