#requires -Version 5.1
# MAJDATA_UPDATER_VERSION: 1.2.3
<#
.SYNOPSIS
    MajdataPlay one-click updater for Windows.

.DESCRIPTION
    Checks the latest MajdataPlay release on GitHub (stable or nightly), downloads
    the Windows x64 package when a newer build is available, installs it over the
    existing game directory, and launches the game.

    The updater also checks its own version from
    https://github.com/TeamMajdata/Majplay-update-cli and replaces/restarts itself
    automatically when a newer script version is published (unless -SkipSelfUpdate).

    Network:
      * A configured system proxy (WinINET / PAC / HTTPS_PROXY) is always tried first.
      * If no working system proxy exists, GitHub mirrors such as gh-proxy.org are used.
      * A direct connection is kept as the last resort.

    StreamingAssets:
      * Existing files below MajdataPlay_Data\StreamingAssets are preserved by default.
      * New files are still installed. Use -OverwriteStreamingAssets to overwrite all.

    GUI:
      * By default the updater looks for a portrait 16:9 display (9:16).
      * On such a display it draws a full-screen GUI with a circle spanning the
        display width, bottom-aligned, and puts all output inside that circle.
      * Otherwise it falls back to the command line.
      * Use -NoGui to force the command line.

.PARAMETER Channel
    Stable selects the newest non-prerelease release.
    Nightly selects the rolling "nightly" release.
    When omitted, the saved setting is used. On a first run without game files,
    choose the channel in the boot menu; if skipped, Stable is used.

.PARAMETER InstallPath
    Game directory containing MajdataPlay.exe. Defaults to
    <script directory>\MajdataPlay. If the script itself is inside a folder
    named MajdataPlay, that folder is used directly.

.PARAMETER Proxy
    Explicit proxy, for example http://127.0.0.1:7890. Overrides proxy detection.

.PARAMETER NoProxy
    Never use a proxy (including system and environment proxy settings).

.PARAMETER Mirror
    GitHub mirror prefixes used when the system proxy is unavailable.
    Pass -Mirror @() -NoMirror to disable mirrors.

.PARAMETER NoMirror
    Do not use mirrors. Only the proxy (if any) and a direct connection are tried.

.PARAMETER TimeoutSec
    Timeout for metadata requests in seconds. Default: 20.

.PARAMETER OverwriteStreamingAssets
    Also overwrite files that already exist under MajdataPlay_Data\StreamingAssets.
    Without this switch, all such existing files are skipped.

.PARAMETER Force
    Download and reinstall even when the installed build appears up to date.

.PARAMETER CheckOnly
    Only check and report; never download, install, or launch the game.

.PARAMETER NoLaunch
    Do not start MajdataPlay after a successful check/update.

.PARAMETER NoGui
    Force command-line output even on a portrait 16:9 display.

.PARAMETER MonitorIndex
    Zero-based monitor index for the GUI. Default -1 = automatic. The selected
    monitor must still be portrait 16:9, otherwise the updater falls back to CLI.

.PARAMETER StopRunningGame
    Close a running MajdataPlay before installing. Without this switch the updater
    aborts because Windows would refuse to replace locked files.

.PARAMETER SelfUpdateUrl
    Custom URL for the updater script. Defaults to the raw main-branch script in
    TeamMajdata/Majplay-update-cli. Useful for forks and local testing.

.PARAMETER SkipSelfUpdate
    Do not check/replace the updater itself. This switch is also passed internally
    when the updater restarts after a successful self-update.

.PARAMETER SkipBootMenu
    Skip the boot menu.

.PARAMETER LogPath
    Log file path. Defaults to <InstallPath>\majdataplay-updater.log.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-MajdataPlay.ps1

.EXAMPLE
    .\Update-MajdataPlay.ps1 -Channel Nightly -OverwriteStreamingAssets

.EXAMPLE
    .\Update-MajdataPlay.ps1 -InstallPath 'D:\Games\MajdataPlay' -CheckOnly -NoGui
#>
[CmdletBinding()]
param(
    [ValidateSet('Stable', 'Nightly')]
    [string]$Channel = 'Stable',

    [string]$InstallPath,

    [string]$Proxy,

    [switch]$NoProxy,

    [string[]]$Mirror = @(
        'https://gh-proxy.org',
        'https://ghproxy.net',
        'https://gh-proxy.com',
        'https://github.moeyy.xyz'
    ),

    [switch]$NoMirror,

    [ValidateRange(5, 300)]
    [int]$TimeoutSec = 20,

    [switch]$OverwriteStreamingAssets,

    [switch]$Force,

    [switch]$CheckOnly,

    [switch]$NoLaunch,

    [switch]$NoGui,

    [int]$MonitorIndex = -1,

    [switch]$StopRunningGame,

    [string]$SelfUpdateUrl,

    [switch]$SkipSelfUpdate,

    [switch]$SkipBootMenu,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:UpdaterVersion = '1.2.3'
$script:UpdaterRepository = 'TeamMajdata/Majplay-update-cli'
$script:DefaultSelfUpdateUrl = 'https://github.com/TeamMajdata/Majplay-update-cli/raw/refs/heads/main/Update-MajdataPlay.ps1'
$script:Repository = 'TeamMajdata/MajdataPlay'
$script:ReleasePage = 'https://github.com/TeamMajdata/MajdataPlay/releases'
$script:AtomUrl = 'https://github.com/TeamMajdata/MajdataPlay/releases.atom'
$script:ApiUrl = 'https://api.github.com/repos/TeamMajdata/MajdataPlay/releases?per_page=30'
$script:WindowsAssetPattern = '^MajdataPlay-StandaloneWindows64.*\.zip$'
$script:UserAgent = "MajdataPlay-Updater/$($script:UpdaterVersion) (+https://github.com/TeamMajdata/MajdataPlay)"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:DefaultEngine = 'd3d12'
$script:GameLaunchArgs = '-force-d3d12'
$script:EngineOptions = [ordered]@{
    'd3d12'  = [pscustomobject]@{ Label = 'D3D12'; Description = '强制 Direct3D 12'; Args = '-force-d3d12' }
    'd3d11'  = [pscustomobject]@{ Label = 'D3D11'; Description = '强制 Direct3D 11'; Args = '-force-d3d11' }
    'vulkan' = [pscustomobject]@{ Label = 'Vulkan'; Description = '强制 Vulkan'; Args = '-force-vulkan' }
    'opengl' = [pscustomobject]@{ Label = 'OpenGL'; Description = '强制 OpenGL'; Args = '-force-glcore' }
    'test'   = [pscustomobject]@{ Label = '测试模式'; Description = '--test-mode'; Args = '--test-mode' }
}
$script:UseGui = $false
$script:GuiPowerShell = $null
$script:GuiRunspace = $null
$script:LogFile = $null
$script:LastPhase = ''
$script:LastMessage = ''
$script:WorkRoot = $null
$script:DownloadPath = $null

$script:UiState = [hashtable]::Synchronized(@{
    Phase           = '准备'
    Message         = '正在初始化更新器...'
    Detail          = ''
    Hint            = ''
    Progress        = 0.0
    DownloadPercent = -1.0
    DownloadBytes   = [long]0
    DownloadTotal   = [long]0
    Speed           = 0.0
    Finished        = $false
    Success         = $false
    Failed          = $false
    CancelRequested = $false
    CloseRequested  = $false
    GuiReady        = $false
    GuiClosed       = $false
    GuiError        = ''
    Channel         = $Channel
    Version         = ''
})

# ---------------------------------------------------------------------------
# GUI source (runs in its own STA runspace; communicates via $State)
# ---------------------------------------------------------------------------
$script:GuiSource = @'
param(
    [hashtable]$State,
    [int]$Left,
    [int]$Top,
    [int]$Width,
    [int]$Height
)

$ErrorActionPreference = 'Stop'
$form = $null
$timer = $null

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'MajdataPlay Updater'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Bounds = New-Object System.Drawing.Rectangle($Left, $Top, $Width, $Height)
    $form.BackColor = [System.Drawing.Color]::White
    $form.ForeColor = [System.Drawing.Color]::FromArgb(3, 105, 161)
    $form.TopMost = $true
    $form.ShowInTaskbar = $true
    $form.KeyPreview = $true
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false

    # Form.DoubleBuffered is protected; set it through reflection.
    try {
        $prop = $form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -ne $prop) { $prop.SetValue($form, $true, $null) }
    } catch { }

    $fontFamily = 'Segoe UI'
    try {
        $families = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
        foreach ($candidate in @('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI', 'Arial')) {
            if ($families -contains $candidate) { $fontFamily = $candidate; break }
        }
    } catch { }

    # Scale the whole layout from the display width. On 1080x1920 this keeps
    # the current look; 1440x2560 and 2160x3840 scale proportionally.
    $scale = $Width / 960.0
    if ($scale -lt 0.35) { $scale = 0.35 }
    if ($scale -gt 4.0) { $scale = 4.0 }

    function New-UiFont([double]$Pixels, [System.Drawing.FontStyle]$Style) {
        return New-Object System.Drawing.Font($fontFamily, [single]$Pixels, $Style, [System.Drawing.GraphicsUnit]::Pixel)
    }

    $fonts = @{
        Heading = New-UiFont (44 * $scale) ([System.Drawing.FontStyle]::Bold)
        Body    = New-UiFont (21 * $scale) ([System.Drawing.FontStyle]::Regular)
        Small   = New-UiFont (16 * $scale) ([System.Drawing.FontStyle]::Regular)
        Tiny    = New-UiFont (13 * $scale) ([System.Drawing.FontStyle]::Regular)
    }

    $script:paintState = @{
        Accent = [System.Drawing.Color]::FromArgb(14, 165, 233)
        AccentSoft = [System.Drawing.Color]::FromArgb(56, 189, 248)
        Text = [System.Drawing.Color]::FromArgb(3, 105, 161)
        Muted = [System.Drawing.Color]::FromArgb(2, 132, 199)
        Dim = [System.Drawing.Color]::FromArgb(2, 132, 199)
        Failed = [System.Drawing.Color]::FromArgb(7, 89, 133)
        Success = [System.Drawing.Color]::FromArgb(2, 132, 199)
    }

    $paintHandler = {
        param($sender, $eventArgs)

        $g = $eventArgs.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        try {

        $w = [double]$form.ClientSize.Width
        $h = [double]$form.ClientSize.Height
        if ($w -le 0 -or $h -le 0) { return }

        $g.Clear([System.Drawing.Color]::White)

        $cx = $w / 2.0
        # The circle spans the full display width: 1080 px at 1080x1920,
        # 2160 px at 4K, and proportionally at other 9:16 resolutions. It is
        # bottom-aligned so the full circle remains visible.
        $diameter = $w
        $r = $diameter / 2.0
        $cy = $h - $r
        if ($r -lt 10) { return }

        $isFailed = [bool]$State.Failed
        $isSuccess = [bool]$State.Success
        $accent = $script:paintState.Accent
        if ($isFailed) { $accent = $script:paintState.Failed }
        elseif ($isSuccess) { $accent = $script:paintState.Success }

        $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, $accent.R, $accent.G, $accent.B), [single]([Math]::Max(2.0, 2.4 * $scale)))
        $g.DrawEllipse($ringPen, [single]($cx - $r), [single]($cy - $r), [single]($r * 2), [single]($r * 2))
        $ringPen.Dispose()

        function Draw-CenteredText {
            param(
                [string]$Text,
                [System.Drawing.Font]$Font,
                [System.Drawing.Brush]$Brush,
                [double]$CenterY,
                [double]$MaxWidth,
                [int]$MaxLines = 8
            )

            if ([string]::IsNullOrWhiteSpace($Text)) { return 0.0 }
            $lines = New-Object System.Collections.Generic.List[string]
            $paragraphs = $Text -split "`r?`n"
            foreach ($paragraph in $paragraphs) {
                if ([string]::IsNullOrEmpty($paragraph)) {
                    $lines.Add('')
                    continue
                }
                $current = ''
                foreach ($ch in $paragraph.ToCharArray()) {
                    $candidate = $current + $ch
                    $measured = $g.MeasureString($candidate, $Font)
                    if ($measured.Width -gt $MaxWidth -and $current.Length -gt 0) {
                        $lines.Add($current.TrimEnd())
                        $current = [string]$ch
                    } else {
                        $current = $candidate
                    }
                }
                if ($current.Length -gt 0) { $lines.Add($current.TrimEnd()) }
            }
            if ($lines.Count -eq 0) { return 0.0 }
            if ($lines.Count -gt $MaxLines) {
                $lines = $lines.GetRange(0, $MaxLines)
                $lines[$MaxLines - 1] = $lines[$MaxLines - 1].TrimEnd() + '…'
            }

            $lineHeight = [double]$Font.GetHeight($g) * 1.14
            $totalHeight = $lineHeight * $lines.Count
            $y = $CenterY - $totalHeight / 2.0
            foreach ($line in $lines) {
                if ($line.Length -gt 0) {
                    $size = $g.MeasureString($line, $Font)
                    $g.DrawString($line, $Font, $Brush, [single]($cx - $size.Width / 2.0), [single]$y)
                }
                $y += $lineHeight
            }
            return $totalHeight
        }

        $phase = [string]$State.Phase
        if ([string]::IsNullOrWhiteSpace($phase)) { $phase = '更新器' }
        $message = [string]$State.Message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = '请稍候...' }
        $detail = [string]$State.Detail
        $hint = [string]$State.Hint
        if ([string]::IsNullOrWhiteSpace($hint)) {
            if ($State.Finished) { $hint = '按 Esc 退出' }
            else { $hint = '按 Esc 取消更新' }
        }

        $textBrush = New-Object System.Drawing.SolidBrush($script:paintState.Text)
        $mutedBrush = New-Object System.Drawing.SolidBrush($script:paintState.Muted)
        $dimBrush = New-Object System.Drawing.SolidBrush($script:paintState.Dim)
        $accentBrush = New-Object System.Drawing.SolidBrush($accent)

        $headingHeight = Draw-CenteredText -Text $phase -Font $fonts.Heading -Brush $textBrush -CenterY ($cy - $r * 0.50) -MaxWidth ($r * 1.45) -MaxLines 2
        $bodyCenter = $cy - $r * 0.10 + $headingHeight * 0.15
        $bodyHeight = Draw-CenteredText -Text $message -Font $fonts.Body -Brush $textBrush -CenterY $bodyCenter -MaxWidth ($r * 1.46) -MaxLines 5

        $progress = [double]$State.Progress
        $barY = $cy + $r * 0.28
        if ($progress -ge 0) {
            $barWidth = $r * 1.42
            $barHeight = [Math]::Max(6.0, $r * 0.045)
            $barX = $cx - $barWidth / 2.0
            $trackRect = New-Object System.Drawing.RectangleF([single]$barX, [single]$barY, [single]$barWidth, [single]$barHeight)
            $trackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(224, 242, 254))
            $g.FillRectangle($trackBrush, $trackRect)
            $trackBrush.Dispose()

            $ratio = [Math]::Max(0.0, [Math]::Min(1.0, $progress / 100.0))
            if ($ratio -gt 0) {
                $fillWidth = [Math]::Max($barHeight, $barWidth * $ratio)
                $fillRect = New-Object System.Drawing.RectangleF([single]$barX, [single]$barY, [single]$fillWidth, [single]$barHeight)
                $barBrush = New-Object System.Drawing.SolidBrush($accent)
                $g.FillRectangle($barBrush, $fillRect)
                $barBrush.Dispose()
            }

            $barPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 125, 211, 252), [single]1)
            $g.DrawRectangle($barPen, [single]$barX, [single]$barY, [single]$barWidth, [single]$barHeight)
            $barPen.Dispose()

            $percentText = if ($State.Failed) { '失败' } elseif ($State.Finished -and $State.Success) { '100%' } else { ('{0:N1}%' -f $progress) }
            $g.DrawString($percentText, $fonts.Small, $accentBrush, [single]$barX, [single]($barY + $barHeight + 8 * $scale))

            $speed = [double]$State.Speed
            $dlTotal = [long]$State.DownloadTotal
            $dlBytes = [long]$State.DownloadBytes
            if ($dlTotal -gt 0 -and -not $State.Finished) {
                $right = '{0} / {1}' -f (Format-GuiSize $dlBytes), (Format-GuiSize $dlTotal)
                if ($speed -gt 0) { $right += ('  {0}/s' -f (Format-GuiSize ([long]$speed))) }
                $rightSize = $g.MeasureString($right, $fonts.Small)
                $g.DrawString($right, $fonts.Small, $mutedBrush, [single]($barX + $barWidth - $rightSize.Width), [single]($barY + $barHeight + 8 * $scale))
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $detailY = if ($progress -ge 0) { $barY + $barHeight + 50 * $scale } else { $cy + $r * 0.20 }
            Draw-CenteredText -Text $detail -Font $fonts.Small -Brush $mutedBrush -CenterY $detailY -MaxWidth ($r * 1.46) -MaxLines 2 | Out-Null
        }

        $hintBrush = if ($State.Failed) { $accentBrush } else { $dimBrush }
        $g.DrawString($hint, $fonts.Tiny, $hintBrush, [single]($cx - $g.MeasureString($hint, $fonts.Tiny).Width / 2.0), [single]($cy + $r * 0.79))

        $textBrush.Dispose()
        $mutedBrush.Dispose()
        $dimBrush.Dispose()
        $accentBrush.Dispose()

        } catch {
            $State.GuiError = $_.Exception.ToString()
            try {
                $errorFont = New-Object System.Drawing.Font('Segoe UI', [single]14)
                $errorBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(3, 105, 161))
                $g.DrawString('GUI paint error:', $errorFont, $errorBrush, [single]20, [single]20)
                $g.DrawString($_.Exception.Message, $errorFont, $errorBrush, (New-Object System.Drawing.RectangleF(20, 44, [single]($w - 40), [single]($h - 64))))
                $errorFont.Dispose()
                $errorBrush.Dispose()
            } catch { }
        }
    }

    function Format-GuiSize([long]$Bytes) {
        if ($Bytes -ge 1073741824) { return ('{0:N2} GB' -f ($Bytes / 1073741824.0)) }
        if ($Bytes -ge 1048576) { return ('{0:N1} MB' -f ($Bytes / 1048576.0)) }
        if ($Bytes -ge 1024) { return ('{0:N0} KB' -f ($Bytes / 1024.0)) }
        return ('{0} B' -f $Bytes)
    }

    $form.Add_Paint($paintHandler)
    $form.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            if ($State.Finished) {
                $State.CloseRequested = $true
            } else {
                $State.CancelRequested = $true
                $State.Message = '正在取消，请稍候...'
                $State.Hint = '等待当前操作结束'
            }
            $eventArgs.Handled = $true
        }
    })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        $State.CloseRequested = $true
        if (-not $State.Finished) { $State.CancelRequested = $true }
        $State.GuiClosed = $true
    })
    $form.Add_Shown({
        $form.TopMost = $true
        $form.Activate()
        [void]$form.BringToFront()
        $State.GuiReady = $true
        $timer.Start()
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        if ($State.CloseRequested) {
            $timer.Stop()
            $form.Close()
            return
        }
        $form.Invalidate()
    })

    [System.Windows.Forms.Application]::Run($form)
} catch {
    $State.GuiError = $_.Exception.ToString()
} finally {
    $State.GuiClosed = $true
    if ($null -ne $timer) {
        try { $timer.Stop(); $timer.Dispose() } catch { }
    }
    if ($null -ne $form) {
        try { $form.Dispose() } catch { }
    }
}
'@

# ---------------------------------------------------------------------------
# BIOS-style boot menu (5 second timeout)
# ---------------------------------------------------------------------------
$script:BootMenuSource = @'
param(
    [hashtable]$Result,
    [object[]]$Items,
    [string]$CurrentEngine,
    [string]$CurrentChannel,
    [int]$TimeoutSec,
    [int]$Left,
    [int]$Top,
    [int]$Width,
    [int]$Height
)

$form = $null
$timer = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $scale = [Math]::Max(0.5, [Math]::Min(4.0, $Width / 1080.0))
    function S([double]$value) { return [int][Math]::Round($value * $scale) }
    function PX([double]$value) { return [single]($value * $scale) }

    $family = 'Consolas'
    try {
        $families = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
        foreach ($candidate in @('Microsoft YaHei UI', 'Microsoft YaHei', 'Consolas', 'Segoe UI')) {
            if ($families -contains $candidate) { $family = $candidate; break }
        }
    } catch { }

    $index = 0
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].Kind -eq 'engine' -and $Items[$i].Id -eq $CurrentEngine) {
            $index = $i
            break
        }
    }

    $state = @{
        Index       = $index
        LastSecond  = -1
        Cancelled   = $false
        Watch       = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'MajdataPlay Boot Menu'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Bounds = New-Object System.Drawing.Rectangle($Left, $Top, $Width, $Height)
    $form.BackColor = [System.Drawing.Color]::White
    $form.ForeColor = [System.Drawing.Color]::FromArgb(3, 105, 161)
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    # Form.DoubleBuffered is protected; set it through reflection to avoid
    # flicker when the full-screen circle is repainted by the countdown.
    try {
        $prop = $form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -ne $prop) { $prop.SetValue($form, $true, $null) }
    } catch { }

    $titleFont = New-Object System.Drawing.Font($family, (PX 34), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $rowFont = New-Object System.Drawing.Font($family, (PX 18), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $smallFont = New-Object System.Drawing.Font($family, (PX 11), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $countFont = New-Object System.Drawing.Font($family, (PX 14), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

    $form.Add_Paint({
        param($sender, $eventArgs)
        $g = $eventArgs.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        try {
            $w = [double]$form.ClientSize.Width
            $h = [double]$form.ClientSize.Height
            if ($w -le 0 -or $h -le 0) { return }

            $g.Clear([System.Drawing.Color]::White)

            $cx = $w / 2.0
            $diameter = $w
            $r = $diameter / 2.0
            $cy = $h - $r
            if ($r -lt 10) { return }

            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(225, 56, 189, 248), [single]([Math]::Max(2.0, 2.4 * $scale)))
            $g.DrawEllipse($ringPen, [single]($cx - $r), [single]($cy - $r), [single]($r * 2), [single]($r * 2))
            $ringPen.Dispose()

            $titleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(2, 132, 199))
            $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(3, 105, 161))
            $mutedBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(2, 132, 199))
            $selectedTextBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)

            $title = 'BOOT MENU'
            $titleSize = $g.MeasureString($title, $titleFont)
            $g.DrawString($title, $titleFont, $titleBrush, [single]($cx - $titleSize.Width / 2.0), [single]($cy - $r * 0.58))

            $rowHeight = [Math]::Max((S 26), $r * 0.105)
            $listWidth = $r * 1.52
            $listX = $cx - ($listWidth / 2.0)
            $startY = $cy - $r * 0.42
            $previousKind = $null

            for ($i = 0; $i -lt $Items.Count; $i++) {
                $item = $Items[$i]
                if ($null -ne $previousKind -and $previousKind -eq 'engine' -and $item.Kind -eq 'channel') {
                    $sepPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(170, 125, 211, 252), [single]1)
                    $sepY = $startY + ($i * $rowHeight) - ($rowHeight * 0.16)
                    $g.DrawLine($sepPen, [single]$listX, [single]$sepY, [single]($listX + $listWidth), [single]$sepY)
                    $sepPen.Dispose()
                }

                $rowY = $startY + ($i * $rowHeight)
                $isSelected = ($i -eq $state.Index)
                if ($isSelected) {
                    $selectedBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(14, 165, 233))
                    $g.FillRectangle($selectedBrush, [single]$listX, [single]$rowY, [single]$listWidth, [single]($rowHeight * 0.86))
                    $selectedBrush.Dispose()
                }

                $current = ''
                if ($item.Kind -eq 'engine' -and $item.Id -eq $CurrentEngine) { $current = ' *' }
                if ($item.Kind -eq 'channel' -and $item.Id -eq $CurrentChannel) { $current = ' *' }
                $marker = if ($isSelected) { '>' } else { ' ' }
                $text = '{0} {1}{2}' -f $marker, $item.Label, $current
                $brush = if ($isSelected) { $selectedTextBrush } else { $textBrush }
                $g.DrawString($text, $rowFont, $brush, [single]($listX + (S 14)), [single]($rowY + (S 4)))
                $previousKind = $item.Kind
            }

            if ($TimeoutSec -le 0) {
                $countdown = '请选择启动项'
            } elseif ($state.Cancelled) {
                $countdown = 'Enter / C 确认'
            } else {
                $remaining = [Math]::Max(0, $TimeoutSec - $state.Watch.Elapsed.TotalSeconds)
                $countdown = ('{0:N0} 秒后自动继续' -f [Math]::Ceiling($remaining))
            }
            $countSize = $g.MeasureString($countdown, $countFont)
            $g.DrawString($countdown, $countFont, $titleBrush, [single]($cx - $countSize.Width / 2.0), [single]($cy + $r * 0.56))

            $footer = '↑/↓ 选择   Enter/C 确认   Esc 跳过'
            $footerSize = $g.MeasureString($footer, $smallFont)
            $g.DrawString($footer, $smallFont, $mutedBrush, [single]($cx - $footerSize.Width / 2.0), [single]($cy + $r * 0.72))

            $titleBrush.Dispose()
            $textBrush.Dispose()
            $mutedBrush.Dispose()
            $selectedTextBrush.Dispose()
        } catch {
            $Result.Error = $_.Exception.ToString()
            try { $form.Close() } catch { }
        }
    })

    $form.Add_KeyDown({
        param($sender, $eventArgs)
        # Any keyboard action cancels the automatic countdown immediately.
        $state.Cancelled = $true
        if ($null -ne $timer) { $timer.Stop() }
        $handled = $true
        switch ($eventArgs.KeyCode) {
            ([System.Windows.Forms.Keys]::Up) { $state.Index-- }
            ([System.Windows.Forms.Keys]::W) { $state.Index-- }
            ([System.Windows.Forms.Keys]::Q) { $state.Index-- }
            ([System.Windows.Forms.Keys]::Down) { $state.Index++ }
            ([System.Windows.Forms.Keys]::S) { $state.Index++ }
            ([System.Windows.Forms.Keys]::Z) { $state.Index++ }
            ([System.Windows.Forms.Keys]::X) { $state.Index++ }
            ([System.Windows.Forms.Keys]::C) {
                $item = $Items[$state.Index]
                $Result.Kind = $item.Kind
                $Result.Id = $item.Id
                $Result.Action = 'Select'
                $form.Close()
            }
            ([System.Windows.Forms.Keys]::Enter) {
                $item = $Items[$state.Index]
                $Result.Kind = $item.Kind
                $Result.Id = $item.Id
                $Result.Action = 'Select'
                $form.Close()
            }
            ([System.Windows.Forms.Keys]::Escape) {
                $Result.Action = 'Timeout'
                $form.Close()
            }
            default { $handled = $false }
        }
        if ($state.Index -lt 0) { $state.Index = $Items.Count - 1 }
        if ($state.Index -ge $Items.Count) { $state.Index = 0 }
        if ($handled) { $eventArgs.SuppressKeyPress = $true }
        $form.Invalidate()
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        if ($TimeoutSec -le 0 -or $state.Cancelled) { return }
        if ($state.Watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
            $timer.Stop()
            $item = $Items[$state.Index]
            $Result.Kind = $item.Kind
            $Result.Id = $item.Id
            $Result.Action = 'Select'
            $Result.TimedOut = $true
            $form.Close()
            return
        }
        $second = [int][Math]::Ceiling([Math]::Max(0, $TimeoutSec - $state.Watch.Elapsed.TotalSeconds))
        if ($second -ne $state.LastSecond) {
            $state.LastSecond = $second
            $form.Invalidate()
        }
    })

    $form.Add_FormClosing({
        if ($Result.Action -eq '') { $Result.Action = 'Timeout' }
        $Result.Closed = $true
    })
    $form.Add_Shown({
        $form.Activate()
        $Result.Handle = [int64]$form.Handle
        $Result.Ready = $true
        if ($TimeoutSec -gt 0) { $timer.Start() }
    })

    [System.Windows.Forms.Application]::Run($form)
} catch {
    $Result.Error = $_.Exception.ToString()
} finally {
    $Result.Closed = $true
    if ($null -ne $timer) { try { $timer.Stop(); $timer.Dispose() } catch { } }
    if ($null -ne $form) { try { $form.Dispose() } catch { } }
}
'@

# ---------------------------------------------------------------------------
# Logging and small utilities
# ---------------------------------------------------------------------------
function Initialize-Logger {
    param([string]$Path)

    $script:LogFile = $null
    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $script:LogFile = [System.IO.Path]::GetFullPath($Path)
        [System.IO.File]::AppendAllText($script:LogFile, '', $script:Utf8NoBom)
    } catch {
        $script:LogFile = $null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom)
        } catch { }
    }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Set-UiStatus {
    param(
        [string]$Phase,
        [string]$Message,
        [double]$Progress = -1,
        [string]$Detail = '',
        [string]$Hint = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Phase)) { $script:UiState.Phase = $Phase }
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $script:UiState.Message = $Message }
    if ($Progress -ge 0) {
        $script:UiState.Progress = [Math]::Max(0.0, [Math]::Min(100.0, $Progress))
    }
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $script:UiState.Detail = $Detail }
    if (-not [string]::IsNullOrWhiteSpace($Hint)) { $script:UiState.Hint = $Hint }

    $changed = ($Phase -ne $script:LastPhase) -or ($Message -ne $script:LastMessage)
    if ($changed) {
        $script:LastPhase = $Phase
        $script:LastMessage = $Message
        Write-Log ("{0} | {1}" -f $Phase, $Message)
        if (-not $script:UseGui) {
            $color = 'Cyan'
            if ($Phase -match '失败|错误') { $color = 'Red' }
            elseif ($Phase -match '完成|最新') { $color = 'Green' }
            Write-Host ''
            Write-Host ("[{0}] {1}" -f $Phase, $Message) -ForegroundColor $color
        }
    }
}

function Set-UiDetail {
    param([string]$Detail)
    if ($script:UiState.Detail -ne $Detail) { $script:UiState.Detail = $Detail }
}

function Write-CliProgress {
    param(
        [string]$Label,
        [double]$Percent,
        [string]$Detail = ''
    )

    if ($script:UseGui) { return }
    $line = "`r  {0} {1,5:N1}%  {2}" -f $Label, $Percent, $Detail
    try {
        $width = [Math]::Max(20, [Console]::WindowWidth - 1)
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
    } catch { }
    Write-Host $line -NoNewline
}

function Test-Cancellation {
    if ($script:UiState.CancelRequested) {
        throw (New-Object System.OperationCanceledException('用户已取消更新。'))
    }
}

function Wait-WithTimeout {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutMs,
        [int]$PollMs = 100
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return [bool](& $Condition)
}

# ---------------------------------------------------------------------------
# Install path, state and local version
# ---------------------------------------------------------------------------
function Resolve-InstallPath {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            throw "安装路径是一个文件，而不是文件夹: $resolved"
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            New-Item -ItemType Directory -Path $resolved -Force | Out-Null
        }
        return $resolved
    }

    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $scriptRoot = [System.IO.Path]::GetFullPath($scriptRoot)

    # If the script itself lives in a folder named MajdataPlay, that folder is
    # already the game root; do not create a nested MajdataPlay\MajdataPlay.
    if ((Split-Path -Leaf $scriptRoot) -ieq 'MajdataPlay') {
        return $scriptRoot
    }

    # Support the common layout: C:\Games\MajdataPlay\Update-MajdataPlay.ps1
    $parent = Split-Path -Parent $scriptRoot
    if ($parent -and (Split-Path -Leaf $parent) -ieq 'MajdataPlay') {
        return [System.IO.Path]::GetFullPath($parent)
    }

    # Default layout: <script directory>\MajdataPlay is the game root.
    $defaultPath = Join-Path $scriptRoot 'MajdataPlay'
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        New-Item -ItemType Directory -Path $defaultPath -Force | Out-Null
    }

    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Get-StatePath {
    return (Join-Path $script:InstallPath '.majdataplay-updater.json')
}

function Read-InstallState {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Log "无法读取更新状态文件: $($_.Exception.Message)" WARN
        return $null
    }
}

function Save-InstallState {
    param([object]$Release)

    $state = [ordered]@{
        updaterVersion = $script:UpdaterVersion
        channel        = $Channel.ToLowerInvariant()
        engine         = (Get-SavedEngine)
        tag            = $Release.Tag
        version        = $Release.Version
        commit         = $Release.Commit
        releaseUpdated = if ($Release.Updated) { $Release.Updated.ToUniversalTime().ToString('o') } else { '' }
        asset          = $Release.AssetName
        sha256         = $Release.Sha256
        installedAt    = (Get-Date).ToUniversalTime().ToString('o')
        installPath    = $script:InstallPath
    }
    $json = $state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Get-StatePath), $json, $script:Utf8NoBom)
}

function Get-LocalVersion {
    $ggm = Join-Path $script:InstallPath 'MajdataPlay_Data\globalgamemanagers'
    if (Test-Path -LiteralPath $ggm -PathType Leaf) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($ggm)
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            $match = [regex]::Match($text, '(?<base>\d+\.\d+\.\d+)-(?<date>\d{8})-(?<commit>[0-9a-fA-F]{7,40})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                return [pscustomobject]@{
                    Raw       = $match.Value
                    Base      = [version]$match.Groups['base'].Value
                    BuildDate = $match.Groups['date'].Value
                    Commit    = $match.Groups['commit'].Value.ToLowerInvariant()
                    Source    = 'globalgamemanagers'
                }
            }
        } catch {
            Write-Log "读取 globalgamemanagers 失败: $($_.Exception.Message)" WARN
        }
    }

    $state = Read-InstallState
    if ($state -and -not [string]::IsNullOrWhiteSpace([string]$state.version)) {
        $match = [regex]::Match([string]$state.version, '(?<base>\d+\.\d+\.\d+)-(?<date>\d{8})-(?<commit>[0-9a-fA-F]{7,40})')
        if ($match.Success) {
            return [pscustomobject]@{
                Raw       = $match.Value
                Base      = [version]$match.Groups['base'].Value
                BuildDate = $match.Groups['date'].Value
                Commit    = $match.Groups['commit'].Value.ToLowerInvariant()
                Source    = 'state'
            }
        }
    }

    return $null
}

function Test-CoreFilesPresent {
    return ((Test-Path -LiteralPath (Join-Path $script:InstallPath 'MajdataPlay.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $script:InstallPath 'MajdataPlay_Data') -PathType Container))
}

function ConvertTo-ChannelName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    switch ($Value.Trim().ToLowerInvariant()) {
        'stable' { return 'Stable' }
        'nightly' { return 'Nightly' }
        default { return $null }
    }
}

function Save-StateFields {
    param([hashtable]$Fields)

    # Merge individual preference fields into the existing state file so install
    # metadata is never lost.
    $state = Read-InstallState
    $data = [ordered]@{}
    if ($null -ne $state) {
        foreach ($property in $state.PSObject.Properties) {
            $data[$property.Name] = $property.Value
        }
    }
    foreach ($key in $Fields.Keys) {
        $data[$key] = $Fields[$key]
    }
    [System.IO.File]::WriteAllText((Get-StatePath), ($data | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
}

function Save-ChannelToState {
    param([string]$SelectedChannel)

    $normalized = ConvertTo-ChannelName $SelectedChannel
    if ($null -eq $normalized) { throw ('无效的更新通道: {0}' -f $SelectedChannel) }
    Save-StateFields -Fields @{ channel = $normalized.ToLowerInvariant() }
}

function ConvertTo-EngineId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $script:DefaultEngine }
    $id = $Value.Trim().ToLowerInvariant()
    if ($script:EngineOptions.Contains($id)) { return $id }
    return $script:DefaultEngine
}

function Get-SavedEngine {
    $state = Read-InstallState
    if ($null -eq $state) { return $script:DefaultEngine }
    return (ConvertTo-EngineId ([string]$state.engine))
}

function Get-EngineArguments {
    param([string]$Engine)
    $id = ConvertTo-EngineId $Engine
    return [string]$script:EngineOptions[$id].Args
}

function Save-LaunchEngine {
    param([string]$Engine)
    $id = ConvertTo-EngineId $Engine
    Save-StateFields -Fields @{ engine = $id }
}

function Get-BootMenuItems {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($id in $script:EngineOptions.Keys) {
        $option = $script:EngineOptions[$id]
        $label = [string]$option.Label
        if ($id -eq $script:DefaultEngine) { $label += '（默认）' }
        $items.Add([pscustomobject]@{ Kind = 'engine'; Id = $id; Label = $label })
    }
    $items.Add([pscustomobject]@{ Kind = 'channel'; Id = 'Stable'; Label = '稳定版 Stable' })
    $items.Add([pscustomobject]@{ Kind = 'channel'; Id = 'Nightly'; Label = 'Nightly' })
    return $items.ToArray()
}

function Test-CommitEqual {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $a7 = $A.Substring(0, [Math]::Min(7, $A.Length)).ToLowerInvariant()
    $b7 = $B.Substring(0, [Math]::Min(7, $B.Length)).ToLowerInvariant()
    return $a7 -eq $b7
}

# ---------------------------------------------------------------------------
# Proxy and mirror routes
# ---------------------------------------------------------------------------
function ConvertTo-ProxyEndpoint {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $candidate = $Value.Trim().Trim('"')
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $candidate = 'http://' + $candidate
    }
    try {
        $uri = [System.Uri]$candidate
    } catch {
        return $null
    }
    if (-not $uri.Host) { return $null }

    $scheme = $uri.Scheme.ToLowerInvariant()
    if ($scheme -eq 'socks' -or $scheme -eq 'socks5') {
        # HttpClientHandler cannot use SOCKS directly. Most local clients expose a
        # mixed HTTP/SOCKS port, so retry the same endpoint as HTTP.
        $builder = New-Object System.UriBuilder($uri)
        $builder.Scheme = 'http'
        $uri = $builder.Uri
    } elseif ($scheme -ne 'http' -and $scheme -ne 'https') {
        return $null
    }

    $display = $uri.Host
    if ($uri.Port -gt 0) { $display = '{0}:{1}' -f $uri.Host, $uri.Port }
    $credential = $null
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        $parts = $uri.UserInfo.Split(':', 2)
        $user = [System.Uri]::UnescapeDataString($parts[0])
        $pass = if ($parts.Length -gt 1) { [System.Uri]::UnescapeDataString($parts[1]) } else { '' }
        $credential = New-Object System.Net.NetworkCredential($user, $pass)
    }

    return [pscustomobject]@{
        Uri        = $uri.AbsoluteUri.TrimEnd('/')
        Display    = $display
        Credential = $credential
    }
}

function Get-SystemProxyCandidates {
    $result = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    function Add-ProxyValue([string]$Value, [string]$Source) {
        $endpoint = ConvertTo-ProxyEndpoint $Value
        if ($null -eq $endpoint) { return }
        $key = $endpoint.Uri.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $endpoint | Add-Member -NotePropertyName Source -NotePropertyValue $Source -Force
        $result.Add($endpoint)
    }

    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        Add-ProxyValue $Proxy 'explicit'
        if ($result.Count -eq 0) { throw ('无法解析代理地址: {0}' -f $Proxy) }
        Write-Log '代理检测: 使用 -Proxy 参数。' DEBUG
        return $result.ToArray()
    }
    if ($NoProxy) { return @() }
    Write-Log '代理检测: 读取注册表。' DEBUG

    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($null -ne $reg) {
            if ([int]$reg.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$reg.ProxyServer)) {
                $raw = [string]$reg.ProxyServer
                $map = @{}
                foreach ($part in ($raw -split ';')) {
                    if ([string]::IsNullOrWhiteSpace($part)) { continue }
                    $pair = $part.Split('=', 2)
                    if ($pair.Length -eq 2) {
                        $map[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim()
                    } else {
                        $map['http'] = $pair[0].Trim()
                    }
                }
                $value = $null
                foreach ($key in @('https', 'http', 'socks', 'socks5')) {
                    if ($map.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($map[$key])) {
                        $value = $map[$key]
                        break
                    }
                }
                Add-ProxyValue $value 'WinINET'
                Write-Log '代理检测: 已读取 WinINET 代理设置。' DEBUG
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$reg.AutoConfigURL)) {
                try {
                    $webProxy = [System.Net.WebRequest]::GetSystemWebProxy()
                    $auto = $webProxy.GetProxy([System.Uri]'https://github.com/')
                    if ($null -ne $auto -and $auto.AbsoluteUri -ne 'https://github.com/') {
                        Add-ProxyValue $auto.AbsoluteUri 'PAC'
                    }
                } catch {
                    Write-Log "PAC 代理解析失败: $($_.Exception.Message)" WARN
                }
            }
        }
    } catch {
        Write-Log "读取 WinINET 代理设置失败: $($_.Exception.Message)" WARN
    }

    foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Add-ProxyValue $value ('环境变量 ' + $name)
        }
    }

    Write-Log ('代理检测: 最终 {0} 个。' -f $result.Count) DEBUG
    return $result.ToArray()
}

function Get-Routes {
    param([object[]]$Proxies)

    $routes = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Proxies) {
        $label = if ($p.Source -eq 'explicit') { '指定代理' } else { '系统代理' }
        $routes.Add([pscustomobject]@{
            Name       = ('{0} {1}' -f $label, $p.Display)
            Base       = ''
            Proxy      = $p.Uri
            Credential = $p.Credential
            Kind       = 'proxy'
        })
    }

    if (-not $NoMirror) {
        $seenMirror = @{}
        foreach ($m in $Mirror) {
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            $base = $m.Trim().TrimEnd('/')
            if ($base -notmatch '^https?://') { continue }
            $key = $base.ToLowerInvariant()
            if ($seenMirror.ContainsKey($key)) { continue }
            $seenMirror[$key] = $true
            $routes.Add([pscustomobject]@{
                Name       = ('镜像 ' + ([System.Uri]$base).Host)
                Base       = $base
                Proxy      = $null
                Credential = $null
                Kind       = 'mirror'
            })
        }
    }

    $routes.Add([pscustomobject]@{
        Name       = '直连'
        Base       = ''
        Proxy      = $null
        Credential = $null
        Kind       = 'direct'
    })

    return $routes.ToArray()
}

function Join-RouteUrl {
    param([object]$Route, [string]$Url)
    if ($Route.Base) { return ($Route.Base.TrimEnd('/') + '/' + $Url) }
    return $Url
}

function New-RouteHandler {
    param([object]$Route)

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    if (-not [string]::IsNullOrWhiteSpace([string]$Route.Proxy)) {
        $webProxy = New-Object System.Net.WebProxy([string]$Route.Proxy)
        if ($null -ne $Route.Credential) { $webProxy.Credentials = $Route.Credential }
        $handler.Proxy = $webProxy
        $handler.UseProxy = $true
    } else {
        $handler.UseProxy = $false
    }
    return $handler
}

function Invoke-WebText {
    param(
        [string]$Url,
        [object[]]$Routes,
        [string]$Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        [int]$Timeout = 20
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($route in $Routes) {
        $handler = $null
        $client = $null
        $response = $null
        $cts = $null
        try {
            $uri = Join-RouteUrl -Route $route -Url $Url
            Write-Log ("GET {0} [{1}]" -f $uri, $route.Name) DEBUG
            $cts = New-Object System.Threading.CancellationTokenSource([TimeSpan]::FromSeconds($Timeout))
            $handler = New-RouteHandler $route
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds($Timeout + 5)
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $script:UserAgent)
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', $Accept)

            $response = $client.GetAsync($uri, [System.Net.Http.HttpCompletionOption]::ResponseContentRead, $cts.Token).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw ('HTTP {0} {1}' -f [int]$response.StatusCode, $response.ReasonPhrase)
            }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            return [pscustomobject]@{ Text = $text; Route = $route; Url = $uri }
        } catch {
            $errors.Add(('{0}: {1}' -f $route.Name, $_.Exception.Message))
            Write-Log ("请求失败 [{0}] {1} : {2}" -f $route.Name, $Url, $_.Exception.Message) WARN
        } finally {
            if ($null -ne $response) { try { $response.Dispose() } catch { } }
            if ($null -ne $client) { try { $client.Dispose() } catch { } }
            if ($null -ne $handler) { try { $handler.Dispose() } catch { } }
            if ($null -ne $cts) { try { $cts.Dispose() } catch { } }
        }
    }

    throw ("无法访问 {0}。`n{1}" -f $Url, ($errors -join "`n"))
}

# ---------------------------------------------------------------------------
# Updater self-update
# ---------------------------------------------------------------------------
function Invoke-SelfUpdateText {
    param(
        [string]$Url,
        [object[]]$Routes,
        [int]$Timeout = 10
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($route in $Routes) {
        $uri = Join-RouteUrl -Route $route -Url $Url
        Write-Log ("GET {0} [{1}]" -f $uri, $route.Name) DEBUG
        try {
            $request = @{
                Uri                = $uri
                UseBasicParsing    = $true
                TimeoutSec         = $Timeout
                MaximumRedirection = 5
                Headers            = @{ 'User-Agent' = $script:UserAgent }
            }

            $oldDefaultProxy = $null
            $restoreDefaultProxy = $false
            if (-not [string]::IsNullOrWhiteSpace([string]$route.Proxy)) {
                $request.Proxy = [string]$route.Proxy
            } elseif ($PSVersionTable.PSVersion.Major -ge 6) {
                $request.NoProxy = $true
            } else {
                # Windows PowerShell 5.1 has no -NoProxy switch. Temporarily
                # clear the default proxy so mirror/direct routes are truly direct.
                $oldDefaultProxy = [System.Net.WebRequest]::DefaultWebProxy
                [System.Net.WebRequest]::DefaultWebProxy = $null
                $restoreDefaultProxy = $true
            }

            try {
                $response = Invoke-WebRequest @request
            } finally {
                if ($restoreDefaultProxy) {
                    [System.Net.WebRequest]::DefaultWebProxy = $oldDefaultProxy
                }
            }

            $content = $response.Content
            if ($content -is [byte[]]) {
                $content = [System.Text.Encoding]::UTF8.GetString($content)
            }
            return [pscustomobject]@{ Text = [string]$content; Route = $route; Url = $uri }
        } catch {
            $errors.Add(('{0}: {1}' -f $route.Name, $_.Exception.Message))
            Write-Log ("请求失败 [{0}] {1} : {2}" -f $route.Name, $Url, $_.Exception.Message) WARN
        }
    }

    throw ("无法访问 {0}。`n{1}" -f $Url, ($errors -join "`n"))
}

function Get-ScriptVersionFromText {
    param([string]$Text)

    $match = [regex]::Match($Text, '(?m)^\s*#\s*MAJDATA_UPDATER_VERSION:\s*(?<v>\d+(?:\.\d+){1,3})\s*$')
    if (-not $match.Success) {
        $match = [regex]::Match($Text, '\$script:UpdaterVersion\s*=\s*''(?<v>\d+(?:\.\d+){1,3})''')
    }
    if (-not $match.Success) { return $null }
    try { return [version]$match.Groups['v'].Value } catch { return $null }
}

function Quote-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\+)$', '$1$1'
    $escaped = $escaped -replace '(\\*)"', '$1$1\"'
    return '"' + $escaped + '"'
}

function Start-UpdaterRestart {
    param([object]$BoundParameters)

    try {
        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw '无法确定当前更新器脚本路径。'
        }

        $exe = $null
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $exe = Join-Path $PSHOME 'powershell.exe'
        } else {
            $exe = Join-Path $PSHOME 'pwsh.exe'
        }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            $exe = (Get-Process -Id $PID).Path
        }

        $arguments = New-Object System.Collections.Generic.List[string]
        foreach ($arg in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-ProcessArgument $scriptPath))) {
            $arguments.Add([string]$arg)
        }

        if ($null -ne $BoundParameters) {
            foreach ($key in @($BoundParameters.Keys)) {
                if ($key -eq 'SkipSelfUpdate') { continue }
                $value = $BoundParameters[$key]
                if ($null -eq $value) { continue }
                if ($value -is [System.Management.Automation.SwitchParameter]) {
                    if ($value.IsPresent) { $arguments.Add(('-' + $key)) }
                } elseif ($value -is [System.Array]) {
                    $parts = @($value | ForEach-Object { Quote-ProcessArgument ([string]$_) })
                    if ($parts.Count -gt 0) {
                        $arguments.Add(('-' + $key))
                        $arguments.Add(($parts -join ','))
                    }
                } else {
                    $arguments.Add(('-' + $key))
                    $arguments.Add((Quote-ProcessArgument ([string]$value)))
                }
            }
        }
        $arguments.Add('-SkipSelfUpdate')

        $argumentLine = $arguments -join ' '
        Write-Log '更新器已更新，正在重启以应用新版本。'
        Start-Process -FilePath $exe -ArgumentList $argumentLine -WorkingDirectory (Get-Location).Path | Out-Null
        return $true
    } catch {
        Write-Log ('重启更新器失败: ' + $_.Exception.Message) WARN
        return $false
    }
}

function Invoke-UpdaterSelfUpdate {
    param(
        [object[]]$Routes,
        [object]$BoundParameters,
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { $Url = $script:DefaultSelfUpdateUrl }
    $localVersion = [version]$script:UpdaterVersion
    $result = [pscustomobject]@{
        Updated = $false
        Version = $null
        Message = ''
        Restarted = $false
    }

    Write-Log ('检查更新器自身: {0}' -f $Url) INFO
    $selfTimeout = [Math]::Min($TimeoutSec, 10)
    $response = Invoke-SelfUpdateText -Url $Url -Routes $Routes -Timeout $selfTimeout
    $remoteText = $response.Text.TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($remoteText) -or $remoteText.Length -lt 5000) {
        throw '远程更新器内容为空或长度异常。'
    }
    if ($remoteText -notmatch '#requires\s+-Version\s+5\.1') {
        throw '远程更新器缺少 #requires -Version 5.1，已拒绝替换。'
    }

    $remoteVersion = Get-ScriptVersionFromText -Text $remoteText
    if ($null -eq $remoteVersion) { throw '无法从远程脚本读取更新器版本。' }
    $result.Version = $remoteVersion
    if ($remoteVersion -le $localVersion) {
        $result.Message = ('更新器已是最新版本 {0}。' -f $localVersion)
        Write-Log $result.Message
        return $result
    }

    $tempDir = $script:WorkRoot
    if ([string]::IsNullOrWhiteSpace([string]$tempDir)) {
        $tempDir = Split-Path -Parent $PSCommandPath
    }
    $tempPath = Join-Path $tempDir ('MajdataPlay-Updater-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        [System.IO.File]::WriteAllText($tempPath, $remoteText, $script:Utf8Bom)
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($tempPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count -gt 0) {
            throw ('远程更新器语法无效: ' + $parseErrors[0].Message)
        }

        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw '无法确定当前更新器脚本路径。'
        }

        $backupPath = $scriptPath + '.bak'
        $oldPath = $scriptPath + '.old'
        Copy-Item -LiteralPath $scriptPath -Destination $backupPath -Force
        try {
            Copy-Item -LiteralPath $tempPath -Destination $scriptPath -Force
        } catch {
            # A running script is normally replaceable, but some AV/locking
            # products only allow a rename. Keep a rollback path either way.
            Move-Item -LiteralPath $scriptPath -Destination $oldPath -Force
            try {
                Move-Item -LiteralPath $tempPath -Destination $scriptPath -Force
            } catch {
                Move-Item -LiteralPath $oldPath -Destination $scriptPath -Force -ErrorAction SilentlyContinue
                throw
            }
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
        }

        $result.Updated = $true
        $result.Message = ('更新器已从 {0} 更新到 {1}。' -f $localVersion, $remoteVersion)
        Write-Log $result.Message
        return $result
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Release metadata
# ---------------------------------------------------------------------------
function Get-AtomEntries {
    param([string]$XmlText)

    [xml]$xml = $XmlText
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('a', 'http://www.w3.org/2005/Atom')
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($node in $xml.SelectNodes('//a:entry', $ns)) {
        $linkNode = $node.SelectSingleNode('a:link', $ns)
        if ($null -eq $linkNode) { continue }
        $href = [string]$linkNode.GetAttribute('href')
        $tag = ''
        if ($href -match '/releases/tag/(?<tag>[^/?#]+)') {
            $tag = [System.Uri]::UnescapeDataString($Matches['tag'])
        }
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }

        $updated = [datetime]::MinValue
        $updatedNode = $node.SelectSingleNode('a:updated', $ns)
        if ($null -ne $updatedNode) {
            try { $updated = [datetime]::Parse($updatedNode.InnerText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) } catch { }
        }

        $title = ''
        $titleNode = $node.SelectSingleNode('a:title', $ns)
        if ($null -ne $titleNode) { $title = $titleNode.InnerText }

        $contentText = ''
        $contentNode = $node.SelectSingleNode('a:content', $ns)
        if ($null -ne $contentNode) { $contentText = $contentNode.InnerText }

        $commit = ''
        $commitMatch = [regex]::Match($contentText, '(?im)Commit:\s*([0-9a-f]{7,40})')
        if (-not $commitMatch.Success) {
            $commitMatch = [regex]::Match($contentText, 'commit/([0-9a-f]{7,40})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        if ($commitMatch.Success) { $commit = $commitMatch.Groups[1].Value.ToLowerInvariant() }

        $buildAt = ''
        $buildMatch = [regex]::Match($contentText, '(?im)Build at:\s*([^\r\n<]+)')
        if ($buildMatch.Success) { $buildAt = $buildMatch.Groups[1].Value.Trim() }

        $items.Add([pscustomobject]@{
            Tag      = $tag
            Title    = $title
            Updated  = $updated
            Content  = $contentText
            Commit   = $commit
            BuildAt  = $buildAt
            HtmlUrl  = $href
            Source   = 'atom'
        })
    }

    return $items.ToArray()
}

function Get-StableVersionFromTag {
    param([string]$Tag)
    if ($Tag -match '^v?(?<ver>\d+(?:\.\d+){1,3})$') {
        try { return [version]$Matches['ver'] } catch { return $null }
    }
    return $null
}

function Get-ReleaseAssetFromPage {
    param([string]$PageText, [string]$Tag, [string]$VersionHint)

    $matches = [regex]::Matches($PageText, '(?is)<a[^>]+href="(?<href>[^"]+/releases/download/[^"]+)"[^>]*>(?<name>.*?)</a>')
    foreach ($match in $matches) {
        $name = [System.Net.WebUtility]::HtmlDecode([regex]::Replace($match.Groups['name'].Value, '<[^>]+>', '').Trim())
        $href = [System.Net.WebUtility]::HtmlDecode($match.Groups['href'].Value)
        if ($name -notmatch $script:WindowsAssetPattern) { continue }

        $tailLength = [Math]::Min(6000, $PageText.Length - $match.Index)
        $tail = $PageText.Substring($match.Index, $tailLength)
        $sha = ''
        $shaMatch = [regex]::Match($tail, 'sha256:([0-9a-fA-F]{64})')
        if ($shaMatch.Success) { $sha = $shaMatch.Groups[1].Value.ToLowerInvariant() }

        $size = [long]0
        $sizeMatch = [regex]::Match($tail, '(?m)(\d+(?:\.\d+)?)\s*(B|KB|MB|GB)\b')
        if ($sizeMatch.Success) {
            $value = [double]$sizeMatch.Groups[1].Value
            switch ($sizeMatch.Groups[2].Value.ToUpperInvariant()) {
                'KB' { $size = [long]($value * 1KB) }
                'MB' { $size = [long]($value * 1MB) }
                'GB' { $size = [long]($value * 1GB) }
                default { $size = [long]$value }
            }
        }

        if ($href -match '^https?://') {
            $url = $href
        } else {
            $url = 'https://github.com' + $href
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = [System.IO.Path]::GetFileName(([System.Uri]$url).AbsolutePath)
        }

        return [pscustomobject]@{
            AssetName  = $name
            AssetUrl   = $url
            Sha256     = $sha
            Size       = [long]0
            ApproxSize = $size
        }
    }

    # Asset list unavailable: construct the conventional URL. The package name
    # has been stable for a long time, and the download will still be validated
    # as a ZIP before installation.
    $fallbackName = 'MajdataPlay-StandaloneWindows64-nightly.zip'
    return [pscustomobject]@{
        AssetName  = $fallbackName
        AssetUrl   = ('https://github.com/{0}/releases/download/{1}/{2}' -f $script:Repository, [System.Uri]::EscapeDataString($Tag), $fallbackName)
        Sha256     = ''
        Size       = [long]0
        ApproxSize = [long]0
    }
}

function Get-ReleaseFromAtom {
    param([object[]]$Routes, [string]$RequestedChannel)

    $response = Invoke-WebText -Url $script:AtomUrl -Routes $Routes -Accept 'application/atom+xml,application/xml;q=0.9,*/*;q=0.8' -Timeout $TimeoutSec
    $entries = @(Get-AtomEntries -XmlText $response.Text)
    if ($entries.Count -eq 0) { throw 'GitHub Atom feed 中没有找到发布记录。' }

    if ($RequestedChannel -eq 'Nightly') {
        $entry = $entries | Where-Object { $_.Tag -eq 'nightly' } | Select-Object -First 1
        if ($null -eq $entry) { throw '没有找到 nightly 发布。' }
        $version = 'nightly'
        if ($entry.Commit) { $version = 'nightly-' + $entry.Commit.Substring(0, [Math]::Min(7, $entry.Commit.Length)) }
        return [pscustomobject]@{
            Channel     = 'Nightly'
            Tag         = $entry.Tag
            Title       = $entry.Title
            Version     = $version
            BaseVersion = $null
            Commit      = $entry.Commit
            BuildAt     = $entry.BuildAt
            Updated     = $entry.Updated
            Source      = 'atom'
        }
    }

    $stable = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $v = Get-StableVersionFromTag -Tag $entry.Tag
        if ($null -ne $v) {
            $entry | Add-Member -NotePropertyName ParsedVersion -NotePropertyValue $v -Force
            $stable.Add($entry)
        }
    }
    if ($stable.Count -eq 0) { throw '没有找到稳定的正式版本。' }
    $entry = $stable | Sort-Object -Property ParsedVersion -Descending | Select-Object -First 1

    $version = $entry.Tag
    $commit = ''
    if ($entry.Title -match '^v?(?<ver>\d+\.\d+\.\d+-\d{8}-(?<commit>[0-9a-fA-F]{7,40}))$') {
        $version = $Matches['ver']
        $commit = $Matches['commit'].ToLowerInvariant()
    } elseif ($entry.Title -match '^v?(?<ver>\d+\.\d+\.\d+)$') {
        $version = $Matches['ver']
    }
    if (-not $commit -and $version -match '-(\d{8})-([0-9a-fA-F]{7,40})$') {
        $commit = $Matches[2].ToLowerInvariant()
    }

    return [pscustomobject]@{
        Channel     = 'Stable'
        Tag         = $entry.Tag
        Title       = $entry.Title
        Version     = $version
        BaseVersion = (Get-StableVersionFromTag -Tag $entry.Tag)
        Commit      = $commit
        BuildAt     = $entry.BuildAt
        Updated     = $entry.Updated
        Source      = 'atom'
    }
}

function Get-ReleaseFromApi {
    param([object[]]$Routes, [string]$RequestedChannel)

    $response = Invoke-WebText -Url $script:ApiUrl -Routes $Routes -Accept 'application/vnd.github+json,application/json;q=0.9,*/*;q=0.8' -Timeout $TimeoutSec
    $data = $response.Text | ConvertFrom-Json
    $items = @($data)
    if ($items.Count -eq 0) { throw 'GitHub API 没有返回发布记录。' }

    if ($RequestedChannel -eq 'Nightly') {
        $rel = $items | Where-Object { $_.tag_name -eq 'nightly' } | Select-Object -First 1
        if ($null -eq $rel) { throw '没有找到 nightly 发布。' }
        $commit = ''
        if ([string]$rel.body -match '(?im)Commit:\s*([0-9a-f]{7,40})') { $commit = $Matches[1].ToLowerInvariant() }
        $buildAt = ''
        if ([string]$rel.body -match '(?im)Build at:\s*([^\r\n]+)') { $buildAt = $Matches[1].Trim() }
        $version = 'nightly'
        if ($commit) { $version = 'nightly-' + $commit.Substring(0, [Math]::Min(7, $commit.Length)) }
        return [pscustomobject]@{
            Channel     = 'Nightly'
            Tag         = [string]$rel.tag_name
            Title       = [string]$rel.name
            Version     = $version
            BaseVersion = $null
            Commit      = $commit
            BuildAt     = $buildAt
            Updated     = [datetime]$rel.updated_at
            Source      = 'api'
        }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $items) {
        if ([bool]$rel.draft -or [bool]$rel.prerelease) { continue }
        $v = Get-StableVersionFromTag -Tag ([string]$rel.tag_name)
        if ($null -ne $v) {
            $rel | Add-Member -NotePropertyName ParsedVersion -NotePropertyValue $v -Force
            $candidates.Add($rel)
        }
    }
    if ($candidates.Count -eq 0) { throw '没有找到稳定的正式版本。' }
    $rel = $candidates | Sort-Object -Property ParsedVersion -Descending | Select-Object -First 1

    $version = [string]$rel.tag_name
    $commit = ''
    if ([string]$rel.name -match '^v?(?<ver>\d+\.\d+\.\d+-\d{8}-(?<commit>[0-9a-fA-F]{7,40}))$') {
        $version = $Matches['ver']
        $commit = $Matches['commit'].ToLowerInvariant()
    }
    if (-not $commit -and $version -match '-(\d{8})-([0-9a-fA-F]{7,40})$') {
        $commit = $Matches[2].ToLowerInvariant()
    }

    return [pscustomobject]@{
        Channel     = 'Stable'
        Tag         = [string]$rel.tag_name
        Title       = [string]$rel.name
        Version     = $version
        BaseVersion = (Get-StableVersionFromTag -Tag ([string]$rel.tag_name))
        Commit      = $commit
        BuildAt     = ''
        Updated     = [datetime]$rel.updated_at
        Source      = 'api'
    }
}

function Get-ReleaseInfo {
    param([object[]]$Routes, [string]$RequestedChannel)

    $release = $null
    $errors = New-Object System.Collections.Generic.List[string]

    try {
        $release = Get-ReleaseFromAtom -Routes $Routes -RequestedChannel $RequestedChannel
        Write-Log '已从 GitHub Atom feed 获取版本信息。'
    } catch {
        $errors.Add(('Atom: ' + $_.Exception.Message))
        Write-Log ('Atom 获取失败: ' + $_.Exception.Message) WARN
    }

    if ($null -eq $release) {
        try {
            $release = Get-ReleaseFromApi -Routes $Routes -RequestedChannel $RequestedChannel
            Write-Log '已从 GitHub API 获取版本信息。'
        } catch {
            $errors.Add(('API: ' + $_.Exception.Message))
            Write-Log ('API 获取失败: ' + $_.Exception.Message) WARN
        }
    }
    if ($null -eq $release) {
        throw ("无法获取 MajdataPlay 版本信息。请检查代理或镜像设置。`n" + ($errors -join "`n"))
    }

    $expandedUrl = ('https://github.com/{0}/releases/expanded_assets/{1}' -f $script:Repository, [System.Uri]::EscapeDataString($release.Tag))
    try {
        $page = Invoke-WebText -Url $expandedUrl -Routes $Routes -Accept 'text/html,*/*;q=0.8' -Timeout $TimeoutSec
        $asset = Get-ReleaseAssetFromPage -PageText $page.Text -Tag $release.Tag -VersionHint $release.Version
        $release | Add-Member -NotePropertyName AssetName -NotePropertyValue $asset.AssetName -Force
        $release | Add-Member -NotePropertyName AssetUrl -NotePropertyValue $asset.AssetUrl -Force
        $release | Add-Member -NotePropertyName Sha256 -NotePropertyValue $asset.Sha256 -Force
        $release | Add-Member -NotePropertyName Size -NotePropertyValue $asset.Size -Force
        $release | Add-Member -NotePropertyName ApproxSize -NotePropertyValue $asset.ApproxSize -Force
    } catch {
        Write-Log ('获取资源列表失败: ' + $_.Exception.Message) WARN
        $asset = $null
        try {
            $apiTagUrl = ('https://api.github.com/repos/{0}/releases/tags/{1}' -f $script:Repository, [System.Uri]::EscapeDataString($release.Tag))
            $apiDetail = (Invoke-WebText -Url $apiTagUrl -Routes $Routes -Accept 'application/vnd.github+json' -Timeout $TimeoutSec).Text | ConvertFrom-Json
            $apiAsset = @($apiDetail.assets) | Where-Object { $_.name -match $script:WindowsAssetPattern } | Select-Object -First 1
            if ($null -ne $apiAsset) {
                $sha = ''
                if ([string]$apiAsset.digest -match '^sha256:(?<sha>[0-9a-fA-F]{64})$') { $sha = $Matches['sha'].ToLowerInvariant() }
                $asset = [pscustomobject]@{
                    AssetName  = [string]$apiAsset.name
                    AssetUrl   = [string]$apiAsset.browser_download_url
                    Sha256     = $sha
                    Size       = [long]$apiAsset.size
                    ApproxSize = [long]$apiAsset.size
                }
                Write-Log '已通过 GitHub API 补充更新包校验信息。'
            }
        } catch {
            Write-Log ('API 资源信息获取失败: ' + $_.Exception.Message) DEBUG
        }
        if ($null -eq $asset) {
            $asset = Get-ReleaseAssetFromPage -PageText '' -Tag $release.Tag -VersionHint $release.Version
        }
        $release | Add-Member -NotePropertyName AssetName -NotePropertyValue $asset.AssetName -Force
        $release | Add-Member -NotePropertyName AssetUrl -NotePropertyValue $asset.AssetUrl -Force
        $release | Add-Member -NotePropertyName Sha256 -NotePropertyValue $asset.Sha256 -Force
        $release | Add-Member -NotePropertyName Size -NotePropertyValue $asset.Size -Force
        $release | Add-Member -NotePropertyName ApproxSize -NotePropertyValue $asset.ApproxSize -Force
    }

    # API fallback did not necessarily have asset information. If SHA/size are
    # missing, try the API asset metadata as a best-effort (it may be rate
    # limited, so failure is harmless).
    if ($release.Source -eq 'api') {
        try {
            $apiAssets = Invoke-WebText -Url ('https://api.github.com/repos/{0}/releases/tags/{1}' -f $script:Repository, [System.Uri]::EscapeDataString($release.Tag)) -Routes $Routes -Accept 'application/vnd.github+json' -Timeout $TimeoutSec
            $detail = $apiAssets.Text | ConvertFrom-Json
            $apiAsset = @($detail.assets) | Where-Object { $_.name -match $script:WindowsAssetPattern } | Select-Object -First 1
            if ($null -ne $apiAsset) {
                $release.AssetName = [string]$apiAsset.name
                $release.AssetUrl = [string]$apiAsset.browser_download_url
                if ([string]$apiAsset.digest -match '^sha256:(?<sha>[0-9a-fA-F]{64})$') { $release.Sha256 = $Matches['sha'].ToLowerInvariant() }
                if ($apiAsset.size) {
                    $release.Size = [long]$apiAsset.size
                    $release.ApproxSize = [long]$apiAsset.size
                }
            }
        } catch {
            Write-Log ('补充资源元数据失败: ' + $_.Exception.Message) DEBUG
        }
    }

    if (-not $release.PSObject.Properties['AssetName'] -or [string]::IsNullOrWhiteSpace([string]$release.AssetName)) {
        throw '没有找到 Windows x64 更新包。'
    }
    return $release
}

# ---------------------------------------------------------------------------
# Update decision
# ---------------------------------------------------------------------------
function Test-ReleaseMatchesState {
    param([object]$Release, [object]$State)
    if ($null -eq $State) { return $false }
    if ([string]$State.channel -ne $Channel.ToLowerInvariant()) { return $false }
    if (-not (Test-CoreFilesPresent)) { return $false }
    if ($Release.Commit -and $State.commit -and (Test-CommitEqual $Release.Commit ([string]$State.commit))) { return $true }
    if ([string]$State.tag -eq $Release.Tag -and [string]$State.asset -eq $Release.AssetName -and -not $Release.Commit) { return $true }
    return $false
}

function Get-UpdateDecision {
    param([object]$Release, [object]$LocalVersion, [object]$State)

    if ($Force) {
        return [pscustomobject]@{ Update = $true; Reason = '指定了 -Force，强制重新安装。' }
    }
    if ($null -eq $LocalVersion) {
        if (Test-ReleaseMatchesState -Release $Release -State $State) {
            return [pscustomobject]@{ Update = $false; Reason = '安装记录与远程版本一致。' }
        }
        return [pscustomobject]@{ Update = $true; Reason = '未检测到本地版本，需要首次安装。' }
    }
    if ($Channel -eq 'Stable') {
        if ($null -eq $Release.BaseVersion) {
            return [pscustomobject]@{ Update = $true; Reason = '无法比较稳定版版本号。' }
        }
        if ($Release.BaseVersion -gt $LocalVersion.Base) {
            return [pscustomobject]@{ Update = $true; Reason = ('发现新版本 {0}（本地 {1}）。' -f $Release.BaseVersion, $LocalVersion.Base) }
        }
        if ($Release.BaseVersion -lt $LocalVersion.Base) {
            return [pscustomobject]@{ Update = $false; Reason = ('本地版本 {0} 高于稳定版 {1}，可能正在使用 nightly；如需切换通道请加 -Force。' -f $LocalVersion.Base, $Release.BaseVersion) }
        }
        if ($Release.Commit -and $LocalVersion.Commit -and -not (Test-CommitEqual $Release.Commit $LocalVersion.Commit)) {
            return [pscustomobject]@{ Update = $true; Reason = '同一版本号有新的重新构建。' }
        }
        return [pscustomobject]@{ Update = $false; Reason = ('已是最新稳定版 {0}。' -f $Release.BaseVersion) }
    }

    if ($Release.Commit -and $LocalVersion.Commit -and (Test-CommitEqual $Release.Commit $LocalVersion.Commit)) {
        return [pscustomobject]@{ Update = $false; Reason = ('nightly 已是最新构建（{0}）。' -f $Release.Commit.Substring(0, 7)) }
    }
    return [pscustomobject]@{ Update = $true; Reason = ('发现新的 nightly 构建 {0}。' -f $Release.Version) }
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
function Test-FileHash {
    param([string]$Path, [string]$ExpectedSha256)

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return $true }
    Set-UiStatus -Phase '校验下载' -Message '正在校验更新包完整性...' -Progress 72
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($hash -eq $ExpectedSha256)
}

function Test-ZipArchive {
    param([string]$Path)
    $zip = $null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        return ($zip.Entries.Count -gt 0)
    } catch {
        return $false
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Invoke-DownloadRoute {
    param(
        [object]$Route,
        [string]$Url,
        [string]$PartPath,
        [long]$ExpectedTotal,
        [double]$ProgressStart,
        [double]$ProgressEnd
    )

    $handler = $null
    $client = $null
    $response = $null
    $request = $null
    $stream = $null
    $fileStream = $null
    $cts = $null

    try {
        $existing = [long]0
        if (Test-Path -LiteralPath $PartPath -PathType Leaf) {
            $existing = (Get-Item -LiteralPath $PartPath).Length
        }
        if ($ExpectedTotal -gt 0 -and $existing -gt $ExpectedTotal) {
            Remove-Item -LiteralPath $PartPath -Force
            $existing = 0
        }
        if ($ExpectedTotal -gt 0 -and $existing -eq $ExpectedTotal) {
            return $PartPath
        }

        $uri = Join-RouteUrl -Route $Route -Url $Url
        Write-Log ("下载 {0} [{1}]，已有 {2} 字节" -f $uri, $Route.Name, $existing) INFO

        $cts = New-Object System.Threading.CancellationTokenSource([TimeSpan]::FromMinutes(60))
        $handler = New-RouteHandler $Route
        # Do not transparently decompress: the payload is already a ZIP and the
        # Content-Length must match the bytes written to disk for resume to work.
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromMinutes(60)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $script:UserAgent)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/octet-stream')

        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $uri)
        if ($existing -gt 0) {
            [void]$request.Headers.TryAddWithoutValidation('Range', ('bytes={0}-' -f $existing))
        }

        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -eq 416) {
            if ($ExpectedTotal -gt 0 -and $existing -eq $ExpectedTotal) { return $PartPath }
            Remove-Item -LiteralPath $PartPath -Force -ErrorAction SilentlyContinue
            throw '服务器拒绝了断点续传请求。'
        }
        if (-not $response.IsSuccessStatusCode) {
            throw ('HTTP {0} {1}' -f [int]$response.StatusCode, $response.ReasonPhrase)
        }

        $append = $false
        if ($existing -gt 0 -and [int]$response.StatusCode -eq 206) {
            $append = $true
        } elseif ($existing -gt 0) {
            # The server ignored Range and sent the whole file.
            $existing = 0
        }

        $contentLength = $response.Content.Headers.ContentLength
        $total = $ExpectedTotal
        if ($total -le 0 -and $null -ne $contentLength) {
            $total = [long]$contentLength + $existing
        }

        $fileMode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $fileStream = New-Object System.IO.FileStream($PartPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = New-Object byte[] 131072
        $current = $existing
        $lastUpdate = [datetime]::UtcNow
        $speedWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lastBytes = $current

        while ($true) {
            Test-Cancellation
            $read = $stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()
            if ($read -le 0) { break }
            $fileStream.Write($buffer, 0, $read)
            $current += $read

            $now = [datetime]::UtcNow
            if (($now - $lastUpdate).TotalMilliseconds -ge 180) {
                $elapsed = [Math]::Max(0.001, $speedWatch.Elapsed.TotalSeconds)
                $speed = [Math]::Max(0.0, ($current - $existing) / $elapsed)
                $percent = if ($total -gt 0) { [Math]::Min(100.0, $current * 100.0 / $total) } else { 0.0 }
                $overall = $ProgressStart + (($ProgressEnd - $ProgressStart) * ($percent / 100.0))
                $totalLabel = if ($total -gt 0) { Format-Size $total } else { '?' }
                $script:UiState.Progress = $overall
                $script:UiState.DownloadPercent = $percent
                $script:UiState.DownloadBytes = $current
                $script:UiState.DownloadTotal = $total
                $script:UiState.Speed = $speed
                $script:UiState.Detail = ('线路: {0}' -f $Route.Name)
                if (-not $script:UseGui) {
                    $line = "`r  下载 {0,5:N1}%    {1} / {2}    {3}/s" -f $percent, (Format-Size $current), $totalLabel, (Format-Size ([long]$speed))
                    try {
                        $width = [Math]::Max(20, [Console]::WindowWidth - 1)
                        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
                    } catch { }
                    Write-Host $line -NoNewline
                }
                $lastUpdate = $now
            }
        }

        $fileStream.Flush($true)
        if (-not $script:UseGui) { Write-Host '' }
        if ($ExpectedTotal -gt 0 -and $current -ne $ExpectedTotal) {
            throw ('下载大小不符：期望 {0} 字节，实际 {1} 字节。' -f $ExpectedTotal, $current)
        }
        return $PartPath
    } finally {
        if ($null -ne $fileStream) { try { $fileStream.Dispose() } catch { } }
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
        if ($null -ne $response) { try { $response.Dispose() } catch { } }
        if ($null -ne $request) { try { $request.Dispose() } catch { } }
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
        if ($null -ne $handler) { try { $handler.Dispose() } catch { } }
        if ($null -ne $cts) { try { $cts.Dispose() } catch { } }
    }
}

function Invoke-UpdateDownload {
    param(
        [object]$Release,
        [object[]]$Routes,
        [string]$Destination
    )

    $part = $Destination + '.part'
    $cacheDir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $useCached = $false
        if ($Release.Sha256) {
            $useCached = Test-FileHash -Path $Destination -ExpectedSha256 $Release.Sha256
        } elseif ($Release.Size -gt 0) {
            $useCached = ((Get-Item -LiteralPath $Destination).Length -eq $Release.Size) -and (Test-ZipArchive -Path $Destination)
        } else {
            $useCached = Test-ZipArchive -Path $Destination
        }
        if ($useCached) {
            Write-Log ('复用已下载的更新包: {0}' -f $Destination)
            Set-UiStatus -Phase '下载更新' -Message '发现已下载的更新包，跳过下载。' -Progress 70
            return $Destination
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $orderedRoutes = @($Routes)

    # Put the route that succeeded for metadata first, when available. The
    # caller passes routes in the same priority order, so this is a no-op for
    # normal operation but keeps retries deterministic.
    foreach ($route in $orderedRoutes) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            Test-Cancellation
            try {
                Set-UiStatus -Phase '下载更新' -Message ('正在从 {0} 下载...' -f $route.Name) -Progress 8
                Invoke-DownloadRoute -Route $route -Url $Release.AssetUrl -PartPath $part -ExpectedTotal $Release.Size -ProgressStart 8 -ProgressEnd 70 | Out-Null
                if ($Release.Size -gt 0 -and (Get-Item -LiteralPath $part).Length -ne $Release.Size) {
                    throw '下载文件大小不正确。'
                }
                if ($Release.Sha256) {
                    if (-not (Test-FileHash -Path $part -ExpectedSha256 $Release.Sha256)) {
                        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                        throw 'SHA256 校验失败，文件已损坏。'
                    }
                } elseif (-not (Test-ZipArchive -Path $part)) {
                    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                    throw '下载的文件不是有效的 ZIP 包。'
                }
                Move-Item -LiteralPath $part -Destination $Destination -Force
                $script:UiState.Progress = 70
                $script:UiState.Detail = '更新包下载完成。'
                return $Destination
            } catch {
                if ($_.Exception -is [System.OperationCanceledException]) { throw }
                $message = $_.Exception.Message
                $errors.Add(('{0}（第 {1} 次）: {2}' -f $route.Name, $attempt, $message))
                Write-Log ("下载失败 [{0}] 第 {1} 次: {2}" -f $route.Name, $attempt, $message) WARN
                if ($attempt -lt 2) { Start-Sleep -Seconds 1 }
            }
        }
    }

    throw ("更新包下载失败。`n" + ($errors -join "`n"))
}

# ---------------------------------------------------------------------------
# Extract and install
# ---------------------------------------------------------------------------
function Expand-UpdatePackage {
    param([string]$ZipPath, [string]$Destination)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entries = @($zip.Entries)
        $index = 0
        $destinationFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'

        foreach ($entry in $entries) {
            Test-Cancellation
            $index++
            $relative = $entry.FullName.Replace('\', '/').TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }

            if ($relative.EndsWith('/')) {
                $dir = [System.IO.Path]::GetFullPath((Join-Path $Destination $relative.Replace('/', '\')))
                if (-not $dir.StartsWith($destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw ('ZIP 包含非法路径: {0}' -f $entry.FullName)
                }
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                continue
            }
            if ($relative -match '(^|/)\.\.(/|$)' -or $relative -match '^[A-Za-z]:') {
                throw ('ZIP 包含非法路径: {0}' -f $entry.FullName)
            }

            $target = [System.IO.Path]::GetFullPath((Join-Path $Destination $relative.Replace('/', '\')))
            if (-not $target.StartsWith($destinationFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('ZIP 包含非法路径: {0}' -f $entry.FullName)
            }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

            $inputStream = $null
            $outputStream = $null
            try {
                $inputStream = $entry.Open()
                $outputStream = New-Object System.IO.FileStream($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $buffer = New-Object byte[] 131072
                while ($true) {
                    Test-Cancellation
                    $read = $inputStream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $outputStream.Write($buffer, 0, $read)
                }
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $inputStream) { $inputStream.Dispose() }
            }
            try { [System.IO.File]::SetLastWriteTime($target, $entry.LastWriteTime.LocalDateTime) } catch { }

            if (($index % 20) -eq 0 -or $index -eq $entries.Count) {
                $pct = $index * 100.0 / [Math]::Max(1, $entries.Count)
                $overall = 72 + ($pct * 0.18)
                Set-UiStatus -Phase '解压更新' -Message '正在解压更新包...' -Progress $overall
                Set-UiDetail ('{0} / {1} 个文件' -f $index, $entries.Count)
                Write-CliProgress -Label '解压' -Percent $pct -Detail ('{0} / {1} 个文件' -f $index, $entries.Count)
            }
        }
        if (-not $script:UseGui) { Write-Host '' }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Find-PackageRoot {
    param([string]$StagePath)

    $exe = @(Get-ChildItem -LiteralPath $StagePath -Filter 'MajdataPlay.exe' -Recurse -File -ErrorAction Stop)
    if ($exe.Count -ne 1) {
        throw ('更新包中 MajdataPlay.exe 数量异常（{0} 个）。' -f $exe.Count)
    }
    $root = Split-Path -Parent $exe[0].FullName
    if (-not (Test-Path -LiteralPath (Join-Path $root 'MajdataPlay_Data') -PathType Container)) {
        throw '更新包结构异常：缺少 MajdataPlay_Data 文件夹。'
    }
    return $root
}

function Install-UpdatePackage {
    param([string]$PackageRoot)

    $files = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -ErrorAction Stop)
    if ($files.Count -eq 0) { throw '更新包中没有文件。' }

    $copied = 0
    $skippedStreaming = 0
    $skippedDebug = 0
    $index = 0

    foreach ($file in $files) {
        Test-Cancellation
        $index++
        $relative = $file.FullName.Substring($PackageRoot.TrimEnd('\').Length).TrimStart('\', '/')
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }

        if ($relative -match '(^|\\)(MajdataPlay_BurstDebugInformation_DoNotShip|[^\\]*_BackUpThisFolder_ButDontShipItWithYourGame)(\\|$)') {
            $skippedDebug++
            continue
        }

        $isStreamingAssets = $relative -match '(^|\\)StreamingAssets(\\|$)'
        $target = Join-Path $script:InstallPath $relative

        if ($isStreamingAssets -and -not $OverwriteStreamingAssets -and (Test-Path -LiteralPath $target -PathType Leaf)) {
            $skippedStreaming++
            continue
        }

        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if (Test-Path -LiteralPath $target -PathType Container) {
            throw ('无法覆盖文件，目标位置是一个文件夹: {0}' -f $target)
        }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            try {
                $item = Get-Item -LiteralPath $target -Force
                if ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    $item.Attributes = $item.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
                }
            } catch { }
        }

        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++

        if (($index % 25) -eq 0 -or $index -eq $files.Count) {
            $pct = $index * 100.0 / [Math]::Max(1, $files.Count)
            $overall = 90 + ($pct * 0.09)
            Set-UiStatus -Phase '安装更新' -Message '正在安装文件...' -Progress $overall
            Set-UiDetail ('已复制 {0}，StreamingAssets 跳过 {1}' -f $copied, $skippedStreaming)
            Write-CliProgress -Label '安装' -Percent $pct -Detail ('已复制 {0}，跳过 {1}' -f $copied, $skippedStreaming)
        }
    }
    if (-not $script:UseGui) { Write-Host '' }

    $script:UiState.Progress = 99
    return [pscustomobject]@{
        Copied          = $copied
        SkippedStreaming = $skippedStreaming
        SkippedDebug    = $skippedDebug
        Total           = $files.Count
    }
}

# ---------------------------------------------------------------------------
# GUI and process helpers
# ---------------------------------------------------------------------------
function Get-EligibleScreen {
    param([int]$Index)

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $screens = @([System.Windows.Forms.Screen]::AllScreens)
    } catch {
        Write-Log ('无法枚举显示器: ' + $_.Exception.Message) WARN
        return $null
    }

    if ($screens.Count -eq 0) { return $null }

    if ($Index -ge 0) {
        if ($Index -ge $screens.Count) {
            Write-Log ("显示器索引 {0} 超出范围（共 {1} 个）。" -f $Index, $screens.Count) WARN
            return $null
        }
        $selected = $screens[$Index]
        if (Test-Portrait169 -Bounds $selected.Bounds) { return $selected }
        Write-Log ("显示器 {0} 不是竖屏 16:9（{1}x{2}）。" -f $Index, $selected.Bounds.Width, $selected.Bounds.Height) WARN
        return $null
    }

    $ordered = @($screens | Where-Object { $_.Primary }) + @($screens | Where-Object { -not $_.Primary })
    foreach ($screen in $ordered) {
        if (Test-Portrait169 -Bounds $screen.Bounds) { return $screen }
    }
    return $null
}

function Test-Portrait169 {
    param([System.Drawing.Rectangle]$Bounds)
    if ($Bounds.Width -le 0 -or $Bounds.Height -le 0) { return $false }
    if ($Bounds.Width -ge $Bounds.Height) { return $false }
    $ratio = $Bounds.Width / [double]$Bounds.Height
    return ([Math]::Abs($ratio - (9.0 / 16.0)) -le 0.02)
}

function Start-UpdaterGui {
    param([System.Windows.Forms.Screen]$Screen)

    try {
        $bounds = $Screen.Bounds
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($script:GuiSource)
        [void]$ps.AddArgument($script:UiState)
        [void]$ps.AddArgument([int]$bounds.Left)
        [void]$ps.AddArgument([int]$bounds.Top)
        [void]$ps.AddArgument([int]$bounds.Width)
        [void]$ps.AddArgument([int]$bounds.Height)
        $handle = $ps.BeginInvoke()

        $script:GuiPowerShell = $ps
        $script:GuiRunspace = $runspace
        $script:UseGui = $true

        $ready = Wait-WithTimeout -Condition {
            $script:UiState.GuiReady -or $script:UiState.GuiClosed -or -not [string]::IsNullOrWhiteSpace([string]$script:UiState.GuiError)
        } -TimeoutMs 4000
        if ($script:UiState.GuiReady) {
            Write-Log 'GUI 已启动。'
            return $true
        }

        $errorText = [string]$script:UiState.GuiError
        Write-Log ("GUI 启动失败: {0}" -f $errorText) WARN
        Stop-UpdaterGui -Force
        $script:UseGui = $false
        return $false
    } catch {
        Write-Log ("GUI 启动异常: {0}" -f $_.Exception.Message) WARN
        Stop-UpdaterGui -Force
        $script:UseGui = $false
        return $false
    }
}

function Stop-UpdaterGui {
    param([switch]$Force)

    if ($null -eq $script:GuiPowerShell) { return }

    if (-not [string]::IsNullOrWhiteSpace([string]$script:UiState.GuiError)) {
        Write-Log ('GUI 运行时错误: ' + [string]$script:UiState.GuiError) WARN
    }

    try {
        $script:UiState.CloseRequested = $true
        Wait-WithTimeout -Condition { $script:UiState.GuiClosed } -TimeoutMs 2500 | Out-Null
    } catch { }

    try {
        $settled = $false
        if ($null -eq $script:GuiPowerShell) {
            $settled = $true
        } else {
            $settled = Wait-WithTimeout -Condition {
                $script:GuiPowerShell.InvocationStateInfo.State -ne [System.Management.Automation.PSInvocationState]::Running
            } -TimeoutMs 2000
        }
        if ($settled) {
            if ($null -ne $script:GuiPowerShell) { $script:GuiPowerShell.Dispose() }
            if ($null -ne $script:GuiRunspace) { $script:GuiRunspace.Dispose() }
        } elseif (-not $script:UiState.GuiClosed) {
            # Only abort when the window never closed. Aborting a visible paint
            # callback produces a fatal WinForms PipelineStoppedException.
            $script:GuiPowerShell.Stop()
            $script:GuiPowerShell.Dispose()
            if ($null -ne $script:GuiRunspace) { $script:GuiRunspace.Dispose() }
        }
    } catch { }

    $script:GuiPowerShell = $null
    $script:GuiRunspace = $null
}

function Set-FinalState {
    param(
        [bool]$Success,
        [string]$Phase,
        [string]$Message,
        [string]$Detail = '',
        [string]$Hint = ''
    )

    $script:UiState.Finished = $true
    $script:UiState.Success = $Success
    $script:UiState.Failed = (-not $Success)
    $script:UiState.Phase = $Phase
    $script:UiState.Message = $Message
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $script:UiState.Detail = $Detail }
    if (-not [string]::IsNullOrWhiteSpace($Hint)) { $script:UiState.Hint = $Hint }
    if ($Success) { $script:UiState.Progress = 100 }
    $script:UiState.Speed = 0
    Write-Log ("$Phase | $Message")
    if (-not $script:UseGui) {
        $color = if ($Success) { 'Green' } else { 'Red' }
        Write-Host ''
        Write-Host ("[{0}] {1}" -f $Phase, $Message) -ForegroundColor $color
        if (-not [string]::IsNullOrWhiteSpace($Detail)) {
            Write-Host ("        " + $Detail) -ForegroundColor DarkGray
        }
    }
}

function Complete-Gui {
    param([int]$DelayMs = 1200)

    if (-not $script:UseGui) { return }
    Start-Sleep -Milliseconds $DelayMs
    $script:UiState.CloseRequested = $true
    Wait-WithTimeout -Condition { $script:UiState.GuiClosed } -TimeoutMs 2500 | Out-Null
    Stop-UpdaterGui -Force
    $script:UseGui = $false
}

function Wait-GuiErrorDismiss {
    if (-not $script:UseGui) { return }
    if ($script:UiState.GuiClosed) {
        $script:UseGui = $false
        return
    }
    # Give the user time to read the error. Esc closes immediately.
    Wait-WithTimeout -Condition { $script:UiState.CloseRequested -or $script:UiState.GuiClosed } -TimeoutMs 20000 | Out-Null
    $script:UiState.CloseRequested = $true
    Wait-WithTimeout -Condition { $script:UiState.GuiClosed } -TimeoutMs 2500 | Out-Null
    Stop-UpdaterGui -Force
    $script:UseGui = $false
}

function Read-BootMenuConsole {
    param(
        [object[]]$Items,
        [string]$CurrentEngine,
        [string]$CurrentChannel,
        [int]$TimeoutSec
    )

    $result = [pscustomobject]@{ Action = 'Timeout'; Kind = ''; Id = ''; TimedOut = $false; Error = '' }
    try {
        if ([Console]::IsInputRedirected) { return $result }
        $null = [Console]::KeyAvailable
    } catch {
        return $result
    }

    $index = 0
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].Kind -eq 'engine' -and $Items[$i].Id -eq $CurrentEngine) {
            $index = $i
            break
        }
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $countdown = ($TimeoutSec -gt 0)
    $lastSecond = -1
    $firstRender = $true

    $render = {
        Clear-Host
        Write-Host ''
        Write-Host '  BOOT MENU' -ForegroundColor Cyan
        Write-Host '  选择启动项，或切换更新通道' -ForegroundColor DarkGray
        Write-Host ''
        $previousKind = $null
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            if ($null -ne $previousKind -and $previousKind -eq 'engine' -and $item.Kind -eq 'channel') {
                Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkCyan
            }
            $current = ''
            if ($item.Kind -eq 'engine' -and $item.Id -eq $CurrentEngine) { $current = ' *' }
            if ($item.Kind -eq 'channel' -and $item.Id -eq $CurrentChannel) { $current = ' *' }
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $line = '  {0} {1}{2}' -f $marker, $item.Label, $current
            if ($i -eq $index) {
                Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host $line -ForegroundColor Gray
            }
            $previousKind = $item.Kind
        }
        Write-Host ''
        if ($TimeoutSec -le 0) {
            Write-Host '  请选择启动项' -ForegroundColor Yellow
        } elseif ($countdown) {
            $remaining = [Math]::Max(0, $TimeoutSec - $watch.Elapsed.TotalSeconds)
            Write-Host ('  {0:N0} 秒后自动继续' -f [Math]::Ceiling($remaining)) -ForegroundColor Yellow
        } else {
            Write-Host '  Enter / C 确认' -ForegroundColor Yellow
        }
        Write-Host '  ↑/↓ 选择   Enter/C 确认   Esc 跳过' -ForegroundColor DarkGray
    }

    while ($true) {
        $redraw = $firstRender
        $firstRender = $false
        if ($countdown) {
            $remaining = $TimeoutSec - $watch.Elapsed.TotalSeconds
            if ($remaining -le 0) {
                $item = $Items[$index]
                $result.Kind = $item.Kind
                $result.Id = $item.Id
                $result.Action = 'Select'
                $result.TimedOut = $true
                try { Clear-Host } catch { }
                return $result
            }
            $second = [int][Math]::Ceiling($remaining)
            if ($second -ne $lastSecond) {
                $lastSecond = $second
                $redraw = $true
            }
        }

        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                # Any keyboard action cancels the automatic countdown immediately.
                $countdown = $false
                switch ($key.Key) {
                    ([ConsoleKey]::UpArrow) { $index-- }
                    ([ConsoleKey]::W) { $index-- }
                    ([ConsoleKey]::Q) { $index-- }
                    ([ConsoleKey]::DownArrow) { $index++ }
                    ([ConsoleKey]::S) { $index++ }
                    ([ConsoleKey]::Z) { $index++ }
                    ([ConsoleKey]::X) { $index++ }
                    ([ConsoleKey]::Enter) {
                        $item = $Items[$index]
                        $result.Kind = $item.Kind
                        $result.Id = $item.Id
                        $result.Action = 'Select'
                        try { Clear-Host } catch { }
                        return $result
                    }
                    ([ConsoleKey]::C) {
                        $item = $Items[$index]
                        $result.Kind = $item.Kind
                        $result.Id = $item.Id
                        $result.Action = 'Select'
                        try { Clear-Host } catch { }
                        return $result
                    }
                    ([ConsoleKey]::Escape) {
                        try { Clear-Host } catch { }
                        return $result
                    }
                }
                if ($index -lt 0) { $index = $Items.Count - 1 }
                if ($index -ge $Items.Count) { $index = 0 }
                $redraw = $true
            }
        } catch {
            return $result
        }

        if ($redraw) {
            try { & $render } catch { return $result }
        }
        Start-Sleep -Milliseconds 100
    }
}

function Show-BootMenu {
    param(
        [object]$TargetScreen,
        [object[]]$Items,
        [string]$CurrentEngine,
        [string]$CurrentChannel,
        [int]$TimeoutSec = 5
    )

    $result = [pscustomobject]@{
        Action   = 'Timeout'
        Kind     = ''
        Id       = ''
        TimedOut = $false
        Error    = ''
    }

    if ($NoGui -or $null -eq $TargetScreen) {
        return (Read-BootMenuConsole -Items $Items -CurrentEngine $CurrentEngine -CurrentChannel $CurrentChannel -TimeoutSec $TimeoutSec)
    }

    $ps = $null
    $runspace = $null
    try {
        $bounds = $TargetScreen.Bounds
        $state = [hashtable]::Synchronized(@{
            Ready    = $false
            Closed   = $false
            Action   = 'Timeout'
            Kind     = ''
            Id       = ''
            TimedOut = $false
            Error    = ''
            Handle   = [int64]0
        })

        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($script:BootMenuSource)
        [void]$ps.AddArgument($state)
        [void]$ps.AddArgument($Items)
        [void]$ps.AddArgument($CurrentEngine)
        [void]$ps.AddArgument($CurrentChannel)
        [void]$ps.AddArgument([int]$TimeoutSec)
        [void]$ps.AddArgument([int]$bounds.Left)
        [void]$ps.AddArgument([int]$bounds.Top)
        [void]$ps.AddArgument([int]$bounds.Width)
        [void]$ps.AddArgument([int]$bounds.Height)
        [void]$ps.BeginInvoke()

        $ready = Wait-WithTimeout -Condition {
            $state.Ready -or $state.Closed -or -not [string]::IsNullOrWhiteSpace([string]$state.Error)
        } -TimeoutMs 8000
        if (-not $ready -or (-not $state.Ready -and -not $state.Closed)) {
            throw ('启动菜单窗口启动失败: ' + [string]$state.Error)
        }

        while (-not $state.Closed -and [string]::IsNullOrWhiteSpace([string]$state.Error)) {
            Start-Sleep -Milliseconds 100
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$state.Error)) {
            throw [string]$state.Error
        }

        $result.Action = [string]$state.Action
        $result.Kind = [string]$state.Kind
        $result.Id = [string]$state.Id
        $result.TimedOut = [bool]$state.TimedOut
        return $result
    } catch {
        Write-Log ('启动菜单 GUI 不可用，回退到控制台: ' + $_.Exception.Message) WARN
        return (Read-BootMenuConsole -Items $Items -CurrentEngine $CurrentEngine -CurrentChannel $CurrentChannel -TimeoutSec $TimeoutSec)
    } finally {
        try {
            # Never abort the runspace while a WinForms Paint callback may still
            # be executing. PipelineStoppedException inside OnPaint is fatal.
            $settled = $false
            if ($null -eq $ps) {
                $settled = $true
            } else {
                $settled = Wait-WithTimeout -Condition {
                    $ps.InvocationStateInfo.State -ne [System.Management.Automation.PSInvocationState]::Running
                } -TimeoutMs 3000
            }
            if ($settled) {
                if ($null -ne $ps) { $ps.Dispose() }
                if ($null -ne $runspace) { $runspace.Dispose() }
            } else {
                Write-Log '启动菜单 runspace 未在 3 秒内结束，留给进程退出时回收。' WARN
            }
        } catch { }
    }
}

function Test-GameRunning {
    $count = @(Get-Process -Name 'MajdataPlay' -ErrorAction SilentlyContinue).Count
    return ($count -gt 0)
}

function Stop-GameIfRequested {
    if (-not (Test-GameRunning)) { return }
    if (-not $StopRunningGame) {
        throw 'MajdataPlay 正在运行。请先关闭游戏，或使用 -StopRunningGame 让更新器关闭它。'
    }

    Set-UiStatus -Phase '安装更新' -Message '正在关闭正在运行的 MajdataPlay...' -Progress 90
    $processes = @(Get-Process -Name 'MajdataPlay' -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    $closed = Wait-WithTimeout -Condition { -not (Test-GameRunning) } -TimeoutMs 5000
    if (-not $closed) {
        foreach ($process in @(Get-Process -Name 'MajdataPlay' -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id $process.Id -Force } catch { }
        }
    }
    if (Test-GameRunning) { throw '无法关闭正在运行的 MajdataPlay。' }
}

function Wait-GameWindow {
    param([int]$TimeoutSec = 60)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $sawProcess = $false
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $processes = @(Get-Process -Name 'MajdataPlay' -ErrorAction SilentlyContinue)
        if ($processes.Count -gt 0) { $sawProcess = $true }
        foreach ($process in $processes) {
            try {
                $process.Refresh()
                if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                    return $process
                }
            } catch { }
        }
        if (-not $sawProcess -and $watch.Elapsed.TotalSeconds -ge 5) {
            throw 'MajdataPlay 进程未能启动。'
        }
        Start-Sleep -Milliseconds 250
    }

    $processes = @(Get-Process -Name 'MajdataPlay' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        throw 'MajdataPlay 启动后未保持运行。'
    }
    throw ('MajdataPlay 进程已启动，但在 {0} 秒内没有检测到游戏窗口。' -f $TimeoutSec)
}

function Set-GameWindowForeground {
    param([System.Diagnostics.Process]$Process)

    try {
        if (-not ('MajdataUpdaterWindowNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MajdataUpdaterWindowNative {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr hWnd);
}
'@
        }

        $handle = [IntPtr]$Process.MainWindowHandle
        if ($handle -eq [IntPtr]::Zero) { return $false }

        [void][MajdataUpdaterWindowNative]::ShowWindow($handle, 9) # SW_RESTORE
        [void][MajdataUpdaterWindowNative]::BringWindowToTop($handle)
        [void][MajdataUpdaterWindowNative]::SetForegroundWindow($handle)

        # Windows can refuse foreground activation from a background process.
        # Toggling topmost and retrying makes the window rise reliably.
        $flags = 0x0001 -bor 0x0002 -bor 0x0040 # NOSIZE | NOMOVE | SHOWWINDOW
        [void][MajdataUpdaterWindowNative]::SetWindowPos($handle, [IntPtr](-1), 0, 0, 0, 0, $flags)
        [void][MajdataUpdaterWindowNative]::SetWindowPos($handle, [IntPtr](-2), 0, 0, 0, 0, $flags)

        $foreground = [MajdataUpdaterWindowNative]::GetForegroundWindow()
        [uint32]$processId = 0
        $targetThread = [MajdataUpdaterWindowNative]::GetWindowThreadProcessId($handle, [ref]$processId)
        $foregroundThread = [MajdataUpdaterWindowNative]::GetWindowThreadProcessId($foreground, [ref]$processId)
        $currentThread = [MajdataUpdaterWindowNative]::GetCurrentThreadId()
        $attached = $false
        if ($currentThread -ne $targetThread) {
            $attached = [MajdataUpdaterWindowNative]::AttachThreadInput($currentThread, $targetThread, $true)
        }
        try {
            [void][MajdataUpdaterWindowNative]::SetForegroundWindow($handle)
            [void][MajdataUpdaterWindowNative]::SetFocus($handle)
        } finally {
            if ($attached) {
                [void][MajdataUpdaterWindowNative]::AttachThreadInput($currentThread, $targetThread, $false)
            }
        }

        Start-Sleep -Milliseconds 300
        $foreground = [MajdataUpdaterWindowNative]::GetForegroundWindow()
        return ($foreground -eq $handle)
    } catch {
        Write-Log ('设置游戏窗口前台失败: ' + $_.Exception.Message) WARN
        return $false
    }
}

function Start-Game {
    if ($NoLaunch) {
        Write-Log '已指定 -NoLaunch，不启动游戏。'
        return
    }
    $exe = Join-Path $script:InstallPath 'MajdataPlay.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "找不到 MajdataPlay.exe: $exe"
    }

    if (Test-GameRunning) {
        Write-Log 'MajdataPlay 已在运行，核验窗口并置于前台。'
    } else {
        Write-Log ("启动游戏: {0} {1}" -f $exe, $script:GameLaunchArgs)
        $startArgs = @{
            FilePath         = $exe
            WorkingDirectory = $script:InstallPath
            PassThru         = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($script:GameLaunchArgs)) {
            $startArgs.ArgumentList = $script:GameLaunchArgs
        }
        $started = Start-Process @startArgs
        if ($null -eq $started) { throw '无法创建 MajdataPlay 进程。' }
    }

    $gameProcess = Wait-GameWindow -TimeoutSec 60
    Write-Log ('检测到游戏窗口，PID {0}，标题: {1}' -f $gameProcess.Id, $gameProcess.MainWindowTitle)
    $focused = Set-GameWindowForeground -Process $gameProcess
    if ($focused) {
        Write-Log ('MajdataPlay 已启动并置于前台 (PID {0})。' -f $gameProcess.Id)
    } else {
        Write-Log ('MajdataPlay 已启动，但未能确认窗口是否处于前台 (PID {0})。' -f $gameProcess.Id) WARN
    }
}

function Assert-DiskSpace {
    param([string]$WorkPath, [long]$AssetSize)

    if ($AssetSize -le 0) { return }
    # The ZIP plus its extracted staging tree need roughly 4x the compressed
    # size. Everything now lives below the install directory.
    $needWork = [long]($AssetSize * 4.0)
    $needInstall = [long]($AssetSize * 4.0)
    foreach ($pair in @(@($WorkPath, $needWork, '下载/解压'), @($script:InstallPath, $needInstall, '安装'))) {
        try {
            $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath([string]$pair[0]))
            $drive = New-Object System.IO.DriveInfo($root)
            if ($drive.AvailableFreeSpace -lt [long]$pair[1]) {
                throw ('{0}磁盘剩余空间不足：需要约 {1}，可用 {2}。' -f $pair[2], (Format-Size ([long]$pair[1])), (Format-Size $drive.AvailableFreeSpace))
            }
        } catch {
            if ($_.Exception.Message -match '磁盘剩余空间不足') { throw }
            Write-Log ("无法检查 {0} 磁盘空间: {1}" -f $pair[0], $_.Exception.Message) WARN
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$exitCode = 0
$guiStarted = $false
$staging = $null
$download = $null

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw '此更新器仅支持 Windows。'
    }

    try {
        [Console]::OutputEncoding = $script:Utf8NoBom
        $OutputEncoding = $script:Utf8NoBom
    } catch { }
    try { $Host.UI.RawUI.WindowTitle = 'MajdataPlay Updater' } catch { }

    # Windows PowerShell 5.1 does not load System.Net.Http by default.
    try { Add-Type -AssemblyName System.Net.Http } catch { }

    # Force TLS 1.2. Some Windows PowerShell/.NET combinations otherwise try an
    # unsupported protocol and fail with SEC_E_NO_CREDENTIALS.
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    } catch { }

    if (-not [string]::IsNullOrWhiteSpace($Proxy) -and $NoProxy) {
        throw '不能同时指定 -Proxy 和 -NoProxy。'
    }

    $script:InstallPath = Resolve-InstallPath -ExplicitPath $InstallPath

    if (-not $CheckOnly) {
        $probePath = Join-Path $script:InstallPath ('.majdataplay-write-test-' + $PID)
        try {
            [System.IO.File]::WriteAllText($probePath, 'ok', $script:Utf8NoBom)
            Remove-Item -LiteralPath $probePath -Force
        } catch {
            throw ('安装目录不可写: {0}。请将脚本放到有写权限的目录，或以管理员身份运行。' -f $script:InstallPath)
        }
    }

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = Join-Path $script:InstallPath 'majdataplay-updater.log'
    }
    Initialize-Logger -Path $LogPath
    Write-Log ('MajdataPlay Updater {0} 启动。PowerShell {1} / {2}' -f $script:UpdaterVersion, $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
    Write-Log ('安装目录: {0}; 覆盖 StreamingAssets: {1}' -f $script:InstallPath, [bool]$OverwriteStreamingAssets)

    # All updater work files live inside the game directory (the default game
    # directory itself is <script directory>\MajdataPlay); no external cache or
    # temporary directory is used.
    $downloadDir = $script:InstallPath
    $script:WorkRoot = $downloadDir
    $stagingRoot = Join-Path $downloadDir 'staging'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    if (Test-Path -LiteralPath $stagingRoot) {
        # Remove leftover staging trees from an interrupted previous run.
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Log ('下载/解压目录: {0}' -f $downloadDir)

    Set-UiStatus -Phase '检查代理' -Message '正在检查系统代理...' -Progress 2
    Write-Log '开始检测系统代理。' DEBUG
    $proxies = @(Get-SystemProxyCandidates)
    Write-Log ('代理检测完成，共 {0} 个。' -f $proxies.Count) DEBUG
    if ($proxies.Count -gt 0) {
        Write-Log ('检测到代理: ' + (($proxies | ForEach-Object { $_.Display }) -join ', '))
    } else {
        Write-Log '未检测到系统代理。'
    }
    $routes = @(Get-Routes -Proxies $proxies)
    Write-Log ('候选线路: ' + (($routes | ForEach-Object { $_.Name }) -join ' -> '))
    Set-UiDetail ('线路: ' + (($routes | ForEach-Object { $_.Name }) -join ' / '))

    if (-not $SkipSelfUpdate) {
        Set-UiStatus -Phase '检查更新器' -Message '正在检查更新器自身...' -Progress 3
        try {
            # Self-update is a small, best-effort request. Use one route only so
            # a slow mirror/404 cannot stall the actual game update.
            $selfRoute = $null
            $proxyRoute = @($routes | Where-Object { $_.Kind -eq 'proxy' } | Select-Object -First 1)
            if ($proxyRoute.Count -gt 0) {
                $selfRoute = $proxyRoute[0]
            } else {
                $mirrorRoute = @($routes | Where-Object { $_.Kind -eq 'mirror' } | Select-Object -First 1)
                if ($mirrorRoute.Count -gt 0) { $selfRoute = $mirrorRoute[0] }
                else { $selfRoute = @($routes | Where-Object { $_.Kind -eq 'direct' } | Select-Object -First 1)[0] }
            }
            $selfResult = Invoke-UpdaterSelfUpdate -Routes @($selfRoute) -BoundParameters $PSBoundParameters -Url $SelfUpdateUrl
            if ($selfResult.Updated) {
                Set-FinalState -Success $true -Phase '更新器已更新' -Message $selfResult.Message -Detail ('新版本 {0}' -f $selfResult.Version) -Hint '正在重启...'
                if ($script:UseGui) { Complete-Gui -DelayMs 1200 }
                if (Start-UpdaterRestart -BoundParameters $PSBoundParameters) {
                    exit 0
                }
                Write-Log '更新器重启失败，继续使用当前实例完成本次任务。' WARN
            } elseif ($selfResult.Version) {
                Write-Log $selfResult.Message DEBUG
            }
        } catch {
            Write-Log ('更新器自更新检查失败（忽略并继续）: ' + $_.Exception.Message) WARN
        }
    }


    $channelWasExplicit = $PSBoundParameters.ContainsKey('Channel')
    $menuState = Read-InstallState
    $menuChannel = 'Stable'
    if ($channelWasExplicit) {
        $menuChannel = ConvertTo-ChannelName $Channel
    } elseif ($null -ne $menuState) {
        $menuChannel = ConvertTo-ChannelName ([string]$menuState.channel)
    }
    if ($null -eq $menuChannel) { $menuChannel = 'Stable' }

    $savedEngine = Get-SavedEngine
    $script:GameLaunchArgs = Get-EngineArguments $savedEngine
    $isFirstRun = -not (Test-CoreFilesPresent)
    if (-not $CheckOnly -and -not $SkipBootMenu) {
        try {
            if ($null -eq $menuState -or [string]::IsNullOrWhiteSpace([string]$menuState.engine)) {
                Save-LaunchEngine -Engine $savedEngine
            }
            $menuItems = Get-BootMenuItems
            $menuScreen = $null
            if (-not $NoGui) {
                $menuScreen = Get-EligibleScreen -Index $MonitorIndex
            }
            $menuTimeout = if ($isFirstRun) { 0 } else { 5 }
            if ($isFirstRun) {
                Write-Log '显示启动菜单（首次启动，不自动倒计时）。'
            } else {
                Write-Log '显示启动菜单（5 秒无操作则使用默认项继续）。'
            }
            $menuResult = Show-BootMenu -TargetScreen $menuScreen -Items $menuItems -CurrentEngine $savedEngine -CurrentChannel $menuChannel -TimeoutSec $menuTimeout
            if ($menuResult.Action -eq 'Select') {
                if ($menuResult.TimedOut) {
                    Write-Log '启动菜单超时，采用当前高亮项。'
                }
                if ($menuResult.Kind -eq 'engine') {
                    $savedEngine = ConvertTo-EngineId $menuResult.Id
                    Save-LaunchEngine -Engine $savedEngine
                    $script:GameLaunchArgs = Get-EngineArguments $savedEngine
                    Write-Log ('启动菜单选择引擎: {0} ({1})' -f $savedEngine, $script:GameLaunchArgs)
                } elseif ($menuResult.Kind -eq 'channel') {
                    $selectedChannel = ConvertTo-ChannelName $menuResult.Id
                    if ($null -ne $selectedChannel) {
                        Save-ChannelToState -SelectedChannel $selectedChannel
                        $Channel = $selectedChannel
                        Write-Log ('启动菜单选择更新通道: {0}' -f $selectedChannel)
                    }
                }
            } else {
                Write-Log ('启动菜单已跳过，继续使用引擎 {0} ({1})。' -f $savedEngine, $script:GameLaunchArgs)
            }
        } catch {
            Write-Log ('启动菜单失败，继续默认流程: ' + $_.Exception.Message) WARN
        }
    } else {
        Write-Log ('跳过启动菜单，使用引擎 {0} ({1})。' -f $savedEngine, $script:GameLaunchArgs)
    }

    if ($channelWasExplicit) {
        $normalizedChannel = ConvertTo-ChannelName $Channel
        if ($null -eq $normalizedChannel) { $normalizedChannel = 'Stable' }
        $Channel = $normalizedChannel
        Save-ChannelToState -SelectedChannel $Channel
    } else {
        $stateAfterMenu = Read-InstallState
        $savedChannel = $null
        if ($null -ne $stateAfterMenu) {
            $savedChannel = ConvertTo-ChannelName ([string]$stateAfterMenu.channel)
        }
        if ($null -ne $savedChannel) {
            $Channel = $savedChannel
        } else {
            $Channel = 'Stable'
            Save-ChannelToState -SelectedChannel $Channel
        }
    }
    $script:UiState.Channel = $Channel
    Write-Log ('本次更新通道: {0}' -f $Channel)

    if (-not $NoGui) {
        $screen = Get-EligibleScreen -Index $MonitorIndex
        if ($null -ne $screen) {
            $script:UiState.Channel = $Channel
            $guiStarted = Start-UpdaterGui -Screen $screen
        } else {
            Write-Log '没有找到竖屏 16:9 显示器，使用命令行模式。'
        }
    }

    if (-not $guiStarted) {
        $script:UseGui = $false
        Write-Host ''
        Write-Host '  MajdataPlay Updater' -ForegroundColor Magenta
        Write-Host ('  通道: {0}    安装目录: {1}' -f $Channel, $script:InstallPath) -ForegroundColor DarkGray
        Write-Host ''
    }

    Set-UiStatus -Phase '检查更新' -Message ('正在获取最新 {0} 版本...' -f $Channel.ToLowerInvariant()) -Progress 4
    $release = Get-ReleaseInfo -Routes $routes -RequestedChannel $Channel
    $script:UiState.Version = $release.Version
    $releaseDisplaySize = if ($release.Size -gt 0) { $release.Size } elseif ($release.ApproxSize -gt 0) { $release.ApproxSize } else { [long]0 }
    Write-Log ('远程版本: {0} (tag {1}, commit {2}, 资源 {3}, {4})' -f $release.Version, $release.Tag, $release.Commit, $release.AssetName, (Format-Size $releaseDisplaySize))

    $localVersion = Get-LocalVersion
    $state = Read-InstallState
    if ($null -ne $localVersion) {
        Write-Log ('本地版本: {0} (来源 {1})' -f $localVersion.Raw, $localVersion.Source)
        Set-UiDetail ('本地 {0}  →  远程 {1}' -f $localVersion.Raw, $release.Version)
    } else {
        Write-Log '未检测到本地版本。'
        Set-UiDetail ('本地未安装  →  远程 {0}' -f $release.Version)
    }

    $decision = Get-UpdateDecision -Release $release -LocalVersion $localVersion -State $state
    Write-Log ('更新判断: {0} ({1})' -f $decision.Update, $decision.Reason)
    Test-Cancellation

    if ($CheckOnly) {
        if ($decision.Update) {
            Set-FinalState -Success $true -Phase '发现新版本' -Message $decision.Reason -Detail ('远程 {0}，资源 {1}' -f $release.Version, $release.AssetName) -Hint '按 Esc 退出'
        } else {
            Set-FinalState -Success $true -Phase '已是最新版本' -Message $decision.Reason -Detail ('远程 {0}' -f $release.Version) -Hint '按 Esc 退出'
        }
        if ($script:UseGui) {
            Wait-WithTimeout -Condition { $script:UiState.CloseRequested -or $script:UiState.GuiClosed } -TimeoutMs 5000 | Out-Null
            Complete-Gui -DelayMs 0
        }
        $exitCode = 0
    } elseif (-not $decision.Update) {
        $finalHint = if ($NoLaunch) { '按 Esc 退出' } else { '即将启动游戏' }
        Set-FinalState -Success $true -Phase '已是最新版本' -Message $decision.Reason -Detail ('当前 {0}' -f $release.Version) -Hint $finalHint
        if ($script:UseGui) { Complete-Gui -DelayMs 1800 }
        if (-not $NoLaunch) { Start-Game }
        $exitCode = 0
    } else {
        if ((Test-GameRunning) -and (-not $StopRunningGame)) {
            throw 'MajdataPlay 正在运行。请先关闭游戏，或使用 -StopRunningGame 让更新器关闭它。'
        }

        $assetName = [System.IO.Path]::GetFileName($release.AssetName)
        if ([string]::IsNullOrWhiteSpace($assetName)) { $assetName = 'MajdataPlay.zip' }
        $cacheKey = if ($release.Commit) { $release.Commit.Substring(0, [Math]::Min(7, $release.Commit.Length)) } else { $release.Tag }
        $cacheKey = ([string]$cacheKey) -replace '[^0-9A-Za-z._-]', '_'
        $tagKey = ([string]$release.Tag) -replace '[^0-9A-Za-z._-]', '_'
        $script:DownloadPath = Join-Path $downloadDir ('{0}-{1}-{2}' -f $tagKey, $cacheKey, $assetName)
        $spaceSize = if ($release.Size -gt 0) { $release.Size } else { $release.ApproxSize }
        Assert-DiskSpace -WorkPath $script:WorkRoot -AssetSize $spaceSize

        Set-UiStatus -Phase '下载更新' -Message ('正在下载 {0}...' -f $assetName) -Progress 8 -Detail ('远程版本 {0}' -f $release.Version)
        $download = Invoke-UpdateDownload -Release $release -Routes $routes -Destination $script:DownloadPath
        Write-Log ('下载完成: {0} ({1})' -f $download, (Format-Size (Get-Item -LiteralPath $download).Length))

        $staging = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))
        Set-UiStatus -Phase '解压更新' -Message '正在解压更新包...' -Progress 72
        Expand-UpdatePackage -ZipPath $download -Destination $staging

        # The ZIP is no longer needed once extraction has completed; remove it
        # immediately so the MajdataPlay download folder stays clean.
        try {
            if (Test-Path -LiteralPath $download -PathType Leaf) {
                Remove-Item -LiteralPath $download -Force
                Write-Log ('已删除下载包: {0}' -f $download)
            }
        } catch {
            Write-Log ('删除下载包失败（安装继续）: ' + $_.Exception.Message) WARN
        }

        $packageRoot = Find-PackageRoot -StagePath $staging
        Write-Log ('更新包根目录: {0}' -f $packageRoot)

        if (Test-GameRunning) { Stop-GameIfRequested }
        Set-UiStatus -Phase '安装更新' -Message '正在安装文件...' -Progress 90
        $stats = Install-UpdatePackage -PackageRoot $packageRoot
        Write-Log ('安装完成: 复制 {0}，StreamingAssets 跳过 {1}，调试文件跳过 {2}，共 {3}' -f $stats.Copied, $stats.SkippedStreaming, $stats.SkippedDebug, $stats.Total)
        if ($stats.SkippedStreaming -gt 0) {
            Write-Log ('已保留 {0} 个已有的 StreamingAssets 文件。使用 -OverwriteStreamingAssets 可强制覆盖。' -f $stats.SkippedStreaming)
        }

        try {
            Save-InstallState -Release $release
        } catch {
            Write-Log ('写入更新状态失败（不影响游戏运行）: ' + $_.Exception.Message) WARN
        }

        $detail = '已更新到 {0}' -f $release.Version
        if ($stats.SkippedStreaming -gt 0) { $detail += ('，保留 {0} 个 StreamingAssets 文件' -f $stats.SkippedStreaming) }
        $finalHint = if ($NoLaunch) { '按 Esc 退出' } else { '即将启动游戏' }
        Set-FinalState -Success $true -Phase '更新完成' -Message ('MajdataPlay 已更新到 {0}。' -f $release.Version) -Detail $detail -Hint $finalHint
        Write-Log '更新完成，准备启动游戏。'
        if ($script:UseGui) { Complete-Gui -DelayMs 1500 }
        Start-Game
        $exitCode = 0
    }
} catch {
    $message = $_.Exception.Message
    if ($_.Exception -is [System.OperationCanceledException]) {
        $message = '更新已取消。'
        Write-Log $message WARN
        Set-FinalState -Success $false -Phase '已取消' -Message $message -Detail '未修改游戏文件。' -Hint '按 Esc 退出'
    } else {
        Write-Log ('更新失败: ' + $_.Exception.ToString()) ERROR
        Set-FinalState -Success $false -Phase '更新失败' -Message $message -Detail '请查看日志了解详细原因。' -Hint '按 Esc 退出'
    }
    if ($script:UseGui) {
        Wait-GuiErrorDismiss
    } elseif ($script:LogFile) {
        Write-Host ('日志: ' + $script:LogFile) -ForegroundColor DarkGray
    }
    $exitCode = 1
} finally {
    try {
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    if ($script:UseGui) { Stop-UpdaterGui -Force }
}

exit $exitCode
