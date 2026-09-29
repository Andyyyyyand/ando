#!/bin/bash
#
# Compila o Meu Clicky pelo Terminal (sem abrir o Xcode) e abre o app.
#
# Usa assinatura "ad-hoc" (local), então não precisa configurar Apple ID
# nem Team. O "hardened runtime" fica desligado porque, com assinatura
# ad-hoc, ele impede o app de carregar os frameworks embutidos (Sparkle)
# e o app fecha logo ao abrir. Com assinatura ad-hoc, a cada nova compilação as
# permissões (tela, acessibilidade, microfone) precisam ser liberadas de novo;
# se existir o certificado local "Meu Clicky Local", ele é usado e as
# permissões continuam valendo.
#
# Uso:  bash scripts/compilar-e-abrir.sh
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
INSTALLED_APP="$HOME/Applications/Meu Clicky.app"
XCODE_APP_STORE_ID=497799835

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }
fail() { printf "\033[1;31m✗ %s\033[0m\n" "$1"; exit 1; }

# ---------------------------------------------------------------------------
step "1/4 Xcode"
XCODE_PATH="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
if [[ -z "$XCODE_PATH" && -d /Applications/Xcode.app ]]; then
    XCODE_PATH=/Applications/Xcode.app
fi

if [[ -z "$XCODE_PATH" ]]; then
    echo "O Xcode não está instalado. Tentando instalar pela App Store (precisa estar logado na App Store)..."
    command -v brew >/dev/null 2>&1 || fail "Rode primeiro: bash scripts/instalar-meu-clicky.sh"
    command -v mas >/dev/null 2>&1 || brew install mas
    mas install "$XCODE_APP_STORE_ID" || fail "Não consegui instalar o Xcode. Instale pela App Store e rode este script de novo."
    XCODE_PATH=/Applications/Xcode.app
fi

# O xcodebuild precisa apontar para o Xcode completo (não só as Command Line Tools).
if [[ "$(xcode-select -p)" != "$XCODE_PATH/Contents/Developer" ]]; then
    echo "Apontando o Terminal para o Xcode (vai pedir sua senha)..."
    sudo xcode-select -s "$XCODE_PATH/Contents/Developer"
fi
sudo xcodebuild -license accept >/dev/null 2>&1 || true
xcodebuild -runFirstLaunch >/dev/null 2>&1 || true
ok "Xcode pronto: $XCODE_PATH"

# ---------------------------------------------------------------------------
step "2/4 Compilando (a primeira vez demora alguns minutos)"
cd "$PROJECT_DIR"
BUILD_LOG="$BUILD_DIR/build.log"
mkdir -p "$BUILD_DIR"

# Com o certificado local "Meu Clicky Local" no Keychain, a assinatura fica
# igual entre compilações e o macOS mantém as permissões. Sem ele, ad-hoc
# ("-"): funciona, mas as permissões somem a cada compilação.
SIGNING_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Meu Clicky Local"'; then
    SIGNING_IDENTITY="Meu Clicky Local"
fi
echo "Assinatura: $SIGNING_IDENTITY"

if ! xcodebuild \
    -project leanring-buddy.xcodeproj \
    -scheme leanring-buddy \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    ENABLE_HARDENED_RUNTIME=NO \
    build > "$BUILD_LOG" 2>&1; then
    echo
    echo "Erros encontrados:"
    grep -E "error:" "$BUILD_LOG" | sort -u | head -20 || tail -30 "$BUILD_LOG"
    echo
    fail "A compilação falhou. Copie os erros acima e mande para o Claude. Log completo: $BUILD_LOG"
fi
ok "Compilado"

# ---------------------------------------------------------------------------
step "3/4 Instalando em ~/Applications"
BUILT_APP="$(find "$BUILD_DIR/DerivedData/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)"
[[ -n "$BUILT_APP" ]] || fail "Não encontrei o app compilado."

osascript -e 'tell application "Clicky" to quit' >/dev/null 2>&1 || true
pkill -f "Meu Clicky.app/Contents/MacOS" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED_APP"
cp -R "$BUILT_APP" "$INSTALLED_APP"
ok "Instalado em $INSTALLED_APP"

# ---------------------------------------------------------------------------
step "4/4 Abrindo"
open "$INSTALLED_APP"
ok "Pronto! Procure o triângulo na barra de menu, lá em cima."
echo "Libere as 4 permissões que o painel pedir e clique em Começar."
echo "Se o macOS pedir para reabrir o app depois de liberar a Gravação de tela, rode:"
echo "  open \"$INSTALLED_APP\""
