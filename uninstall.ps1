param(
  [switch]$SkipClaude,
  [switch]$SkipCodex,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $Root "state"
$OriginalCodexNotifyPath = Join-Path $StateDir "codex-notify-original.json"

function Write-Step($Message) {
  Write-Host "[agent-notify] $Message"
}

function Backup-File($Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backup = "$Path.agent-notify-uninstall.$stamp.bak"
  if (-not $DryRun) {
    Copy-Item -LiteralPath $Path -Destination $backup -Force
  }
  Write-Step "Backup created: $Path -> $backup"
}

function Save-Json($Path, $Object) {
  $json = $Object | ConvertTo-Json -Depth 100
  if (-not $DryRun) {
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
  }
}

function Remove-ClaudeHooks {
  $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
  if (-not (Test-Path -LiteralPath $settingsPath)) { return }

  Backup-File $settingsPath
  $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  if (-not $settings.PSObject.Properties["hooks"]) { return }

  foreach ($eventName in @("Stop", "Notification", "TaskCompleted")) {
    if (-not $settings.hooks.PSObject.Properties[$eventName]) { continue }
    $kept = @()
    foreach ($entry in @($settings.hooks.$eventName)) {
      $hasAgentNotify = $false
      foreach ($hook in @($entry.hooks)) {
        if (($hook.command -as [string]) -like "*agent-notify*notify.mjs*") {
          $hasAgentNotify = $true
        }
      }
      if (-not $hasAgentNotify) { $kept += $entry }
    }
    $settings.hooks.$eventName = @($kept)
  }

  Save-Json $settingsPath $settings
  Write-Step "Claude Code hooks removed"
}

function Restore-CodexNotify {
  $configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
  if (-not (Test-Path -LiteralPath $configPath)) { return }
  if (-not (Test-Path -LiteralPath $OriginalCodexNotifyPath)) {
    Write-Step "Original Codex notify record not found, skip restore"
    return
  }

  Backup-File $configPath
  $raw = Get-Content -LiteralPath $configPath -Raw
  $original = Get-Content -LiteralPath $OriginalCodexNotifyPath -Raw | ConvertFrom-Json
  $line = $original.originalLine
  if (-not $line) { $line = "notify = " + (($original.argv | ConvertTo-Json -Compress)) }

  if ($raw -match '(?m)^\s*notify\s*=\s*\[.*agent-notify.*notify\.mjs.*\]\s*$') {
    $updated = [regex]::Replace($raw, '(?m)^\s*notify\s*=\s*\[.*agent-notify.*notify\.mjs.*\]\s*$', $line, 1)
    if (-not $DryRun) {
      [System.IO.File]::WriteAllText($configPath, $updated, [System.Text.UTF8Encoding]::new($false))
    }
    Write-Step "Codex notify restored"
  } else {
    Write-Step "Codex notify does not point to agent-notify, skip"
  }
}

if (-not $SkipClaude) {
  Remove-ClaudeHooks
}

if (-not $SkipCodex) {
  Restore-CodexNotify
}

Write-Step "Uninstall complete"
