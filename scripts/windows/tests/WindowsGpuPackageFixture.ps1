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

function Write-FixtureCabinet([string]$Directory, [object[]]$Items, [hashtable]$Replace = @{}, [string[]]$Omit = @()) {
    $lines = @('.OPTION EXPLICIT', '.Set CabinetNameTemplate=payload.cab', ".Set DiskDirectoryTemplate=$Directory", '.Set MaxDiskSize=0', '.Set Compress=ON')
    foreach ($item in $Items) {
        if ($item.Name -in $Omit) { continue }
        $source = if ($Replace.ContainsKey($item.Name)) { $Replace[$item.Name] } else { $item.Source }
        $lines += "`"$source`" $($item.Id)"
    }
    $ddf = Join-Path $Directory 'payload.ddf'
    [IO.File]::WriteAllLines($ddf, $lines)
    New-FixtureCabinet -Ddf $ddf -Directory $Directory
    return (Join-Path $Directory 'payload.cab')
}

function Remove-FixtureComObject([object[]]$ComObject) {
    foreach ($object in $ComObject) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($object) }
}

function Write-FixtureMsiCabinet([string]$Msi, [string]$Cabinet) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.OpenDatabase($Msi, 1)
    try {
        $view = $db.OpenView('UPDATE `_Streams` SET `Data` = ? WHERE `Name` = ''payload.cab''')
        $record = $installer.CreateRecord(1)
        try { $record.SetStream(1, $Cabinet); $null = $view.Execute($record); $null = $view.Close() }
        finally { Remove-FixtureComObject @($record, $view) }
        $null = $db.Commit()
    } finally { Remove-FixtureComObject @($db, $installer) }
}

function Invoke-FixtureMsiStatement([string]$Msi, [string]$Statement) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.OpenDatabase($Msi, 1)
    try {
        $view = $db.OpenView($Statement)
        try { $null = $view.Execute(); $null = $view.Close(); $null = $db.Commit() }
        finally { Remove-FixtureComObject @($view) }
    } finally { Remove-FixtureComObject @($db, $installer) }
}

# Build an embedded cabinet and MSI directory/file tables with the CPack install-root shape.
function New-FixtureMsi([string]$Msi, [string]$Cabinet, [object[]]$Items) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.OpenDatabase($Msi, 3)
    try {
        $sql = @(
            'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL PRIMARY KEY `Directory`)',
            'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `Directory_` CHAR(72) NOT NULL PRIMARY KEY `Component`)',
            'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL, `Component_` CHAR(72) NOT NULL, `Sequence` SHORT NOT NULL PRIMARY KEY `File`)',
            'CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` SHORT NOT NULL, `Cabinet` CHAR(255) PRIMARY KEY `DiskId`)',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''TARGETDIR'', NULL, ''SourceDir'')',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''INSTALL_ROOT'', ''TARGETDIR'', ''AccelerANTgine'')',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''bin'', ''INSTALL_ROOT'', ''bin'')',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''models'', ''bin'', ''models'')',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''lib'', ''INSTALL_ROOT'', ''lib'')',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''gst'', ''lib'', ''gstreamer-1.0'')',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''licenses'', ''INSTALL_ROOT'', ''licenses'')',
            'INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES (''ort'', ''licenses'', ''onnxruntime'')',
            # Use format strings because backticks are PowerShell escapes in double-quoted strings.
            ('INSERT INTO `Media` (`DiskId`, `LastSequence`, `Cabinet`) VALUES (1, {0}, ''#payload.cab'')' -f $Items.Count)
        )
        $seq = 0
        foreach ($item in $Items) {
            $seq++
            $sql += 'INSERT INTO `Component` (`Component`, `Directory_`) VALUES (''c{0}'', ''{1}'')' -f $seq, $item.Dir
            $sql += 'INSERT INTO `File` (`File`, `FileName`, `Component_`, `Sequence`) VALUES (''{0}'', ''{1}'', ''c{2}'', {2})' -f $item.Id, $item.Name, $seq
        }
        foreach ($statement in $sql) { $view = $db.OpenView($statement); try { $null = $view.Execute(); $null = $view.Close() } finally { Remove-FixtureComObject @($view) } }
        $view = $db.OpenView('INSERT INTO `_Streams` (`Name`, `Data`) VALUES (?, ?)')
        $record = $installer.CreateRecord(2)
        try { $record.StringData(1) = 'payload.cab'; $record.SetStream(2, $Cabinet); $null = $view.Execute($record); $null = $view.Close() }
        finally { Remove-FixtureComObject @($record, $view) }
        $null = $db.Commit()
    } finally { Remove-FixtureComObject @($db, $installer) }
}

function Get-FixtureMsiItem([object[]]$Group) {
    $index = 0
    foreach ($entry in $Group) {
        foreach ($name in $entry.Names) {
            @{ Id = "f$index"; Source = Join-Path $entry.Directory $name; Name = $name; Dir = $entry.Dir }
            $index++
        }
    }
}

function Add-FixtureZipMember([Collections.IDictionary]$Member, [string]$Directory, [string[]]$Names, [string]$Prefix) {
    foreach ($name in $Names) { $Member["$Prefix$name"] = Join-Path $Directory $name }
}

function Remove-FixtureArchiveEntry([string]$Path, [string]$Member) {
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Update)
    try { $archive.GetEntry($Member).Delete() } finally { $archive.Dispose() }
}

function Copy-FixtureArchiveEntry([string]$Path, [string]$Member, [string]$Source, [switch]$Replace) {
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        if ($Replace) { $archive.GetEntry($Member).Delete() }
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $Source, $Member) | Out-Null
    } finally { $archive.Dispose() }
}

function Write-FixtureArchiveEntry([string]$Path, [string]$Member, [string]$Text, [switch]$Replace) {
    $source = Join-Path $script:entryDir "$([guid]::NewGuid().ToString('N')).txt"
    [IO.File]::WriteAllText($source, $Text)
    Copy-FixtureArchiveEntry -Path $Path -Member $Member -Source $source -Replace:$Replace
}

function Write-FixturePayload([string]$Image, [string]$Bin, [string]$Licenses, [string]$ModelDir, [string]$PluginDir) {
    foreach ($name in $script:modelNames) { Set-Content -LiteralPath (Join-Path $ModelDir $name) -Value "fixture $name" }
    foreach ($name in $script:pluginNames) { New-TestPeFile -Path (Join-Path $PluginDir $name) -Tag $name }
    foreach ($name in $script:gpuNames) {
        New-TestPeFile -Path (Join-Path $Image $name) -Tag $name
        Copy-Item -LiteralPath (Join-Path $Image $name) -Destination $Bin
    }
    foreach ($name in $script:appNames) { New-TestPeFile -Path (Join-Path $Bin $name) -Tag $name }
    foreach ($name in $script:licenseNames) { Set-Content -LiteralPath (Join-Path $Licenses $name) -Value "original $name" }
}

# Give the verifier a fixture-owned source lock and the same pinned helpers as the real checkout.
function New-FixtureRepo([string]$Root, [string]$ModelDir) {
    $fixtureRepo = Join-Path $Root 'fixture-repo'
    $fixtureScripts = Join-Path $fixtureRepo 'scripts\windows'
    $fixtureHub = Join-Path $fixtureRepo 'third_party\ANTfrastructure'
    $null = New-Item -ItemType Directory -Force -Path $fixtureScripts, (Join-Path $fixtureRepo 'models'), `
        (Join-Path $fixtureHub 'windows'), (Join-Path $fixtureHub 'linux'), (Join-Path $fixtureHub 'shared')
    foreach ($name in 'Test-WindowsGpuPackages.ps1', 'Test-WindowsGpuImage.ps1', 'Resolve-BuildModule.ps1') {
        Copy-Item -LiteralPath (Join-Path $script:fixture "scripts\windows\$name") -Destination $fixtureScripts
    }
    foreach ($part in 'windows/scripts', 'linux/scripts', 'shared/python') {
        Copy-Item -LiteralPath (Join-Path $script:fixture "third_party/ANTfrastructure/$part") `
            -Destination (Join-Path $fixtureHub (Split-Path $part -Parent)) -Recurse
    }
    $fixtureLock = Join-Path $fixtureRepo 'models\models.lock'
    $lockRows = foreach ($name in $script:modelNames) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $ModelDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name  https://example.invalid/$name"
    }
    [IO.File]::WriteAllLines($fixtureLock, [string[]]$lockRows, [Text.UTF8Encoding]::new($false))
    return (Join-Path $fixtureScripts 'Test-WindowsGpuPackages.ps1')
}

function New-FixtureMsix([string]$Root, [string]$Bin, [string]$ModelDir, [string]$PluginDir) {
    $stage = Join-Path $Root 'msix-stage'; $null = New-Item -ItemType Directory -Path $stage
    foreach ($name in $script:gpuNames + $script:appNames) { Copy-Item -LiteralPath (Join-Path $Bin $name) -Destination $stage }
    Copy-Item -LiteralPath $ModelDir -Destination $stage -Recurse
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $stage 'lib\gstreamer-1.0')
    foreach ($name in $script:pluginNames) { Copy-Item -LiteralPath (Join-Path $PluginDir $name) -Destination (Join-Path $stage 'lib\gstreamer-1.0') }
    $msixPath = Join-Path $Root 'candidate.msix'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $msixPath)
    return $msixPath
}

function Assert-FixtureRejected([hashtable]$Arguments, [string]$Pattern, [string]$Failure) {
    $rejected = $false
    try { & $script:proof @Arguments }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $rejected = $true }
    if (-not $rejected) { throw $Failure }
}

function Restore-FixtureArchive {
    Copy-Item $script:originalZip $script:zipPath -Force; Copy-Item $script:backup $script:msix -Force
}

function Assert-FixtureArchiveCaseRejected([object[]]$Cases, [string]$Pattern, [switch]$AddEntry) {
    foreach ($case in $Cases) {
        if ($AddEntry) { Write-FixtureArchiveEntry -Path $case.Path -Member $case.Member -Text 'unexpected runtime' }
        else { Remove-FixtureArchiveEntry -Path $case.Path -Member $case.Member }
        Assert-FixtureRejected -Arguments $script:msixArgs -Pattern $Pattern -Failure $case.Failure
        Restore-FixtureArchive
    }
}

function Assert-FixtureModelMutationRejected([string]$ModelDir) {
    foreach ($name in $script:modelNames) {
        foreach ($mutation in 'changed', 'missing') {
            $path = Join-Path $ModelDir $name
            $bytes = [IO.File]::ReadAllBytes($path)
            try {
                if ($mutation -eq 'changed') { [IO.File]::WriteAllText($path, 'tampered') }
                else { Remove-Item -LiteralPath $path }
                Assert-FixtureRejected -Arguments $script:msixArgs -Pattern 'do not match models.lock' -Failure "$mutation staged model file was accepted: $name"
            } finally { [IO.File]::WriteAllBytes($path, $bytes) }
        }
    }
}

function Assert-FixtureMsiDemoMutationRejected([string]$Root, [string]$Msi, [string]$MsiBackup, [string]$BadProvider) {
    foreach ($mutation in 'missing', 'altered') {
        Copy-Item -LiteralPath $MsiBackup -Destination $Msi -Force
        $demoDir = Join-Path $Root "demo-$mutation"; $null = New-Item -ItemType Directory -Path $demoDir
        $omit = @(if ($mutation -eq 'missing') { 'AccelerANTgine_demo.exe' })
        $demoCab = Write-FixtureCabinet -Directory $demoDir -Items $script:items -Replace @{ 'AccelerANTgine_demo.exe' = $BadProvider } -Omit $omit
        Write-FixtureMsiCabinet -Msi $Msi -Cabinet $demoCab
        Assert-FixtureRejected -Arguments $script:msixArgs -Pattern 'package binary verification failed' -Failure "$mutation MSI inference demo was accepted"
    }
}

Import-Module (Join-Path $fixture 'third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') -Function New-TestPeFile, New-TestZipFile
$image = Join-Path $root 'ort\bin'; $wheelDir = Join-Path $root 'wheels'; $bundle = Join-Path $root 'bundle'
$bin = Join-Path $bundle 'bin'; $licenses = Join-Path $bundle 'licenses\onnxruntime'; $packages = Join-Path $root 'packages'
$entryDir = Join-Path $root 'entries'
$null = New-Item -ItemType Directory -Path $image, $wheelDir, $bin, $licenses, $packages, $entryDir -Force
$gpuNames = @('onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll', 'DirectML.dll')
$appNames = @('AccelerANTgine.exe', 'AccelerANTgine_demo.exe', 'AccelerANTgine.dll')
$modelNames = @('deim_dfine_n_coco.onnx', 'deim_dfine_n_coco.LICENSE', 'deim_dfine_n_coco.NOTICE')
$licenseNames = @('LICENSE', 'ThirdPartyNotices.txt')
$modelDir = Join-Path $bin 'models'; $null = New-Item -ItemType Directory -Force -Path $modelDir
$pluginDir = Join-Path $bundle 'lib\gstreamer-1.0'; $null = New-Item -ItemType Directory -Force -Path $pluginDir
$pluginNames = @('gstcoreelements.dll', 'gstwebrtc.dll')
Write-FixturePayload -Image $image -Bin $bin -Licenses $licenses -ModelDir $modelDir -PluginDir $pluginDir
$wheelMembers = [ordered]@{}
Add-FixtureZipMember $wheelMembers $image $gpuNames 'onnxruntime/capi/'
Add-FixtureZipMember $wheelMembers $licenses $licenseNames 'onnxruntime/'
New-TestZipFile -Path (Join-Path $wheelDir 'onnxruntime_gpu-1.0.0-cp315-cp315-win_amd64.whl') -Member $wheelMembers -FileValues
$zipPath = Join-Path $packages 'candidate.zip'
$zipMembers = [ordered]@{}
Add-FixtureZipMember $zipMembers $bin ($gpuNames + $appNames) 'candidate/bin/'
Add-FixtureZipMember $zipMembers $pluginDir $pluginNames 'candidate/lib/gstreamer-1.0/'
Add-FixtureZipMember $zipMembers $modelDir $modelNames 'candidate/bin/models/'
New-TestZipFile -Path $zipPath -Member $zipMembers -FileValues

$items = @(Get-FixtureMsiItem @(
        @{ Dir = 'bin'; Directory = $bin; Names = $gpuNames + $appNames }
        @{ Dir = 'gst'; Directory = $pluginDir; Names = $pluginNames }
        @{ Dir = 'models'; Directory = $modelDir; Names = $modelNames }
        @{ Dir = 'ort'; Directory = $licenses; Names = $licenseNames }
    ))
$cab = Write-FixtureCabinet -Directory $root -Items $items
$msi = Join-Path $packages 'candidate.msi'
New-FixtureMsi -Msi $msi -Cabinet $cab -Items $items

$proof = New-FixtureRepo -Root $root -ModelDir $modelDir
$msix = New-FixtureMsix -Root $root -Bin $bin -ModelDir $modelDir -PluginDir $pluginDir
$packageArgs = @{ Variant = 'nvidia'; OnnxRoot = (Split-Path $image -Parent); WheelDir = $wheelDir; Bundle = $bundle; PackageDir = $packages }
$msixArgs = $packageArgs + @{ MsixPath = $msix }
& $proof @msixArgs
Assert-FixtureModelMutationRejected -ModelDir $modelDir
$backup = Join-Path $root 'original.msix'; Copy-Item -LiteralPath $msix -Destination $backup
Write-FixtureArchiveEntry -Path $msix -Member 'lib/gstreamer-1.0/gstwebrtc.dll' -Text 'tampered' -Replace
Assert-FixtureRejected -Arguments $msixArgs -Pattern 'package binary verification failed' -Failure 'Modified MSIX GStreamer plugin was accepted'
Copy-Item -LiteralPath $backup -Destination $msix -Force
# Replace the embedded MSI cabinet with one whose GStreamer plugin bytes differ.
$msiBackup = Join-Path $root 'original.msi'; Copy-Item -LiteralPath $msi -Destination $msiBackup
$badDir = Join-Path $root 'tampered-cab'; $null = New-Item -ItemType Directory -Path $badDir
$badProvider = Join-Path $badDir 'tampered.dll'; New-TestPeFile -Path $badProvider -Tag 'tampered'
Write-FixtureMsiCabinet -Msi $msi -Cabinet (Write-FixtureCabinet -Directory $badDir -Items $items -Replace @{ 'gstwebrtc.dll' = $badProvider })
Assert-FixtureRejected -Arguments $packageArgs -Pattern 'package binary verification failed' -Failure 'Modified MSI GStreamer plugin was accepted'
Copy-Item -LiteralPath $msiBackup -Destination $msi -Force
# Alter the CPack ZIP provider while preserving its other entries.
Write-FixtureArchiveEntry -Path $zipPath -Member 'candidate/lib/gstreamer-1.0/gstwebrtc.dll' -Text 'tampered' -Replace
Assert-FixtureRejected -Arguments $packageArgs -Pattern 'package binary verification failed' -Failure 'Modified ZIP GStreamer plugin was accepted'
Write-Host 'PASS: synthetic GPU ZIP, MSI and MSIX byte proof and mutated-plugin rejection'


Copy-FixtureArchiveEntry -Path $zipPath -Member 'candidate/lib/gstreamer-1.0/gstwebrtc.dll' -Source (Join-Path $pluginDir 'gstwebrtc.dll') -Replace
$originalZip = Join-Path $root 'original.zip'; Copy-Item $zipPath $originalZip
Assert-FixtureArchiveCaseRejected -Pattern 'package binary verification failed' -Cases @(
    @{ Path = $zipPath; Member = 'candidate/bin/AccelerANTgine_demo.exe'; Failure = 'Missing package member accepted: candidate/bin/AccelerANTgine_demo.exe' },
    @{ Path = $msix; Member = 'AccelerANTgine_demo.exe'; Failure = 'Missing package member accepted: AccelerANTgine_demo.exe' },
    @{ Path = $zipPath; Member = 'candidate/bin/models/deim_dfine_n_coco.onnx'; Failure = 'Missing package member accepted: candidate/bin/models/deim_dfine_n_coco.onnx' },
    @{ Path = $msix; Member = 'models/deim_dfine_n_coco.onnx'; Failure = 'Missing package member accepted: models/deim_dfine_n_coco.onnx' },
    @{ Path = $zipPath; Member = 'candidate/bin/models/deim_dfine_n_coco.NOTICE'; Failure = 'Missing package member accepted: candidate/bin/models/deim_dfine_n_coco.NOTICE' },
    @{ Path = $msix; Member = 'models/deim_dfine_n_coco.NOTICE'; Failure = 'Missing package member accepted: models/deim_dfine_n_coco.NOTICE' }
)
Assert-FixtureArchiveCaseRejected -Pattern 'package binary verification failed' -Cases @(
    @{ Path = $zipPath; Member = 'candidate/lib/gstreamer-1.0/gstwebrtc.dll'; Failure = "Missing plugin accepted: $zipPath" },
    @{ Path = $msix; Member = 'lib/gstreamer-1.0/gstwebrtc.dll'; Failure = "Missing plugin accepted: $msix" }
)
$missingDir = Join-Path $root 'missing-cab'; $null = New-Item -ItemType Directory -Path $missingDir
Write-FixtureMsiCabinet -Msi $msi -Cabinet (Write-FixtureCabinet -Directory $missingDir -Items $items -Omit 'gstwebrtc.dll')
Assert-FixtureRejected -Arguments $packageArgs -Pattern 'package binary verification failed' -Failure 'Missing MSI plugin was accepted'
Write-Host 'PASS: missing GStreamer plugin rejected in ZIP, MSI and MSIX'

Assert-FixtureMsiDemoMutationRejected -Root $root -Msi $msi -MsiBackup $msiBackup -BadProvider $badProvider
Copy-Item -LiteralPath $msiBackup -Destination $msi -Force
Write-Host 'PASS: missing or altered MSI inference demo rejected'

Assert-FixtureArchiveCaseRejected -Pattern 'ORT family' -AddEntry -Cases @(
    @{ Path = $zipPath; Member = 'candidate/bin/models/onnxruntime.dll'; Failure = 'Nested ORT family DLL was accepted: candidate/bin/models/onnxruntime.dll' },
    @{ Path = $msix; Member = 'models/onnxruntime.dll'; Failure = 'Nested ORT family DLL was accepted: models/onnxruntime.dll' }
)
Write-Host 'PASS: unexpected nested ORT family DLL rejected in ZIP and MSIX'

$nestedRuntime = Join-Path $modelDir 'onnxruntime.dll'
[IO.File]::WriteAllText($nestedRuntime, 'unexpected runtime')
try {
    Assert-FixtureRejected -Arguments $msixArgs -Pattern 'ORT family' -Failure 'Nested staged ORT family DLL was accepted'
} finally { Remove-Item -LiteralPath $nestedRuntime -Force }

Invoke-FixtureMsiStatement -Msi $msi -Statement 'INSERT INTO `File` (`File`, `FileName`, `Component_`, `Sequence`) VALUES (''f_extra'', ''onnxruntime.dll'', ''c10'', 1)'
try {
    Assert-FixtureRejected -Arguments $msixArgs -Pattern 'ORT family' -Failure 'Duplicate MSI ORT family DLL was accepted'
} finally { Copy-Item $msiBackup $msi -Force }
Write-Host 'PASS: nested staged and duplicate MSI ORT family DLLs rejected'
