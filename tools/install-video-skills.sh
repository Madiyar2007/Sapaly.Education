#!/usr/bin/env bash
# Installs 9 open-source Claude Code video/motion skills on macOS into ~/.claude/skills.
# Safe to re-run: already-installed pieces are skipped or updated.
#
# Usage:  bash install-video-skills.sh ["/path/to/AI Video Editor"]
# The optional folder is where Argo (browser demo recorder) gets its npm packages.
# Full log: ~/.claude/video-skills-install.log

set -uo pipefail

SKILLS="$HOME/.claude/skills"
SRC="$HOME/.claude/skill-sources"
LOG="$HOME/.claude/video-skills-install.log"
mkdir -p "$SKILLS" "$SRC"
exec > >(tee -a "$LOG") 2>&1

declare -a RESULTS
ok()   { RESULTS+=("✅ $1|$2"); echo "✅ $1: $2"; }
warn() { RESULTS+=("⚠️  $1|$2"); echo "⚠️  $1: $2"; }
step() { echo; echo "==== $* ===="; }

# ---------------------------------------------------------------- 0. Homebrew
step "Homebrew"
if ! command -v brew >/dev/null; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
fi
if ! command -v brew >/dev/null; then
  echo "Homebrew не найден. Поставь его одной командой с https://brew.sh (попросит пароль), потом запусти этот скрипт снова."
  exit 1
fi

# ---------------------------------------------------------------- 1. System tools
step "Системные программы: ffmpeg, espeak-ng, whisper-cpp, uv, node, bun, git"
for pkg in ffmpeg espeak-ng whisper-cpp uv node git; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then echo "  $pkg уже стоит"
  else brew install "$pkg" || warn "$pkg" "brew install не удался"; fi
done
if ! command -v bun >/dev/null; then brew install oven-sh/bun/bun || warn "bun" "brew install не удался"; fi
command -v ffmpeg >/dev/null && ok "ffmpeg" "$(ffmpeg -version | head -1 | cut -d' ' -f1-3)"

# ---------------------------------------------------------------- 2. Clone / update sources
step "Скачиваю репозитории в $SRC"
REPOS=(
  talsiach/take-one
  win4r/video-director
  vincentsch/explainroo
  Leonxlnx/earshot
  NiazMorshed2007/reanimate
  alchaincyf/huashu-art-motion
  alchaincyf/huashu-motion
  rossark0/rossark-motion-skill
  shreyaskarnik/argo
)
for r in "${REPOS[@]}"; do
  d="$SRC/${r#*/}"
  if [ -d "$d/.git" ]; then git -C "$d" pull -q --ff-only || warn "${r#*/}" "git pull не удался, оставил старую версию"
  else git clone -q --depth 1 "https://github.com/$r" "$d" || warn "${r#*/}" "git clone не удался"; fi
done

# copy_skill <skill-name> <folder containing SKILL.md>
copy_skill() {
  local name="$1" from="$2"
  if [ ! -f "$from/SKILL.md" ]; then warn "$name" "не нашёл SKILL.md в $from"; return 1; fi
  rsync -a --delete --exclude .git "$from/" "$SKILLS/$name/"
}

# ---------------------------------------------------------------- 3. Skills
step "Take-One"
copy_skill take-one "$SRC/take-one" && ok "take-one" "готов"

step "Video-Director (+ numpy, Pillow для QA-скриптов)"
if copy_skill video-director "$SRC/video-director/video-director"; then
  if python3 -m pip install --user -q numpy Pillow 2>/dev/null \
     || python3 -m pip install --user -q --break-system-packages numpy Pillow; then
    ok "video-director" "готов"
  else warn "video-director" "скилл скопирован, но numpy/Pillow не поставились"; fi
fi

step "Explainroo"
if copy_skill explainroo "$SRC/explainroo/skills/explainroo"; then
  (cd "$SRC/explainroo" && npx --yes explainroo doctor --fetch) \
    && ok "explainroo" "готов" || warn "explainroo" "скилл скопирован, doctor ругается — см. лог"
fi

step "Earshot (+ real-sound, CLI через uv, MCP-сервер)"
copy_skill earshot "$SRC/earshot/skills/earshot"
copy_skill real-sound "$SRC/earshot/skills/real-sound"
if uv tool install --force "earshot[mcp] @ git+https://github.com/Leonxlnx/earshot"; then
  export PATH="$HOME/.local/bin:$PATH"
  if command -v claude >/dev/null && ! claude mcp get earshot >/dev/null 2>&1; then
    claude mcp add earshot --scope user -e EARSHOT_THREADS=3 -- earshot mcp || true
  fi
  earshot doctor || true
  ok "earshot" "готов (модели докачаются при первом запуске)"
else warn "earshot" "скилл скопирован, но uv tool install не удался"; fi

step "Reanimate (+ bun-зависимости, Chromium)"
if copy_skill reanimate "$SRC/reanimate/skills/reanimate"; then
  bash "$SKILLS/reanimate/scripts/setup.sh" && ok "reanimate" "готов" || warn "reanimate" "setup.sh не прошёл — см. лог"
fi

step "Huashu Art Motion (+ Chromium для рендера)"
if copy_skill huashu-art-motion "$SRC/huashu-art-motion"; then
  (cd "$SKILLS/huashu-art-motion" && uv run --with playwright playwright install chromium) \
    && ok "huashu-art-motion" "готов (инструкции на китайском — это нормально)" \
    || warn "huashu-art-motion" "скилл скопирован, Chromium не поставился"
fi

step "Huashu Motion"
if copy_skill huashu-motion "$SRC/huashu-motion/skills/huashu-motion"; then
  "$SKILLS/huashu-motion/bin/om" --help >/dev/null 2>&1 \
    && ok "huashu-motion" "готов (для рендера нужен установленный Google Chrome)" \
    || warn "huashu-motion" "скилл скопирован, CLI не запустился"
fi

step "Rossark-Motion"
copy_skill rossark-motion "$SRC/rossark-motion-skill" && ok "rossark-motion" "готов"

step "Argo (скилл argo-guide + локальная озвучка kokoro)"
if copy_skill argo-guide "$SRC/argo/skills/argo-guide"; then
  PROJECT="${1:-}"
  if [ -z "$PROJECT" ]; then
    for p in "$HOME/AI Video Editor" "$HOME/Desktop/AI Video Editor" "$HOME/Documents/AI Video Editor" "$HOME/Downloads/AI Video Editor"; do
      [ -d "$p" ] && PROJECT="$p" && break
    done
  fi
  if [ -n "$PROJECT" ] && [ -d "$PROJECT" ]; then
    (cd "$PROJECT" && { [ -f package.json ] || npm init -y >/dev/null; } \
      && npm i -D @argo-video/cli kokoro-js@1 && npx --yes playwright install chromium) \
      && ok "argo-guide" "готов, пакеты в: $PROJECT" \
      || warn "argo-guide" "скилл скопирован, npm-пакеты в $PROJECT не поставились"
  else
    warn "argo-guide" "скилл скопирован; папку 'AI Video Editor' не нашёл — пакеты Argo поставятся при первом использовании"
  fi
fi

# ---------------------------------------------------------------- 4. Summary
step "ИТОГ"
printf '%s\n' "${RESULTS[@]}" | column -t -s'|'
echo
echo "Скиллы: $SKILLS"
ls -1 "$SKILLS"
echo
echo "Полный лог: $LOG"
echo "Перезапусти Claude Code, чтобы он увидел новые скиллы."
