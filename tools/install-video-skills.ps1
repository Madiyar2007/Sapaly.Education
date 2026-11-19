# Installs 9 open-source Claude Code video/motion skills on Windows into %USERPROFILE%\.claude\skills.
# Safe to re-run: already-installed pieces are skipped or updated.
#
# Run in PowerShell:
#   powershell -ExecutionPolicy Bypass -File install-video-skills.ps1 [-Project "C:\path\to\AI Video Editor"]
# -Project is where Argo (browser demo recorder) gets its npm packages. Default: searched under your user folder.
# Full log: %USERPROFILE%\.claude\video-skills-install.log

param([string]$Project = "")

$ErrorActionPreference = "Continue"
$Claude  = Join-Path $env:USERPROFILE ".claude"
$Skills  = Join-Path $Claude "skills"
$Src     = Join-Path $Claude "skill-sources"
$Log     = Join-Path $Claude "video-skills-install.log"
New-Item -ItemType Directory -Force -Path $Skills, $Src | Out-Null
Start-Transcript -Path $Log -Append | Out-Null

$Results = New-Object System.Collections.ArrayList
function Ok($n, $m)   { [void]$Results.Add([pscustomobject]@{Status="OK";   Skill=$n; Note=$m}); Write-Host "[OK]   $n : $m" -ForegroundColor Green }
function Warn($n, $m) { [void]$Results.Add([pscustomobject]@{Status="WARN"; Skill=$n; Note=$m}); Write-Host "[WARN] $n : $m" -ForegroundColor Yellow }
function Step($t)     { Write-Host ""; Write-Host "==== $t ====" -ForegroundColor Cyan }
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
  $extra = @("$env:USERPROFILE\.local\bin", "$env:USERPROFILE\.bun\bin", "$env:APPDATA\npm")
  foreach ($e in $extra) { if (Test-Path $e) { $env:Path += ";$e" } }
}
function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------- 1. System tools (winget)
Step "System tools: Git, Node.js, Python, ffmpeg, uv, Bun, eSpeak-NG"
if (-not (Has winget)) {
  Write-Host "winget not found. Install 'App Installer' from the Microsoft Store, then run this script again." -ForegroundColor Red
  Stop-Transcript | Out-Null; exit 1
}
$pkgs = [ordered]@{
  "git"    = "Git.Git"
  "node"   = "OpenJS.NodeJS.LTS"
  "python" = "Python.Python.3.12"
  "ffmpeg" = "Gyan.FFmpeg"
  "uv"     = "astral-sh.uv"
  "bun"    = "Oven-sh.Bun"
  "espeak-ng" = "eSpeak-NG.eSpeak-NG"
}
Refresh-Path
foreach ($cmd in $pkgs.Keys) {
  if (Has $cmd) { Write-Host "  $cmd already installed"; continue }
  winget install --id $pkgs[$cmd] -e --silent --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) { Warn $cmd "winget install failed (id $($pkgs[$cmd]))" }
  Refresh-Path
}
if (Has ffmpeg) { Ok "ffmpeg" "installed" } else { Warn "ffmpeg" "not on PATH - open a NEW PowerShell window and re-run this script" }
if (-not (Has git) -or -not (Has node)) {
  Write-Host "Git or Node is not on PATH yet. Close PowerShell, open a new one and run this script again." -ForegroundColor Red
  Stop-Transcript | Out-Null; exit 1
}

# ---------------------------------------------------------------- 2. Clone / update sources
Step "Downloading repositories into $Src"
$repos = @(
  "talsiach/take-one", "win4r/video-director", "vincentsch/explainroo", "Leonxlnx/earshot",
  "NiazMorshed2007/reanimate", "alchaincyf/huashu-art-motion", "alchaincyf/huashu-motion",
  "rossark0/rossark-motion-skill", "shreyaskarnik/argo"
)
foreach ($r in $repos) {
  $d = Join-Path $Src ($r.Split("/")[1])
  if (Test-Path (Join-Path $d ".git")) { git -C $d pull -q --ff-only; if ($LASTEXITCODE) { Warn $r "git pull failed, kept old version" } }
  else { git clone -q --depth 1 "https://github.com/$r" $d; if ($LASTEXITCODE) { Warn $r "git clone failed" } }
}

function Copy-Skill($name, $from) {
  if (-not (Test-Path (Join-Path $from "SKILL.md"))) { Warn $name "SKILL.md not found in $from"; return $false }
  $to = Join-Path $Skills $name
  robocopy $from $to /MIR /XD .git /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { Warn $name "copy failed"; return $false }
  return $true
}

# ---------------------------------------------------------------- 3. Skills
Step "Take-One"
if (Copy-Skill "take-one" "$Src\take-one") { Ok "take-one" "ready" }

Step "Video-Director (+ numpy, Pillow)"
if (Copy-Skill "video-director" "$Src\video-director\video-director") {
  python -m pip install --user -q numpy Pillow
  if ($LASTEXITCODE -eq 0) { Ok "video-director" "ready" } else { Warn "video-director" "skill copied, numpy/Pillow failed" }
}

Step "Explainroo"
if (Copy-Skill "explainroo" "$Src\explainroo\skills\explainroo") {
  Push-Location "$Src\explainroo"; npx --yes explainroo doctor --fetch; $rc = $LASTEXITCODE; Pop-Location
  if ($rc -eq 0) { Ok "explainroo" "ready" } else { Warn "explainroo" "skill copied, doctor reported problems - see log" }
}

Step "Earshot (+ real-sound, CLI via uv, MCP server)"
[void](Copy-Skill "earshot" "$Src\earshot\skills\earshot")
[void](Copy-Skill "real-sound" "$Src\earshot\skills\real-sound")
uv tool install --force "earshot[mcp] @ git+https://github.com/Leonxlnx/earshot"
if ($LASTEXITCODE -eq 0) {
  Refresh-Path
  if (Has claude) {
    claude mcp get earshot *> $null
    if ($LASTEXITCODE -ne 0) { claude mcp add earshot --scope user -e EARSHOT_THREADS=3 -- earshot mcp }
  }
  earshot doctor
  Ok "earshot" "ready (models download on first use)"
} else { Warn "earshot" "skill copied, uv tool install failed" }

Step "Reanimate (+ bun deps, Chromium)"
if (Copy-Skill "reanimate" "$Src\reanimate\skills\reanimate") {
  Push-Location "$Skills\reanimate\scripts"
  bun install --silent
  if ($LASTEXITCODE -eq 0) { bunx playwright install chromium }
  $rc = $LASTEXITCODE; Pop-Location
  if ($rc -eq 0) { Ok "reanimate" "ready" } else { Warn "reanimate" "skill copied, bun/playwright setup failed" }
}

Step "Huashu Art Motion (+ Chromium)"
if (Copy-Skill "huashu-art-motion" "$Src\huashu-art-motion") {
  Push-Location "$Skills\huashu-art-motion"; uv run --with playwright playwright install chromium; $rc = $LASTEXITCODE; Pop-Location
  if ($rc -eq 0) { Ok "huashu-art-motion" "ready (instructions are in Chinese - that's fine)" } else { Warn "huashu-art-motion" "skill copied, Chromium failed" }
}

Step "Huashu Motion"
if (Copy-Skill "huashu-motion" "$Src\huashu-motion\skills\huashu-motion") {
  Ok "huashu-motion" "ready (uses 'npx huashu-motion'; needs Google Chrome installed)"
}

Step "Rossark-Motion"
if (Copy-Skill "rossark-motion" "$Src\rossark-motion-skill") { Ok "rossark-motion" "ready" }

Step "Argo (argo-guide skill + free local voice kokoro)"
if (Copy-Skill "argo-guide" "$Src\argo\skills\argo-guide") {
  if (-not $Project) {
    $found = Get-ChildItem -Path $env:USERPROFILE -Directory -Filter "AI Video Editor" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $Project = $found.FullName }
  }
  if ($Project -and (Test-Path $Project)) {
    Push-Location $Project
    if (-not (Test-Path "package.json")) { npm init -y | Out-Null }
    npm i -D @argo-video/cli kokoro-js@1
    if ($LASTEXITCODE -eq 0) { npx --yes playwright install chromium }
    $rc = $LASTEXITCODE; Pop-Location
    if ($rc -eq 0) { Ok "argo-guide" "ready, packages in: $Project" } else { Warn "argo-guide" "skill copied, npm packages failed in $Project" }
  } else { Warn "argo-guide" "skill copied; 'AI Video Editor' folder not found - Argo packages install on first use" }
}

# ---------------------------------------------------------------- 4. Summary
Step "SUMMARY"
$Results | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Skills folder: $Skills"
Get-ChildItem $Skills -Directory | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host ""
Write-Host "Full log: $Log"
Write-Host "Restart Claude so it picks up the new skills." -ForegroundColor Cyan
Stop-Transcript | Out-Null
