param(
  [string]$FeishuWebhookUrl = "",
  [string]$FeishuWebhookSecret = "",
  [ValidateSet("webhook", "app")]
  [string]$FeishuMode = "webhook",
  [string]$FeishuAppId = "",
  [string]$FeishuAppSecret = "",
  [string]$FeishuReceiverId = "",
  [string]$FeishuReceiverType = "open_id",
  [switch]$SkipClaude,
  [switch]$SkipCodex,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $Root "state"
$ConfigPath = Join-Path $Root "config.json"
$ExampleConfigPath = Join-Path $Root "config.example.json"
$NotifyPath = Join-Path $Root "notify.mjs"

function Write-Step($Message) {
  Write-Host "[agent-notify] $Message"
}

function Backup-File($Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backup = "$Path.agent-notify.$stamp.bak"
  if (-not $DryRun) {
    Copy-Item -LiteralPath $Path -Destination $backup -Force
  }
  Write-Step "Backup created: $Path -> $backup"
}

function Ensure-Property($Object, $Name, $Value) {
  if (-not $Object.PSObject.Properties[$Name]) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Save-Json($Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 100
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
  }
}

function Ensure-AgentNotifyConfig {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    if (-not $DryRun) {
      New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    }
  }

  if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  } else {
    $config = Get-Content -LiteralPath $ExampleConfigPath -Raw | ConvertFrom-Json
  }

  Ensure-Property $config "feishu" ([pscustomobject]@{})
  Ensure-Property $config.feishu "enabled" $true
  Ensure-Property $config.feishu "mode" $FeishuMode
  Ensure-Property $config.feishu "webhookUrl" ""
  Ensure-Property $config.feishu "webhookSecret" ""
  Ensure-Property $config.feishu "appId" ""
  Ensure-Property $config.feishu "appSecret" ""
  Ensure-Property $config.feishu "receiverId" ""
  Ensure-Property $config.feishu "receiverType" "open_id"

  $config.feishu.mode = $FeishuMode
  if ($FeishuWebhookUrl) { $config.feishu.webhookUrl = $FeishuWebhookUrl }
  if ($FeishuWebhookSecret) { $config.feishu.webhookSecret = $FeishuWebhookSecret }
  if ($FeishuAppId) { $config.feishu.appId = $FeishuAppId }
  if ($FeishuAppSecret) { $config.feishu.appSecret = $FeishuAppSecret }
  if ($FeishuReceiverId) { $config.feishu.receiverId = $FeishuReceiverId }
  if ($FeishuReceiverType) { $config.feishu.receiverType = $FeishuReceiverType }

  Save-Json $ConfigPath $config
  Write-Step "Config ready: $ConfigPath"
}

function New-ClaudeHookEntry($EventName) {
  $command = "node `"$NotifyPath`" emit --agent claude --event $EventName"
  [pscustomobject]@{
    matcher = "*"
    hooks = @(
      [pscustomobject]@{
        type = "command"
        command = $command
        shell = "powershell"
        async = $true
        timeout = 5
      }
    )
  }
}

function Add-ClaudeHook($Settings, $EventName) {
  Ensure-Property $Settings "hooks" ([pscustomobject]@{})
  if (-not $Settings.hooks.PSObject.Properties[$EventName]) {
    $Settings.hooks | Add-Member -NotePropertyName $EventName -NotePropertyValue @()
  }

  $current = @($Settings.hooks.$EventName)
  $needle = "agent-notify"
  foreach ($entry in $current) {
    foreach ($hook in @($entry.hooks)) {
      if (($hook.command -as [string]) -like "*$needle*notify.mjs*--agent claude*--event $EventName*") {
        return
      }
    }
  }

  $Settings.hooks.$EventName = @($current + (New-ClaudeHookEntry $EventName))
}

function Install-ClaudeHooks {
  $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
  $settingsDir = Split-Path -Parent $settingsPath
  if (-not (Test-Path -LiteralPath $settingsDir)) {
    if (-not $DryRun) {
      New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    }
  }

  if (Test-Path -LiteralPath $settingsPath) {
    Backup-File $settingsPath
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  } else {
    $settings = [pscustomobject]@{
      '$schema' = "https://json.schemastore.org/claude-code-settings.json"
      hooks = [pscustomobject]@{}
    }
  }

  Add-ClaudeHook $settings "Stop"
  Add-ClaudeHook $settings "Notification"
  Add-ClaudeHook $settings "TaskCompleted"
  Save-Json $settingsPath $settings
  Write-Step "Claude Code hooks installed: $settingsPath"
}

function Escape-TomlString($Value) {
  ([string]$Value).Replace('\', '\\').Replace('"', '\"')
}

function To-TomlArray($Items) {
  $quoted = @($Items | ForEach-Object { '"' + (Escape-TomlString $_) + '"' })
  "[" + ($quoted -join ", ") + "]"
}

function Install-CodexNotify {
  $configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Codex config not found: $configPath"
  }

  Backup-File $configPath
  $raw = Get-Content -LiteralPath $configPath -Raw
  $newNotify = To-TomlArray @("node", $NotifyPath, "codex-notify")

  if ($raw -match '(?m)^\s*notify\s*=\s*(\[.*\])\s*$') {
    $currentArrayText = $Matches[1]
    if ($currentArrayText -like "*agent-notify*notify.mjs*") {
      Write-Step "Codex notify already points to agent-notify, skip"
      return
    }

    $original = $currentArrayText | ConvertFrom-Json
    $originalRecord = [pscustomobject]@{
      argv = @($original)
      originalLine = "notify = $currentArrayText"
      installedAt = (Get-Date).ToString("o")
    }
    if (-not $DryRun) {
      $originalJson = $originalRecord | ConvertTo-Json -Depth 10
      [System.IO.File]::WriteAllText((Join-Path $StateDir "codex-notify-original.json"), $originalJson, [System.Text.UTF8Encoding]::new($false))
    }
    $updated = [regex]::Replace($raw, '(?m)^\s*notify\s*=\s*\[.*\]\s*$', "notify = $newNotify", 1)
  } else {
    $updated = "notify = $newNotify`r`n" + $raw
  }

  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($configPath, $updated, [System.Text.UTF8Encoding]::new($false))
  }
  Write-Step "Codex notify fanout installed: $configPath"
}

if (-not (Test-Path -LiteralPath $NotifyPath)) {
  throw "notify.mjs not found: $NotifyPath"
}

Ensure-AgentNotifyConfig

if (-not $SkipClaude) {
  Install-ClaudeHooks
}

if (-not $SkipCodex) {
  Install-CodexNotify
}

Write-Step "Install complete. Run first: node `"$NotifyPath`" test --dry-run"
Write-Step "After Feishu config is ready, run: node `"$NotifyPath`" test"
