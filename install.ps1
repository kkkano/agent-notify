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
$OriginalCodexHooksPath = Join-Path $StateDir "codex-hooks-original.json"

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

  Ensure-Property $config "events" ([pscustomobject]@{})
  Ensure-Property $config.events "claude" ([pscustomobject]@{})
  Ensure-Property $config.events.claude "Stop" $true
  Ensure-Property $config.events.claude "Notification" $true
  Ensure-Property $config.events.claude "TaskCompleted" $false
  Ensure-Property $config.events.claude "SubagentStop" $false
  $config.events.claude.TaskCompleted = $false
  $config.events.claude.SubagentStop = $false

  Ensure-Property $config.events "codex" ([pscustomobject]@{})
  Ensure-Property $config.events.codex "notify" $true
  Ensure-Property $config.events.codex "Stop" $true
  Ensure-Property $config.events.codex "PermissionRequest" $true

  Ensure-Property $config "notifications" ([pscustomobject]@{})
  Ensure-Property $config.notifications "completion" $true
  Ensure-Property $config.notifications "actionRequired" $true
  Ensure-Property $config.notifications "stage" $false
  Ensure-Property $config.notifications "subagent" $false
  Ensure-Property $config.notifications "unknown" $false
  $config.notifications.completion = $true
  $config.notifications.actionRequired = $true
  $config.notifications.stage = $false
  $config.notifications.subagent = $false
  $config.notifications.unknown = $false

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

function Remove-ClaudeHook($Settings, $EventName) {
  if (-not $Settings.PSObject.Properties["hooks"]) { return }
  if (-not $Settings.hooks.PSObject.Properties[$EventName]) { return }

  $kept = @()
  foreach ($entry in @($Settings.hooks.$EventName)) {
    $hasAgentNotify = $false
    foreach ($hook in @($entry.hooks)) {
      if (($hook.command -as [string]) -like "*agent-notify*notify.mjs*--agent claude*--event $EventName*") {
        $hasAgentNotify = $true
      }
    }
    if (-not $hasAgentNotify) { $kept += $entry }
  }
  $Settings.hooks.$EventName = @($kept)
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
  Remove-ClaudeHook $settings "TaskCompleted"
  Remove-ClaudeHook $settings "SubagentStop"
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

function Remove-AgentNotifyCodexHookBlock($Raw) {
  [regex]::Replace($Raw, '(?ms)\r?\n?# BEGIN agent-notify codex hooks\r?\n.*?\r?\n# END agent-notify codex hooks\r?\n?', "`r`n")
}

function Set-CodexHooksFeature($Raw) {
  $featureMatch = [regex]::Match($Raw, '(?ms)^\[features\]\s*.*?(?=^\[|\z)')
  if ($featureMatch.Success) {
    $block = $featureMatch.Value
    if ($block -match '(?m)^\s*codex_hooks\s*=') {
      $newBlock = [regex]::Replace($block, '(?m)^\s*codex_hooks\s*=.*$', 'codex_hooks = true', 1)
    } else {
      $newBlock = $block.TrimEnd() + "`r`ncodex_hooks = true`r`n"
    }
    return $Raw.Substring(0, $featureMatch.Index) + $newBlock + $Raw.Substring($featureMatch.Index + $featureMatch.Length)
  }

  return $Raw.TrimEnd() + "`r`n`r`n[features]`r`ncodex_hooks = true`r`n"
}

function Save-CodexHooksOriginal($Raw) {
  if (Test-Path -LiteralPath $OriginalCodexHooksPath) { return }

  $line = $null
  $match = [regex]::Match($Raw, '(?m)^\s*codex_hooks\s*=.*$')
  if ($match.Success) { $line = $match.Value }

  $record = [pscustomobject]@{
    codexHooksLine = $line
    installedAt = (Get-Date).ToString("o")
  }
  if (-not $DryRun) {
    $json = $record | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($OriginalCodexHooksPath, $json, [System.Text.UTF8Encoding]::new($false))
  }
}

function Add-CodexHooks($Raw) {
  Save-CodexHooksOriginal $Raw
  $clean = Remove-AgentNotifyCodexHookBlock $Raw
  $withFeature = Set-CodexHooksFeature $clean
  $stopCommand = "node `"$NotifyPath`" emit --agent codex --event Stop"
  $permissionCommand = "node `"$NotifyPath`" emit --agent codex --event PermissionRequest"
  $hookBlock = @"

# BEGIN agent-notify codex hooks
[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "$(Escape-TomlString $stopCommand)"
timeout = 5

[[hooks.PermissionRequest]]
matcher = "*"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = "$(Escape-TomlString $permissionCommand)"
timeout = 5
# END agent-notify codex hooks
"@
  return $withFeature.TrimEnd() + "`r`n" + $hookBlock.TrimEnd() + "`r`n"
}

function Install-CodexNotify {
  $configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Codex config not found: $configPath"
  }

  Backup-File $configPath
  $raw = Get-Content -LiteralPath $configPath -Raw
  $newNotify = To-TomlArray @("node", $NotifyPath, "codex-notify")
  $updated = $raw

  if ($raw -match '(?m)^\s*notify\s*=\s*(\[.*\])\s*$') {
    $currentArrayText = $Matches[1]
    if ($currentArrayText -like "*agent-notify*notify.mjs*") {
      Write-Step "Codex notify already points to agent-notify"
    } else {
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
    }
  } else {
    $updated = "notify = $newNotify`r`n" + $raw
  }

  $updated = Add-CodexHooks $updated
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($configPath, $updated, [System.Text.UTF8Encoding]::new($false))
  }
  Write-Step "Codex notify fanout and hooks installed: $configPath"
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
