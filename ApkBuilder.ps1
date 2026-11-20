using namespace System.Windows.Forms
using namespace System.Drawing
# Lightweight APK Builder
# One window that sets up a minimal Android toolchain (JDK 17 + SDK) inside this folder
# and builds Android projects into APK files. No Android Studio. No system changes:
# JAVA_HOME / ANDROID_HOME are only set for the programs this app starts.
# ASCII only on purpose (Windows PowerShell 5.1 reads BOM-less files as ANSI).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

$Root       = $PSScriptRoot
$ConfigFile = Join-Path $Root 'settings.json'
$OutDir     = Join-Path $Root 'APK_Output'
$JdkDir     = Join-Path $Root 'tools\jdk'
$DlDir      = Join-Path $Root 'tools\downloads'
$LogFile    = Join-Path $Root 'last_build_log.txt'
$Cfg        = @{ sdkDir = (Join-Path $Root 'AndroidSDK'); project = '' }
$script:busy = $false
$script:Downloaded = 0
$script:LastOutput = ''

foreach ($d in @($OutDir, (Join-Path $Root 'Projects'), $DlDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
if (Test-Path $ConfigFile) {
    try {
        $j = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($j.sdkDir)  { $Cfg.sdkDir  = $j.sdkDir }
        if ($j.project) { $Cfg.project = $j.project }
    } catch {}
}
function Save-Cfg { $Cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding ASCII }

# ---------------------------------------------------------------- UI helpers
function Add-Log($t)  { $script:log.AppendText($t + "`r`n") }
function Set-Op($t)   { $script:opLabel.Text = $t; [Application]::DoEvents() }
function Show-Msg($text, $icon = 'Information') { [void][MessageBox]::Show($text, 'Lightweight APK Builder', 'OK', $icon) }
function Ask-YesNo($text) { return ([MessageBox]::Show($text, 'Lightweight APK Builder', 'YesNo', 'Question') -eq 'Yes') }
function Set-Status($lbl, $text, $ok) {
    $lbl.Text = $text
    if ($ok) { $lbl.ForeColor = [Color]::SeaGreen } else { $lbl.ForeColor = [Color]::Firebrick }
}

# ---------------------------------------------------------------- process helpers
function Run-Capture($exe, $cmdArgs, $timeoutMs = 30000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $cmdArgs; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) { try { $p.Kill() } catch {} }
    return ($o.Result + "`n" + $e.Result)
}

function Handle-Line($line, $sb) {
    [void]$sb.AppendLine($line)
    if ($line -match '^\s*\[[=\s]*\]') { $script:opLabel.Text = $line.Trim(); return }   # sdkmanager progress bars
    Add-Log $line
}

# Runs a program, shows its output live in the log, keeps the window responsive. Returns exit code.
function Run-Streaming($file, $cmdArgs, $workDir, $stdinText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $file; $psi.Arguments = $cmdArgs; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    if ($workDir) { $psi.WorkingDirectory = $workDir }
    $sb = New-Object System.Text.StringBuilder
    $p = [System.Diagnostics.Process]::Start($psi)
    try { if ($stdinText) { $p.StandardInput.Write($stdinText) }; $p.StandardInput.Close() } catch {}
    $so = $p.StandardOutput.ReadLineAsync(); $se = $p.StandardError.ReadLineAsync()
    $exitedAt = $null
    while ($so -or $se) {
        $did = $false
        if ($so -and $so.IsCompleted) {
            $line = $so.Result
            if ($null -eq $line) { $so = $null } else { Handle-Line $line $sb; $so = $p.StandardOutput.ReadLineAsync() }
            $did = $true
        }
        if ($se -and $se.IsCompleted) {
            $line = $se.Result
            if ($null -eq $line) { $se = $null } else { Handle-Line $line $sb; $se = $p.StandardError.ReadLineAsync() }
            $did = $true
        }
        if (-not $did) {
            [Application]::DoEvents(); Start-Sleep -Milliseconds 30
            if ($p.HasExited) {
                if (-not $exitedAt) { $exitedAt = Get-Date }
                elseif (((Get-Date) - $exitedAt).TotalSeconds -gt 2) { break }
            }
        }
    }
    [void]$p.WaitForExit(5000)
    $script:LastOutput = $sb.ToString()
    if ($p.HasExited) { return $p.ExitCode } else { return -1 }
}

# Runs a .bat file (sdkmanager.bat, gradlew.bat) through cmd.exe
function Run-Bat($bat, $batArgs, $workDir, $stdinText) {
    return (Run-Streaming 'cmd.exe' ('/c ""{0}" {1}"' -f $bat, $batArgs) $workDir $stdinText)
}

# ---------------------------------------------------------------- downloads
function Download-File($url, $dest, $label) {
    Set-Op "Downloading $label ..."
    $script:bar.Style = 'Continuous'; $script:bar.Value = 0
    $read = 0; $in = $null; $out = $null; $resp = $null
    try {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'LightweightAPKBuilder'; $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
        $resp = $req.GetResponse(); $total = $resp.ContentLength
        $in = $resp.GetResponseStream(); $out = [IO.File]::Create($dest)
        $buf = New-Object byte[] 65536; $last = [DateTime]::Now
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $read += $n
            if (([DateTime]::Now - $last).TotalMilliseconds -gt 150) {
                $last = [DateTime]::Now
                if ($total -gt 0) { $script:bar.Value = [int](100 * $read / $total) }
                $script:opLabel.Text = ('Downloading {0}: {1:N1} of {2:N1} MB' -f $label, ($read / 1MB), ($total / 1MB))
                [Application]::DoEvents()
            }
        }
    } catch {
        if ($out) { $out.Close(); $out = $null }
        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        throw "Download of $label failed or was interrupted. Check your internet connection and try again.`nDetails: $($_.Exception.Message)"
    } finally {
        if ($out) { $out.Close() }; if ($in) { $in.Close() }; if ($resp) { $resp.Close() }
    }
    $script:Downloaded += $read
    $script:bar.Value = 100
}

function Verify-Hash($file, $algo, $expected, $label) {
    Set-Op "Verifying $label ..."
    $h = (Get-FileHash -Path $file -Algorithm $algo).Hash
    if ($h -ne $expected) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        throw "The downloaded $label file failed its $algo check (expected $expected, got $h). It was deleted. Please try again."
    }
    Add-Log "  $label checksum ($algo) OK"
}

function Get-JdkMeta {
    $r = Invoke-RestMethod 'https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jdk&os=windows'
    $p = $r | Where-Object { $_.binary.package.link -like '*.zip' } | Select-Object -First 1
    if (-not $p) { throw 'Could not find a JDK 17 download from Adoptium.' }
    return @{ url = $p.binary.package.link; sha256 = $p.binary.package.checksum; size = [long]$p.binary.package.size; name = $p.binary.package.name }
}

function Get-CmdToolsMeta {
    $txt = (Invoke-WebRequest 'https://dl.google.com/android/repository/repository2-1.xml' -UseBasicParsing).Content
    if ($txt -isnot [string]) { $txt = [Text.Encoding]::UTF8.GetString($txt) }
    $xml = New-Object System.Xml.XmlDocument
    $xml.LoadXml($txt.TrimStart([char]0xFEFF))
    $n = $xml.SelectSingleNode("//remotePackage[@path='cmdline-tools;latest']/archives/archive[host-os='windows']/complete")
    if (-not $n) { throw 'Could not find the Android command-line tools in Google''s package list.' }
    $c = $n.SelectSingleNode('checksum')
    return @{ url = ('https://dl.google.com/android/repository/' + $n.SelectSingleNode('url').InnerText); size = [long]$n.SelectSingleNode('size').InnerText; algo = $c.GetAttribute('type').ToUpper(); hash = $c.InnerText.Trim() }
}

# ---------------------------------------------------------------- environment detection
function Get-JavaMajor($jh) {
    $j = Join-Path $jh 'bin\java.exe'
    if (-not (Test-Path $j)) { return 0 }
    $o = Run-Capture $j '-version'
    if ($o -match 'version "(\d+)(?:\.(\d+))?') {
        $m = [int]$Matches[1]; if ($m -eq 1) { $m = [int]$Matches[2] }; return $m
    }
    return 0
}

function Find-Jdk {
    if (Test-Path $JdkDir) {
        $d = Get-ChildItem $JdkDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } | Select-Object -First 1
        if ($d) { return $d.FullName }
    }
    if ($env:JAVA_HOME) { $m = Get-JavaMajor $env:JAVA_HOME; if ($m -ge 17 -and $m -le 21) { return $env:JAVA_HOME } }
    return $null
}

function Get-SdkManager { return (Join-Path $Cfg.sdkDir 'cmdline-tools\latest\bin\sdkmanager.bat') }
function Get-Adb        { return (Join-Path $Cfg.sdkDir 'platform-tools\adb.exe') }

function Set-BuildEnv {
    $jh = Find-Jdk
    if (-not $jh) { return $false }
    $sdk = $Cfg.sdkDir
    $env:JAVA_HOME = $jh; $env:ANDROID_HOME = $sdk; $env:ANDROID_SDK_ROOT = $sdk
    $env:Path = "$jh\bin;$sdk\platform-tools;$sdk\cmdline-tools\latest\bin;" + $env:Path
    return $true
}

function Get-DirSizeMB($p) {
    if (-not (Test-Path $p)) { return 0 }
    $s = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $s) { return 0 }
    return [math]::Round($s / 1MB, 0)
}

# ---------------------------------------------------------------- project inspection
function Read-Text($p) { if (Test-Path $p) { return (Get-Content $p -Raw) } else { return '' } }
function First-Match($text, $pattern) { if ($text -and $text -match $pattern) { return $Matches[1] } else { return $null } }

function Test-ProjectFolder($p) {
    if (-not ((Test-Path "$p\settings.gradle.kts") -or (Test-Path "$p\settings.gradle"))) {
        throw "This does not look like an Android project: settings.gradle(.kts) is missing.`nPick the top-level project folder (the one that contains the 'app' folder)."
    }
    if (-not ((Test-Path "$p\app\build.gradle.kts") -or (Test-Path "$p\app\build.gradle"))) {
        throw "app\build.gradle(.kts) is missing. This tool expects a standard project with an 'app' module."
    }
}

function Get-ProjectInfo($p) {
    $app = Read-Text "$p\app\build.gradle.kts"; if (-not $app) { $app = Read-Text "$p\app\build.gradle" }
    $toml = Read-Text "$p\gradle\libs.versions.toml"
    $rootGradle = (Read-Text "$p\build.gradle.kts") + (Read-Text "$p\build.gradle")
    $wrap = Read-Text "$p\gradle\wrapper\gradle-wrapper.properties"
    $q = '[\x22\x27]'
    $info = @{}
    $info.compileSdk = First-Match $app 'compileSdk(?:Version)?\s*[=(\s]\s*(\d+)'
    if (-not $info.compileSdk) { $info.compileSdk = First-Match $app 'compileSdk\s*\{[^}]*release\((\d+)' }
    if (-not $info.compileSdk) { $info.compileSdk = First-Match $toml 'compileSdk\s*=\s*[\x22]?(\d+)' }
    $info.targetSdk = First-Match $app 'targetSdk(?:Version)?\s*[=(\s]\s*(\d+)'
    if (-not $info.targetSdk) { $info.targetSdk = First-Match $toml 'targetSdk\s*=\s*[\x22]?(\d+)' }
    $info.minSdk = First-Match $app 'minSdk(?:Version)?\s*[=(\s]\s*(\d+)'
    if (-not $info.minSdk) { $info.minSdk = First-Match $toml 'minSdk\s*=\s*[\x22]?(\d+)' }
    $info.agp = First-Match $toml 'agp\s*=\s*[\x22]([^\x22]+)'
    if (-not $info.agp) { $info.agp = First-Match $rootGradle 'com\.android\.application.{0,12}version\s*.{0,3}?([0-9][0-9A-Za-z.\-]*)' }
    $info.kotlin = First-Match $toml 'kotlin\s*=\s*[\x22]([^\x22]+)'
    if (-not $info.kotlin) { $info.kotlin = First-Match $rootGradle 'kotlin.android.{0,12}version\s*.{0,3}?([0-9][0-9A-Za-z.\-]*)' }
    $info.gradle = First-Match $wrap 'gradle-([0-9][0-9.]*)-(?:bin|all)\.zip'
    $info.buildTools = First-Match $app 'buildToolsVersion\s*[=(\s]\s*[\x22\x27](\d+\.\d+\.\d+)'
    return $info
}

function Show-ProjectInfo($info) {
    Add-Log '--- Project settings found (read only, nothing is changed) ---'
    foreach ($k in 'compileSdk', 'targetSdk', 'minSdk', 'agp', 'kotlin', 'gradle', 'buildTools') {
        $v = $info[$k]; if (-not $v) { $v = '(not found)' }
        Add-Log ('  {0,-11} {1}' -f $k, $v)
    }
}

function Get-TargetPlatform {
    if ($Cfg.project -and (Test-Path $Cfg.project)) {
        try { $i = Get-ProjectInfo $Cfg.project; if ($i.compileSdk) { return [int]$i.compileSdk } } catch {}
    }
    return 34
}

# ---------------------------------------------------------------- status panel
function Refresh-Status {
    $jh = Find-Jdk
    if ($jh) { Set-Status $script:lJava ('Ready - JDK ' + (Get-JavaMajor $jh)) $true } else { Set-Status $script:lJava 'Not installed' $false }

    $sdk = $Cfg.sdkDir
    if (Test-Path (Get-SdkManager)) { Set-Status $script:lSdk 'Ready' $true } else { Set-Status $script:lSdk 'Not installed' $false }

    $plats = @(); if (Test-Path "$sdk\platforms") { $plats = @(Get-ChildItem "$sdk\platforms" -Directory | ForEach-Object { $_.Name -replace '^android-', 'API ' }) }
    if ($plats.Count) { Set-Status $script:lPlat ($plats -join ', ') $true } else { Set-Status $script:lPlat 'None installed' $false }

    $bt = @(); if (Test-Path "$sdk\build-tools") { $bt = @(Get-ChildItem "$sdk\build-tools" -Directory | ForEach-Object { $_.Name }) }
    if ($bt.Count) { Set-Status $script:lBt ($bt -join ', ') $true } else { Set-Status $script:lBt 'Downloaded automatically on the first build' $true }

    if ($Cfg.project -and (Test-Path $Cfg.project)) { Set-Status $script:lProj $Cfg.project $true } else { Set-Status $script:lProj 'No project selected' $false }

    $jm = Get-DirSizeMB $JdkDir; $sm = Get-DirSizeMB $sdk
    $script:lDisk.Text = ('{0:N0} MB used  (JDK {1:N0} MB + Android SDK {2:N0} MB)   SDK folder: {3}' -f ($jm + $sm), $jm, $sm, $sdk)
    $script:lDisk.ForeColor = [Color]::DimGray
    [Application]::DoEvents()
}

# ---------------------------------------------------------------- install
function Install-Environment {
    $sdk = $Cfg.sdkDir
    $drive = [IO.Path]::GetPathRoot($sdk)
    try { $free = (New-Object IO.DriveInfo($drive)).AvailableFreeSpace } catch { $free = [long]::MaxValue }
    if ($free -lt 3GB) {
        throw ('Not enough free disk space on {0}: {1:N1} GB free, about 3 GB are needed (tools + Gradle cache). Free some space or use "Change SDK Folder".' -f $drive, ($free / 1GB))
    }
    $platform = Get-TargetPlatform
    $script:Downloaded = 0

    $needJdk = -not (Find-Jdk)
    $needCmd = -not (Test-Path (Get-SdkManager))
    $plan = @()
    $jdkMeta = $null; $cmdMeta = $null
    if ($needJdk) { Set-Op 'Looking up JDK 17 ...'; $jdkMeta = Get-JdkMeta; $plan += ('JDK 17 (portable, Adoptium) - {0:N0} MB' -f ($jdkMeta.size / 1MB)) }
    if ($needCmd) { Set-Op 'Looking up Android tools ...'; $cmdMeta = Get-CmdToolsMeta; $plan += ('Android command-line tools (Google) - {0:N0} MB' -f ($cmdMeta.size / 1MB)) }
    $plan += ('Android platform-tools + SDK platform API {0} (exact sizes are shown by Android''s installer in the log)' -f $platform)
    $msg = "These items will be downloaded from the official sources:`n`n- " + ($plan -join "`n- ") +
           "`n`nInstall location:`n$sdk`nand $JdkDir`n`nYour Windows settings will not be changed. Continue?"
    if (-not (Ask-YesNo $msg)) { Add-Log 'Setup cancelled.'; return }

    if ($needJdk) {
        $zip = Join-Path $DlDir $jdkMeta.name
        Download-File $jdkMeta.url $zip 'JDK 17'
        Verify-Hash $zip 'SHA256' $jdkMeta.sha256 'JDK 17'
        Set-Op 'Unpacking JDK 17 ...'; $script:bar.Style = 'Marquee'; [Application]::DoEvents()
        if (Test-Path $JdkDir) { Remove-Item $JdkDir -Recurse -Force }
        New-Item -ItemType Directory -Path $JdkDir | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $JdkDir)
        Remove-Item $zip -Force
        Add-Log '  JDK 17 ready.'
    }
    if ($needCmd) {
        $zip = Join-Path $DlDir 'cmdline-tools.zip'
        Download-File $cmdMeta.url $zip 'Android command-line tools'
        Verify-Hash $zip $cmdMeta.algo $cmdMeta.hash 'Android command-line tools'
        Set-Op 'Unpacking Android tools ...'; $script:bar.Style = 'Marquee'; [Application]::DoEvents()
        $tmp = Join-Path $sdk '_tmp'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        New-Item -ItemType Directory -Path (Join-Path $sdk 'cmdline-tools') -Force | Out-Null
        $latest = Join-Path $sdk 'cmdline-tools\latest'
        if (Test-Path $latest) { Remove-Item $latest -Recurse -Force }
        Move-Item (Join-Path $tmp 'cmdline-tools') $latest
        Remove-Item $tmp -Recurse -Force; Remove-Item $zip -Force
        Add-Log '  Android command-line tools ready.'
    }

    if (-not (Set-BuildEnv)) { throw 'JDK setup did not complete. Please try again.' }
    $sm = Get-SdkManager
    $script:bar.Style = 'Marquee'

    $lic = "Android's SDK components are covered by Google's license agreement:`nhttps://developer.android.com/studio/terms`n`nDo you accept the Android SDK licenses?"
    if (-not (Ask-YesNo $lic)) { Add-Log 'Licenses not accepted - stopping. The SDK cannot be installed without accepting them.'; return }

    Set-Op 'Accepting Android SDK licenses ...'
    $code = Run-Bat $sm ('--sdk_root="{0}" --licenses' -f $sdk) $sdk ("y`n" * 40)
    if ($code -ne 0) { throw 'Accepting the SDK licenses failed. See the log above for the original message.' }

    Set-Op 'Installing platform-tools and SDK platform ...'
    $code = Run-Bat $sm ('--sdk_root="{0}" "platform-tools" "platforms;android-{1}"' -f $sdk, $platform) $sdk $null
    if ($code -ne 0) { throw "sdkmanager failed (exit code $code). Check your internet connection; the original message is in the log." }

    Refresh-Status
    $jm = Get-DirSizeMB $JdkDir; $sz = Get-DirSizeMB $sdk
    Add-Log ''
    Add-Log '=== Setup finished ==='
    Add-Log ('Downloaded by this app (JDK + tools): {0:N0} MB. Android installer downloads (platform etc.) are on top of that.' -f ($script:Downloaded / 1MB))
    Add-Log ('Installed size: JDK {0:N0} MB + Android SDK {1:N0} MB = {2:N0} MB' -f $jm, $sz, ($jm + $sz))
    Add-Log "Location: $JdkDir  and  $sdk"
    Set-Op 'Setup finished.'
    Show-Msg "Android environment is ready.`n`nNext: click 'Select Android Project', then 'Build APK'."
}

# ---------------------------------------------------------------- build
$Hints = @(
    @('SDK location not found|ANDROID_HOME|ANDROID_SDK_ROOT', 'The Android SDK was not found. Click "Install Android Environment".'),
    @('UnknownHostException|Could not GET|Could not HEAD|Connection (timed out|reset)|Read timed out|Could not resolve (all|com|org)|Network is unreachable', 'Network problem. Gradle needs internet the first time to fetch its own files and libraries. Check your connection and click Build APK again.'),
    @('Unsupported class file major version|requires Java|Java 17|Unsupported Java|JAVA_HOME', 'Java version problem. This tool uses JDK 17; the project may need a different Java or a newer Gradle. Check the Gradle version line in the project settings above.'),
    @('licenses? (have|has) not been accepted|Failed to install the following Android SDK packages|Missing SDK package|failed to find (Build Tools|target)', 'An SDK part is missing or a license is not accepted. Click "Install Android Environment" again, then rebuild.'),
    @('e: file:///|Unresolved reference|Compilation error|Type mismatch', 'Kotlin compile error in the project code. Look for lines starting with "e:" in the log - they name the file and line.'),
    @('AAPT|resource (linking )?failed|Android resource|error: resource', 'Android resource error (layout, drawable, manifest or string problem). The line mentioning the file in the log shows where.'),
    @('Could not resolve|Could not find|Cannot resolve', 'A Gradle dependency could not be downloaded. Check your internet and the dependency name/version in the build file.'),
    @('No space left|not enough space|disk is full', 'The disk is full. Free some space and try again.')
)

function Get-Hint($text) {
    foreach ($h in $Hints) { if ($text -match $h[0]) { return $h[1] } }
    return 'The build failed. The original Gradle message is in the log above; the first line starting with "FAILURE" or "e:" usually explains why.'
}

function Build-Apk {
    $proj = $Cfg.project
    if (-not $proj -or -not (Test-Path $proj)) { throw 'Please click "Select Android Project" first.' }
    Test-ProjectFolder $proj
    if (-not ((Test-Path "$proj\gradlew.bat") -and (Test-Path "$proj\gradle\wrapper\gradle-wrapper.jar"))) {
        throw "The project has no Gradle Wrapper (gradlew.bat and gradle\wrapper\gradle-wrapper.jar).`nIf the project came from Android Studio or GitHub it normally includes them - re-download the full project folder."
    }
    $info = Get-ProjectInfo $proj
    Show-ProjectInfo $info
    if (-not $info.compileSdk) { Add-Log 'Note: compileSdk not detected; the SDK platform will be fetched by Gradle if needed.' }

    $platOk = $true
    if ($info.compileSdk) { $platOk = Test-Path (Join-Path $Cfg.sdkDir ('platforms\android-' + $info.compileSdk)) }
    $ready = [bool](Find-Jdk) -and (Test-Path (Get-SdkManager)) -and $platOk
    if (-not $ready) {
        if (-not (Ask-YesNo 'The Android tools are not fully set up for this project yet. Set them up now?')) { return }
        Install-Environment
        $platOk = $true
        if ($info.compileSdk) { $platOk = Test-Path (Join-Path $Cfg.sdkDir ('platforms\android-' + $info.compileSdk)) }
        if (-not ([bool](Find-Jdk) -and (Test-Path (Get-SdkManager)) -and $platOk)) { return }
    }
    if (-not (Set-BuildEnv)) { throw 'JDK not found. Click "Install Android Environment".' }

    Add-Log ''
    Add-Log '=== Building (gradlew assembleDebug) ==='
    Add-Log 'First build downloads Gradle and libraries and can take several minutes. Later builds are faster.'
    Set-Op 'Building APK - please wait ...'
    $script:bar.Style = 'Marquee'; $script:bar.MarqueeAnimationSpeed = 30
    $start = Get-Date
    $code = Run-Bat (Join-Path $proj 'gradlew.bat') 'assembleDebug --console=plain --no-daemon' $proj $null
    try { Set-Content -Path $LogFile -Value $script:LastOutput } catch {}

    if ($code -ne 0) {
        $hint = Get-Hint $script:LastOutput
        Add-Log ''; Add-Log "BUILD FAILED (exit code $code)."; Add-Log "Hint: $hint"
        Set-Op 'Build failed.'
        Show-Msg ("The build failed.`n`n$hint`n`nThe original error text is in the log window (also saved to last_build_log.txt).") 'Error'
        return
    }
    $apk = Get-ChildItem -Path $proj -Filter *.apk -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\build\\outputs\\apk\\' -and $_.LastWriteTime -ge $start.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apk) { throw 'Gradle reported success but no new APK was found under build\outputs\apk.' }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
    $dest = Join-Path $OutDir ((Split-Path $proj -Leaf) + '-debug.apk')
    Copy-Item $apk.FullName $dest -Force
    Add-Log ''; Add-Log ('BUILD SUCCESSFUL - APK saved to: {0}  ({1:N1} MB)' -f $dest, ((Get-Item $dest).Length / 1MB))
    Set-Op 'Build successful.'
    Refresh-Status
    Show-Msg ("Your APK is ready:`n$dest`n`nClick 'Install on Phone' to put it on your phone, or copy it there yourself.")
}

# ---------------------------------------------------------------- phone
function Install-ToPhone {
    $adb = Get-Adb
    if (-not (Test-Path $adb)) { throw 'adb was not found. Click "Install Android Environment" first.' }
    $apk = Get-ChildItem $OutDir -Filter *.apk -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $apk) { throw 'There is no APK in APK_Output yet. Click "Build APK" first.' }
    Set-Op 'Looking for your phone ...'
    [void](Run-Capture $adb 'start-server' 20000)
    $out = Run-Capture $adb 'devices -l'
    $devs = @()
    foreach ($l in ($out -split "`r?`n")) {
        if ($l -match '^(\S+)\s+(device|unauthorized|offline)\b(.*)$') {
            $serial = $Matches[1]; $state = $Matches[2]; $rest = $Matches[3]
            $model = $serial; if ($rest -match 'model:(\S+)') { $model = $Matches[1] -replace '_', ' ' }
            $devs += @{ serial = $serial; state = $state; model = $model }
        }
    }
    if ($devs.Count -eq 0) {
        Add-Log $out
        throw "No phone found.`n`n1. On the phone: Settings > About phone > tap 'Build number' 7 times.`n2. Settings > Developer options > turn on 'USB debugging'.`n3. Connect with a USB cable that carries data and unlock the phone.`n4. Click Install on Phone again."
    }
    $dev = $devs | Where-Object { $_.state -eq 'device' } | Select-Object -First 1
    if (-not $dev) {
        $d = $devs[0]
        if ($d.state -eq 'unauthorized') { throw "'$($d.model)' is connected but has not allowed this computer.`nLook at the phone screen and tap 'Allow' on the USB debugging prompt (tick 'Always allow'), then try again." }
        throw "'$($d.model)' shows as '$($d.state)'. Unplug and replug the cable, unlock the phone and try again."
    }
    if (-not (Ask-YesNo ("Install {0} on {1}?" -f $apk.Name, $dev.model))) { Add-Log 'Install cancelled.'; return }
    Set-Op 'Installing on phone ...'
    $script:bar.Style = 'Marquee'
    $code = Run-Streaming $adb ('-s {0} install -r "{1}"' -f $dev.serial, $apk.FullName) $null $null
    if ($code -eq 0 -and $script:LastOutput -match 'Success') {
        Set-Op 'Installed.'; Show-Msg "Installed on $($dev.model). Look for the app on the phone."
    } else {
        throw ("Install failed. Original message:`n" + $script:LastOutput.Trim())
    }
}

# ---------------------------------------------------------------- window
$form = New-Object Form
$form.Text = 'Lightweight APK Builder'
$form.ClientSize = New-Object Size(780, 690)
$form.MinimumSize = New-Object Size(720, 600)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Font('Segoe UI', 9.5)

$title = New-Object Label
$title.Text = 'Lightweight APK Builder'; $title.Font = New-Object Font('Segoe UI', 18, [FontStyle]::Bold)
$title.Location = New-Object Point(16, 8); $title.AutoSize = $true
$form.Controls.Add($title)
$sub = New-Object Label
$sub.Text = 'Turn an Android project into an APK. No Android Studio needed.'
$sub.ForeColor = [Color]::DimGray; $sub.Location = New-Object Point(18, 46); $sub.AutoSize = $true
$form.Controls.Add($sub)

function New-Row($y, $name) {
    $n = New-Object Label; $n.Text = $name; $n.Font = New-Object Font('Segoe UI', 9.5, [FontStyle]::Bold)
    $n.Location = New-Object Point(18, $y); $n.Size = New-Object Size(110, 22); $form.Controls.Add($n)
    $v = New-Object Label; $v.Text = '...'; $v.Location = New-Object Point(132, $y)
    $v.Size = New-Object Size(630, 22); $v.Anchor = 'Top,Left,Right'; $form.Controls.Add($v)
    return $v
}
$script:lJava = New-Row 80  'Java'
$script:lSdk  = New-Row 102 'Android tools'
$script:lPlat = New-Row 124 'SDK platform'
$script:lBt   = New-Row 146 'Build tools'
$script:lProj = New-Row 168 'Project'
$script:lDisk = New-Row 190 'Disk space'

$panel = New-Object FlowLayoutPanel
$panel.Location = New-Object Point(14, 222); $panel.Size = New-Object Size(752, 92); $panel.Anchor = 'Top,Left,Right'
$form.Controls.Add($panel)
function New-Btn($text) {
    $b = New-Object Button; $b.Text = $text; $b.Size = New-Object Size(176, 38); $b.Margin = New-Object Padding(4)
    $panel.Controls.Add($b); return $b
}
$btnInstall = New-Btn 'Install Android Environment'
$btnSelect  = New-Btn 'Select Android Project'
$btnBuild   = New-Btn 'Build APK'
$btnOpen    = New-Btn 'Open APK Output'
$btnCheck   = New-Btn 'Check Installation'
$btnPhone   = New-Btn 'Install on Phone'
$btnSdk     = New-Btn 'Change SDK Folder'
$btnBuild.Font = New-Object Font('Segoe UI', 9.5, [FontStyle]::Bold)
$script:buttons = @($btnInstall, $btnSelect, $btnBuild, $btnOpen, $btnCheck, $btnPhone, $btnSdk)

$script:opLabel = New-Object Label
$script:opLabel.Text = 'Ready.'; $script:opLabel.Location = New-Object Point(18, 324)
$script:opLabel.Size = New-Object Size(744, 22); $script:opLabel.Anchor = 'Top,Left,Right'
$form.Controls.Add($script:opLabel)

$script:bar = New-Object ProgressBar
$script:bar.Location = New-Object Point(18, 348); $script:bar.Size = New-Object Size(744, 18); $script:bar.Anchor = 'Top,Left,Right'
$form.Controls.Add($script:bar)

$script:log = New-Object TextBox
$script:log.Multiline = $true; $script:log.ReadOnly = $true; $script:log.ScrollBars = 'Both'; $script:log.WordWrap = $false
$script:log.Font = New-Object Font('Consolas', 9); $script:log.BackColor = [Color]::White
$script:log.Location = New-Object Point(18, 376); $script:log.Size = New-Object Size(744, 298); $script:log.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($script:log)

function Do-Action([scriptblock]$body) {
    if ($script:busy) { return }
    $script:busy = $true
    foreach ($b in $script:buttons) { $b.Enabled = $false }
    try { & $body }
    catch {
        $m = $_.Exception.Message
        Add-Log ''; Add-Log "ERROR: $m"; Set-Op 'Something went wrong - see the message.'
        Show-Msg $m 'Error'
    }
    finally {
        $script:bar.Style = 'Blocks'; $script:bar.Value = 0
        $script:busy = $false
        foreach ($b in $script:buttons) { $b.Enabled = $true }
        try { Refresh-Status } catch {}
    }
}

$btnInstall.Add_Click({ Do-Action { Install-Environment } })
$btnBuild.Add_Click({ Do-Action { Build-Apk } })
$btnPhone.Add_Click({ Do-Action { Install-ToPhone } })
$btnCheck.Add_Click({ Do-Action { Add-Log 'Checking installation ...'; Refresh-Status; Add-Log 'Status updated above.'; Set-Op 'Ready.' } })
$btnOpen.Add_Click({ if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }; Start-Process explorer.exe $OutDir })
$btnSelect.Add_Click({
    Do-Action {
        $dlg = New-Object FolderBrowserDialog
        $dlg.Description = 'Select your Android project folder (the one that contains the "app" folder)'
        $start = Join-Path $Root 'Projects'; if ($Cfg.project -and (Test-Path $Cfg.project)) { $start = $Cfg.project }
        $dlg.SelectedPath = $start
        if ($dlg.ShowDialog() -eq 'OK') {
            Test-ProjectFolder $dlg.SelectedPath
            $Cfg.project = $dlg.SelectedPath; Save-Cfg
            Add-Log "Project selected: $($Cfg.project)"
            Show-ProjectInfo (Get-ProjectInfo $Cfg.project)
        }
    }
})
$btnSdk.Add_Click({
    Do-Action {
        $dlg = New-Object FolderBrowserDialog
        $dlg.Description = 'Choose where the Android SDK should live (e.g. another drive). Existing files are not moved.'
        $dlg.SelectedPath = $Cfg.sdkDir
        if ($dlg.ShowDialog() -eq 'OK') { $Cfg.sdkDir = $dlg.SelectedPath; Save-Cfg; Add-Log "SDK folder set to: $($Cfg.sdkDir)" }
    }
})

$form.Add_Shown({
    Add-Log 'Welcome! Steps: 1) Install Android Environment  2) Select Android Project  3) Build APK'
    Add-Log 'Everything is installed inside this folder. Your Windows settings are not changed.'
    Do-Action { Refresh-Status }
})
[void]$form.ShowDialog()
