#!/bin/bash
#
# Instala tudo que o Meu Clicky precisa para rodar localmente no Mac:
#   1. Ollama + modelo de visão qwen3-vl:4b-instruct (o "cérebro" local, grátis)
#   2. Voz Kokoro em português via mlx-audio (substitui o ElevenLabs, grátis)
#      rodando em segundo plano como um serviço do macOS (LaunchAgent)
#   3. Claude Code (o agente pesado, usa sua assinatura do Claude)
#
# Uso:  bash scripts/instalar-meu-clicky.sh
# Pode rodar de novo quantas vezes quiser; ele pula o que já está instalado.
#

set -euo pipefail

MEU_CLICKY_DIR="$HOME/.meu-clicky"
VOICE_VENV_DIR="$MEU_CLICKY_DIR/voz"
KOKORO_PORT=8123
LOCAL_VISION_MODEL="qwen3-vl:4b-instruct"
LAUNCH_AGENT_LABEL="com.meuclicky.kokoro"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }
warn() { printf "\033[1;33m! %s\033[0m\n" "$1"; }

if [[ "$(uname -m)" != "arm64" ]]; then
    warn "Este script é para Macs com chip Apple (M1/M2/M3/M4). A voz Kokoro via MLX não roda em Intel."
    exit 1
fi

# ---------------------------------------------------------------------------
step "1/5 Homebrew"
if ! command -v brew >/dev/null 2>&1; then
    echo "Instalando Homebrew (vai pedir sua senha do Mac)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
ok "Homebrew pronto"

# ---------------------------------------------------------------------------
step "2/5 Ollama + modelo de visão ($LOCAL_VISION_MODEL, ~3,3 GB)"
if ! command -v ollama >/dev/null 2>&1; then
    brew install ollama
fi
# Roda o Ollama como serviço: sobe sozinho quando o Mac liga.
brew services start ollama >/dev/null 2>&1 || true
for _ in {1..20}; do
    curl -fs http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
    sleep 1
done
ollama pull "$LOCAL_VISION_MODEL"
ok "Ollama rodando com $LOCAL_VISION_MODEL"

# ---------------------------------------------------------------------------
step "3/5 Voz Kokoro (mlx-audio) em português"
brew list espeak-ng >/dev/null 2>&1 || brew install espeak-ng
brew list python@3.12 >/dev/null 2>&1 || brew install python@3.12
PYTHON_BIN="$(brew --prefix python@3.12)/bin/python3.12"

mkdir -p "$MEU_CLICKY_DIR"
if [[ ! -x "$VOICE_VENV_DIR/bin/python" ]]; then
    "$PYTHON_BIN" -m venv "$VOICE_VENV_DIR"
fi
"$VOICE_VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VOICE_VENV_DIR/bin/pip" install --quiet --upgrade "mlx-audio[server]" "misaki[en]"
ok "mlx-audio instalado em $VOICE_VENV_DIR"

# ---------------------------------------------------------------------------
step "4/5 Serviço de voz em segundo plano (porta $KOKORO_PORT)"
mkdir -p "$HOME/Library/LaunchAgents" "$MEU_CLICKY_DIR/logs"
cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCH_AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VOICE_VENV_DIR/bin/mlx_audio.server</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>$KOKORO_PORT</string>
        <string>--log-dir</string>
        <string>$MEU_CLICKY_DIR/logs</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$MEU_CLICKY_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$MEU_CLICKY_DIR/logs/kokoro.out.log</string>
    <key>StandardErrorPath</key>
    <string>$MEU_CLICKY_DIR/logs/kokoro.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"

echo "Esperando o servidor de voz subir..."
for _ in {1..60}; do
    curl -fs "http://127.0.0.1:$KOKORO_PORT/v1/models" >/dev/null 2>&1 && break
    sleep 1
done

echo "Baixando a voz Kokoro e testando (a primeira vez demora um pouco)..."
if curl -fs -X POST "http://127.0.0.1:$KOKORO_PORT/v1/audio/speech" \
    -H "Content-Type: application/json" \
    -d '{"model":"mlx-community/Kokoro-82M-bf16","input":"oi! eu sou o seu clicky.","voice":"pf_dora","lang_code":"p","response_format":"wav"}' \
    -o "$MEU_CLICKY_DIR/teste-voz.wav"; then
    afplay "$MEU_CLICKY_DIR/teste-voz.wav" || true
    ok "Voz Kokoro funcionando"
else
    warn "A voz Kokoro não respondeu. O app vai usar a voz do macOS até isso ser resolvido."
    warn "Veja o log: $MEU_CLICKY_DIR/logs/kokoro.err.log"
fi

# ---------------------------------------------------------------------------
step "5/5 Claude Code (agente para tarefas pesadas)"
if command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]; then
    ok "Claude Code já instalado"
else
    curl -fsSL https://claude.ai/install.sh | bash
    ok "Claude Code instalado"
fi
echo "Se ainda não fez login no Claude Code, rode 'claude' no Terminal uma vez e entre com sua conta."

printf "\n\033[1;32mTudo pronto!\033[0m\n"
echo "Próximo passo: abra leanring-buddy.xcodeproj no Xcode e aperte Cmd+R (veja o README)."
