#Requires -Version 5.1
<#
.SYNOPSIS
    OpenCode GO Usage — индикатор лимитов подписки OpenCode GO в системном трее Windows.

.DESCRIPTION
    Windows-аналог апплета Cinnamon clrblind/opencode-go-usage и плагина Noctalia
    zumik3-del/opencode-go-usage.

    Основной режим — официальный API консоли:
        GET https://opencode.ai/console/api/go/status
        Authorization: Bearer oc_sk_...
    Ответ (JSON): access.meters.{fiveHour,week,month} с usedMicroCents,
    limitMicroCents и resetsAt, плюс access.endsAt для месячного лимита.

    Резервный режим — как в оригинальном апплете: разбор HTML страницы
    https://opencode.ai/workspace/<wrk_...>/go с cookie auth.

    Показывает 5-часовой, недельный и месячный лимиты, время до сброса
    и уведомляет, когда лимит обнулился.

.PARAMETER Once
    Один запрос, вывод результата в консоль и выход. Удобно для проверки настроек.

.PARAMETER SelfTest
    Проверка разбора на встроенном образце ответа API, без сети.

.PARAMETER InstallAutostart
    Добавить приложение в автозапуск Windows и выйти.

.PARAMETER RemoveAutostart
    Убрать приложение из автозапуска Windows и выйти.

.PARAMETER ConfigPath
    Путь к config.json. По умолчанию — рядом со скриптом.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\GoUsage.ps1 -Once
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$SelfTest,
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$script:Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath -or $ConfigPath.Trim() -eq '') { $ConfigPath = Join-Path $script:Here 'config.json' }

$script:AppName         = 'OpenCode GO Usage'
$script:ApiUrl          = 'https://opencode.ai/console/api/go/status'
$script:IconFile        = Join-Path $script:Here 'icon.png'
$script:LogFile         = Join-Path $script:Here 'go-usage.log'
$script:ShortcutName    = 'OpenCode GO Usage.lnk'
$script:UserAgent       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

$script:LimitDefaults = @{
    api    = @{ Min = 60; Max = 86400; Default = 300 }
    cookie = @{ Min = 5;  Max = 3600;  Default = 30 }
}

# --------------------------------------------------------------------------
# Служебное
# --------------------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        if ((Get-Item -LiteralPath $script:LogFile).Length -gt 262144) {
            $tail = Get-Content -LiteralPath $script:LogFile -Tail 300
            Set-Content -LiteralPath $script:LogFile -Value $tail -Encoding UTF8
        }
    } catch { }
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Не найден файл настроек: $ConfigPath"
    }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Файл config.json пуст.' }

    $cfg = $raw | ConvertFrom-Json

    $apiKey = ([string]$cfg.api_key).Trim()
    $ws     = ([string]$cfg.workspace_id).Trim()
    $cookie = ([string]$cfg.auth_cookie).Trim()
    if ($cookie -match '^(?i)auth=') { $cookie = $cookie.Substring(5) }

    $mode = $null
    if ($apiKey -ne '') {
        if ($apiKey -notmatch '^oc_sk_') {
            throw 'api_key должен начинаться с oc_sk_ — скопируйте ключ из консоли OpenCode (console -> API keys).'
        }
        $mode = 'api'
    } elseif ($ws -ne '' -and $cookie -ne '') {
        if ($ws -notmatch '^wrk_') {
            throw 'workspace_id должен начинаться с wrk_ — скопируйте его из адресной строки после входа на opencode.ai/auth.'
        }
        if ($cookie.Length -lt 20) {
            throw 'auth_cookie слишком короткий — скопируйте значение cookie auth целиком (F12 -> Application -> Cookies -> opencode.ai).'
        }
        $mode = 'cookie'
    } else {
        throw 'Заполните api_key (oc_sk_...) либо пару workspace_id (wrk_...) + auth_cookie в config.json.'
    }

    $limits = $script:LimitDefaults[$mode]
    $interval = $limits.Default
    if ($null -ne $cfg.update_interval) {
        try { $interval = [int]$cfg.update_interval } catch { $interval = $limits.Default }
    }
    if ($interval -lt $limits.Min -or $interval -gt $limits.Max) { $interval = $limits.Default }

    $notify = $true
    if ($null -ne $cfg.show_notifications) { $notify = [bool]$cfg.show_notifications }

    return [pscustomobject]@{
        mode               = $mode
        api_key            = $apiKey
        workspace_id       = $ws
        auth_cookie        = $cookie
        update_interval    = $interval
        show_notifications = $notify
    }
}

function Save-ConfigValue {
    param([string]$Name, $Value)
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains $Name) { $cfg.$Name = $Value }
        else { $cfg | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
        $json = $cfg | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Log "Не удалось сохранить настройку ${Name}: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
# Разбор ответов
# --------------------------------------------------------------------------

function Format-ResetCountdown {
    param([string]$Iso)

    if ([string]::IsNullOrWhiteSpace($Iso)) { return '' }
    $moment = $null
    try {
        $moment = [System.DateTimeOffset]::Parse($Iso.Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return ''
    }

    $diff = $moment.LocalDateTime - (Get-Date)
    if ($diff.TotalSeconds -le 0) { return 'сейчас' }

    $days = [int][math]::Floor($diff.TotalDays)
    $hours = $diff.Hours
    $minutes = $diff.Minutes

    if ($days -ge 1) { return ('{0} д {1} ч' -f $days, $hours) }
    if ($hours -ge 1) { return ('{0} ч {1} мин' -f $hours, $minutes) }
    return ('{0} мин' -f $minutes)
}

function New-UsageItem {
    param([string]$Label, [string]$Short, [int]$Percent, [string]$Reset)
    return [pscustomobject]@{
        Label   = $Label
        Short   = $Short
        Percent = $Percent
        Reset   = $Reset
    }
}

function Convert-UsageJson {
    param([string]$Json)

    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Json)) { return $items }

    $data = $Json | ConvertFrom-Json
    $access = $data.access
    if (-not $access -or -not $access.meters) { return $items }

    $meters = $access.meters

    $defs = @(
        @{ Meter = $meters.fiveHour; Label = '5 часов'; Short = '5ч';  Reset = $(if ($meters.fiveHour) { $meters.fiveHour.resetsAt }) },
        @{ Meter = $meters.week;     Label = 'Неделя';  Short = 'Нед'; Reset = $(if ($meters.week) { $meters.week.resetsAt }) },
        @{ Meter = $meters.month;    Label = 'Месяц';   Short = 'Мес'; Reset = $access.endsAt }
    )

    foreach ($def in $defs) {
        $meter = $def.Meter
        if (-not $meter) { continue }
        $limit = 0.0
        $used = 0.0
        try { $limit = [double]$meter.limitMicroCents } catch { }
        try { $used = [double]$meter.usedMicroCents } catch { }
        if ($limit -le 0) { continue }

        $percent = [int][math]::Round(($used / $limit) * 100, 0, [System.MidpointRounding]::AwayFromZero)
        if ($percent -lt 0) { $percent = 0 }
        if ($percent -gt 100) { $percent = 100 }

        [void]$items.Add((New-UsageItem -Label $def.Label -Short $def.Short -Percent $percent -Reset (Format-ResetCountdown -Iso ([string]$def.Reset))))
    }

    return $items
}

function Convert-UsageHtml {
    param([string]$Html)

    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Html)) { return $items }

    # Вся страница в одну строку — как в оригинальном апплете.
    $flat = $Html -replace "`r?`n", ''
    $pattern = '(?s)usage-label">([^<]+).*?usage-value"><!--\$-->([0-9]+).*?Resets in<!--/--> <!--\$-->([^<]+)'
    $rx = [regex]$pattern

    foreach ($chunk in ($flat -split '<div[^>]+data-slot="usage-item"')) {
        $m = $rx.Match($chunk)
        if ($m.Success) {
            $label = $m.Groups[1].Value.Trim()
            $pct = 0
            [void][int]::TryParse($m.Groups[2].Value, [ref]$pct)
            if ($pct -lt 0 -or $pct -gt 100) { continue }
            $short = ($label -split '\s+')[0]
            [void]$items.Add((New-UsageItem -Label $label -Short $short -Percent $pct -Reset $m.Groups[3].Value.Trim()))
        }
    }
    return $items
}

function Format-UsageLine {
    param($Item)
    $line = '{0} | {1,3}%' -f $Item.Label.PadRight(10), $Item.Percent
    if ($Item.Reset) { $line += ' | сброс через ' + $Item.Reset }
    return $line
}

function Get-ShortTooltip {
    param($Items)
    $parts = foreach ($i in $Items) { '{0} {1}%' -f $i.Short, $i.Percent }
    $text = $script:AppName
    if ($parts) { $text = ($parts -join ' · ') }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    return $text
}

# --------------------------------------------------------------------------
# Сетевой запрос и его разбор
# --------------------------------------------------------------------------

function Get-PageUri {
    param([string]$WorkspaceId)
    return 'https://opencode.ai/workspace/{0}/go' -f $WorkspaceId
}

function Invoke-CollectSync {
    param($Config)

    $headers = @{ 'User-Agent' = $script:UserAgent }

    try {
        if ($Config.mode -eq 'api') {
            $headers['Authorization'] = 'Bearer ' + $Config.api_key
            $headers['Accept'] = 'application/json'
            $response = Invoke-WebRequest -Uri $script:ApiUrl -Headers $headers -UseBasicParsing -TimeoutSec 20
            $items = Convert-UsageJson -Json ([string]$response.Content)
            if ($items.Count -eq 0) {
                return @{ ok = $false; items = @(); error = 'В ответе API нет данных о лимитах.' }
            }
            return @{ ok = $true; items = @($items); error = $null }
        }

        $headers['Cookie'] = 'auth=' + $Config.auth_cookie
        $headers['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        $response = Invoke-WebRequest -Uri (Get-PageUri -WorkspaceId $Config.workspace_id) -Headers $headers -UseBasicParsing -TimeoutSec 20
        $html = [string]$response.Content
        $items = Convert-UsageHtml -Html $html
        if ($items.Count -eq 0) {
            $hint = 'Не удалось разобрать страницу. Скорее всего истёк cookie auth — обновите его или перейдите на api_key.'
            return @{ ok = $false; items = @(); error = $hint }
        }
        return @{ ok = $true; items = @($items); error = $null }
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        return @{ ok = $false; items = @(); error = (Get-HttpErrorMessage -Status $status -Message $_.Exception.Message) }
    }
}

function Get-HttpErrorMessage {
    param([int]$Status, [string]$Message)

    switch ($Status) {
        401 { return 'Ключ не принят (401). Проверьте api_key — он должен быть вида oc_sk_... и не отозван.' }
        403 { return 'Доступ запрещён (403). Возможно, у ключа нет прав на GO-статистику.' }
        404 { return 'API вернул 404. Возможно, у аккаунта другая адресация — попробуйте режим workspace_id + auth_cookie.' }
        429 { return 'Слишком частые запросы (429). Увеличьте update_interval в config.json.' }
    }
    if ($Status -gt 0) { return ('HTTP {0}: {1}' -f $Status, $Message) }
    return ('Ошибка сети: ' + $Message)
}

# --------------------------------------------------------------------------
# Автозапуск
# --------------------------------------------------------------------------

function Get-StartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) $script:ShortcutName)
}

function Test-Autostart {
    return (Test-Path -LiteralPath (Get-StartupShortcutPath))
}

function Set-Autostart {
    param([bool]$Enable)

    $link = Get-StartupShortcutPath
    if (-not $Enable) {
        if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        Write-Log 'Автозапуск отключён.'
        return
    }

    $vbs = Join-Path $script:Here 'GoUsage.vbs'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    if (Test-Path -LiteralPath $vbs) {
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $shortcut.Arguments = '"{0}"' -f $vbs
    } else {
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $script:Here 'GoUsage.ps1')
    }
    $shortcut.WorkingDirectory = $script:Here
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Мониторинг лимитов OpenCode GO'
    $shortcut.Save()
    Write-Log "Автозапуск включён: $link"
}

# --------------------------------------------------------------------------
# Иконка
# --------------------------------------------------------------------------

function Get-TrayIcon {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:IconFile) {
        try {
            $bitmap = [System.Drawing.Bitmap]::FromFile($script:IconFile)
            $script:iconHandle = $bitmap.GetHicon()
            $icon = [System.Drawing.Icon]::FromHandle($script:iconHandle)
            $bitmap.Dispose()
            return $icon
        } catch {
            Write-Log "Не удалось загрузить icon.png: $($_.Exception.Message)"
        }
    }
    return [System.Drawing.SystemIcons]::Application
}

# --------------------------------------------------------------------------
# Режим -Once и -SelfTest
# --------------------------------------------------------------------------

function Invoke-OnceMode {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

    try {
        $cfg = Read-Config
    } catch {
        Write-Host ('ОШИБКА НАСТРОЕК: ' + $_.Exception.Message) -ForegroundColor Red
        return 1
    }

    Write-Host ('Режим:     ' + $cfg.mode)
    if ($cfg.mode -eq 'api') {
        Write-Host ('URL:       ' + $script:ApiUrl)
        Write-Host ('Ключ:      ' + $cfg.api_key.Substring(0, [math]::Min(10, $cfg.api_key.Length)) + '...')
    } else {
        Write-Host ('URL:       ' + (Get-PageUri -WorkspaceId $cfg.workspace_id))
        Write-Host ('Workspace: ' + $cfg.workspace_id)
    }
    Write-Host ''

    $result = Invoke-CollectSync -Config $cfg
    if (-not $result.ok) {
        Write-Host ('ОШИБКА: ' + $result.error) -ForegroundColor Red
        return 2
    }

    foreach ($item in $result.items) { Write-Host (Format-UsageLine -Item $item) }
    return 0
}

function Invoke-SelfTest {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

    $now = (Get-Date).ToUniversalTime()
    $sample = @{
        access = @{
            endsAt             = $now.AddDays(3).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            cancelAtPeriodEnd  = $false
            meters             = @{
                fiveHour = @{ usedMicroCents = 3400000000; limitMicroCents = 10000000000; resetsAt = $now.AddHours(2).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
                week     = @{ usedMicroCents = 10000000000; limitMicroCents = 10000000000; resetsAt = $now.AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
                month    = @{ usedMicroCents = 6300000000; limitMicroCents = 10000000000; resetsAt = $now.AddDays(3).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
            }
        }
    } | ConvertTo-Json -Depth 8

    $items = Convert-UsageJson -Json $sample
    if ($items.Count -ne 3) {
        Write-Host ('ПРОВАЛ: ожидалось 3 строки, получено ' + $items.Count) -ForegroundColor Red
        return 1
    }

    $expected = @(34, 100, 63)
    $ok = $true
    for ($i = 0; $i -lt 3; $i++) {
        Write-Host (Format-UsageLine -Item $items[$i])
        if ($items[$i].Percent -ne $expected[$i]) {
            Write-Host ('  ОЖИДАЛОСЬ {0}%, ПОЛУЧЕНО {1}%' -f $expected[$i], $items[$i].Percent) -ForegroundColor Red
            $ok = $false
        }
    }

    if ($ok) { Write-Host 'Разбор JSON работает.' -ForegroundColor Green; return 0 }
    return 1
}

# --------------------------------------------------------------------------
# Фоновое обновление (без блокировки интерфейса)
# --------------------------------------------------------------------------

$script:fetchPowerShell = $null
$script:fetchAsync      = $null
$script:lastItems       = @()
$script:lastError       = $null
$script:prevPercents    = @{}
$script:notifiedReset   = @{}
$script:cfg             = $null
$script:miUsage         = @()
$script:notify          = $null
$script:menu            = $null
$script:timerFetch      = $null
$script:timerPoll       = $null

function Start-Fetch {
    if ($script:fetchAsync -and -not $script:fetchAsync.IsCompleted) { return }
    if (-not $script:cfg) { return }

    $mode     = $script:cfg.mode
    $apiUrl   = $script:ApiUrl
    $pageUrl  = Get-PageUri -WorkspaceId $script:cfg.workspace_id
    $apiKey   = $script:cfg.api_key
    $cookie   = $script:cfg.auth_cookie
    $agent    = $script:UserAgent

    $script:fetchPowerShell = [powershell]::Create()
    [void]$script:fetchPowerShell.AddScript({
        param($Mode, $ApiUrl, $PageUrl, $ApiKey, $Cookie, $Agent)
        $headers = @{ 'User-Agent' = $Agent }
        try {
            if ($Mode -eq 'api') {
                $headers['Authorization'] = 'Bearer ' + $ApiKey
                $headers['Accept'] = 'application/json'
                $r = Invoke-WebRequest -Uri $ApiUrl -Headers $headers -UseBasicParsing -TimeoutSec 20
                [pscustomobject]@{ ok = $true; body = [string]$r.Content; error = ''; status = 0 }
            } else {
                $headers['Cookie'] = 'auth=' + $Cookie
                $headers['Accept'] = 'text/html,application/xhtml+xml'
                $r = Invoke-WebRequest -Uri $PageUrl -Headers $headers -UseBasicParsing -TimeoutSec 20
                [pscustomobject]@{ ok = $true; body = [string]$r.Content; error = ''; status = 0 }
            }
        } catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            [pscustomobject]@{ ok = $false; body = ''; error = $_.Exception.Message; status = $status }
        }
    }).AddArgument($mode).AddArgument($apiUrl).AddArgument($pageUrl).AddArgument($apiKey).AddArgument($cookie).AddArgument($agent)

    try {
        $script:fetchAsync = $script:fetchPowerShell.BeginInvoke()
    } catch {
        Write-Log "Не удалось запустить фоновый запрос: $($_.Exception.Message)"
        $script:lastError = $_.Exception.Message
        Update-Ui
    }
}

function Complete-Fetch {
    if (-not $script:fetchAsync -or -not $script:fetchAsync.IsCompleted) { return }

    $result = $null
    try {
        $output = $script:fetchPowerShell.EndInvoke($script:fetchAsync)
        if ($output -and $output.Count -gt 0) { $result = $output[0] }
    } catch {
        $result = [pscustomobject]@{ ok = $false; body = ''; error = $_.Exception.Message; status = 0 }
    } finally {
        if ($script:fetchPowerShell) { $script:fetchPowerShell.Dispose() }
        $script:fetchPowerShell = $null
        $script:fetchAsync = $null
    }

    if (-not $result) { return }

    if (-not $result.ok) {
        $script:lastError = Get-HttpErrorMessage -Status ([int]$result.status) -Message ([string]$result.error)
        Write-Log $script:lastError
        Update-Ui
        return
    }

    $items = $null
    try {
        if ($script:cfg -and $script:cfg.mode -eq 'api') { $items = Convert-UsageJson -Json ([string]$result.body) }
        else { $items = Convert-UsageHtml -Html ([string]$result.body) }
    } catch {
        $script:lastError = 'Не удалось разобрать ответ: ' + $_.Exception.Message
        Write-Log $script:lastError
        Update-Ui
        return
    }

    if (-not $items -or $items.Count -eq 0) {
        $script:lastItems = @()
        $script:lastError = if ($script:cfg -and $script:cfg.mode -eq 'api') {
            'В ответе API нет данных о лимитах. Проверьте, активна ли подписка GO.'
        } else {
            'Не удалось разобрать страницу. Скорее всего истёк cookie auth.'
        }
        Write-Log $script:lastError
        Update-Ui
        return
    }

    $script:lastItems = @($items)
    $script:lastError = $null
    Check-Resets -Items $script:lastItems
    Update-Ui
}

function Check-Resets {
    param($Items)

    foreach ($item in $Items) {
        $prev = $script:prevPercents[$item.Label]
        $script:prevPercents[$item.Label] = $item.Percent

        if ($item.Percent -eq 0 -and $null -ne $prev -and $prev -gt 0 -and -not $script:notifiedReset[$item.Label]) {
            $script:notifiedReset[$item.Label] = $true
            if ($script:cfg -and $script:cfg.show_notifications -and $script:notify) {
                $script:notify.ShowBalloonTip(6000, 'Лимит сброшен',
                    ('{0}: 0% (было {1}%)' -f $item.Label, $prev),
                    [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
        if ($item.Percent -gt 0) { $script:notifiedReset.Remove($item.Label) }
    }
}

function Update-Ui {
    if (-not $script:notify) { return }

    if ($script:lastError) {
        $script:notify.Text = ('{0}: нет данных' -f $script:AppName)
        if ($script:miUsage.Count -gt 0) {
            $script:miUsage[0].Text = $script:lastError
            $script:miUsage[0].Visible = $true
            for ($i = 1; $i -lt $script:miUsage.Count; $i++) { $script:miUsage[$i].Visible = $false }
        }
        return
    }

    $items = @($script:lastItems)
    for ($i = 0; $i -lt $script:miUsage.Count; $i++) {
        if ($i -lt $items.Count) {
            $script:miUsage[$i].Text = Format-UsageLine -Item $items[$i]
            $script:miUsage[$i].Visible = $true
        } else {
            $script:miUsage[$i].Visible = $false
        }
    }

    $script:notify.Text = Get-ShortTooltip -Items $items
}

# --------------------------------------------------------------------------
# Интерфейс
# --------------------------------------------------------------------------

function Show-UsageBalloon {
    if (-not $script:notify) { return }

    if ($script:lastError) {
        $script:notify.ShowBalloonTip(5000, $script:AppName, $script:lastError, [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    if ($script:lastItems.Count -eq 0) {
        $script:notify.ShowBalloonTip(3000, $script:AppName, 'Данных пока нет.', [System.Windows.Forms.ToolTipIcon]::None)
        return
    }

    $text = ($script:lastItems | ForEach-Object { Format-UsageLine -Item $_ }) -join [Environment]::NewLine
    $script:notify.ShowBalloonTip(6000, 'Лимиты OpenCode GO', $text, [System.Windows.Forms.ToolTipIcon]::Info)
}

function Build-Menu {
    $script:menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:miUsage = @()

    for ($i = 0; $i -lt 3; $i++) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = '—'
        $mi.Enabled = $false
        $mi.Visible = $false
        $script:miUsage += $mi
        [void]$script:menu.Items.Add($mi)
    }

    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miRefresh = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRefresh.Text = 'Обновить сейчас'
    $miRefresh.Add_Click({ Start-Fetch })
    [void]$script:menu.Items.Add($miRefresh)

    $miBrowser = New-Object System.Windows.Forms.ToolStripMenuItem
    $miBrowser.Text = 'Открыть лимиты в браузере'
    $miBrowser.Add_Click({
        $target = 'https://opencode.ai/'
        if ($script:cfg) {
            if ($script:cfg.mode -eq 'cookie' -and $script:cfg.workspace_id) {
                $target = Get-PageUri -WorkspaceId $script:cfg.workspace_id
            }
        }
        try { Start-Process $target } catch { Write-Log $_.Exception.Message }
    })
    [void]$script:menu.Items.Add($miBrowser)

    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miNotify = New-Object System.Windows.Forms.ToolStripMenuItem
    $miNotify.Text = 'Уведомлять о сбросе лимита'
    $miNotify.CheckOnClick = $true
    if ($script:cfg) { $miNotify.Checked = [bool]$script:cfg.show_notifications }
    $miNotify.Add_Click({
        if (-not $script:cfg) { return }
        $script:cfg.show_notifications = [bool]$miNotify.Checked
        Save-ConfigValue -Name 'show_notifications' -Value ([bool]$miNotify.Checked)
    })
    [void]$script:menu.Items.Add($miNotify)

    $miAutostart = New-Object System.Windows.Forms.ToolStripMenuItem
    $miAutostart.Text = 'Запускать при входе в Windows'
    $miAutostart.CheckOnClick = $true
    $miAutostart.Checked = Test-Autostart
    $miAutostart.Add_Click({
        try { Set-Autostart -Enable ([bool]$miAutostart.Checked) }
        catch { Write-Log "Ошибка автозапуска: $($_.Exception.Message)" }
    })
    [void]$script:menu.Items.Add($miAutostart)

    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $miExit.Text = 'Выход'
    $miExit.Add_Click({
        if ($script:notify) { $script:notify.Visible = $false }
        [System.Windows.Forms.Application]::Exit()
    })
    [void]$script:menu.Items.Add($miExit)
}

function Start-Tray {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    try {
        $script:cfg = Read-Config
        $script:lastError = $null
    } catch {
        $script:cfg = $null
        $script:lastError = $_.Exception.Message
        Write-Log ('Настройки: ' + $script:lastError)
    }

    Build-Menu

    $script:notify = New-Object System.Windows.Forms.NotifyIcon
    $script:notify.Icon = Get-TrayIcon
    $script:notify.Text = $script:AppName
    $script:notify.ContextMenuStrip = $script:menu
    $script:notify.Visible = $true
    $script:notify.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Show-UsageBalloon
        } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            $script:menu.Show([System.Windows.Forms.Cursor]::Position)
        }
    })

    Update-Ui

    if ($script:cfg) {
        $script:timerFetch = New-Object System.Windows.Forms.Timer
        $script:timerFetch.Interval = [int]$script:cfg.update_interval * 1000
        $script:timerFetch.Add_Tick({ Start-Fetch })
        $script:timerFetch.Start()

        $script:timerPoll = New-Object System.Windows.Forms.Timer
        $script:timerPoll.Interval = 300
        $script:timerPoll.Add_Tick({ Complete-Fetch })
        $script:timerPoll.Start()

        Start-Fetch
        Write-Log ('Запуск в режиме {0}, опрос каждые {1} с.' -f $script:cfg.mode, $script:cfg.update_interval)
    } else {
        Write-Log 'Запуск без настроек — показываю ошибку в меню.'
    }

    [System.Windows.Forms.Application]::Run()
}

# --------------------------------------------------------------------------
# Точка входа
# --------------------------------------------------------------------------

if ($InstallAutostart -and $RemoveAutostart) {
    Write-Host 'Укажите только один параметр: -InstallAutostart или -RemoveAutostart.' -ForegroundColor Red
    exit 1
}

if ($InstallAutostart) {
    Set-Autostart -Enable $true
    Write-Host ('Автозапуск включён: ' + (Get-StartupShortcutPath))
    exit 0
}

if ($RemoveAutostart) {
    Set-Autostart -Enable $false
    Write-Host 'Автозапуск отключён.'
    exit 0
}

if ($SelfTest) { exit (Invoke-SelfTest) }
if ($Once) { exit (Invoke-OnceMode) }

Start-Tray
