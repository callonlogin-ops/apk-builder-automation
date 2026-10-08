#!/bin/bash

##############################################################################
# APK Builder & Automation Script
# Automação completa: Clone → Build → Sign → Emulate → Deploy
# Suporta: Android Studio, APKTool, ADB, Termux, Play Console & AppGeyser
##############################################################################

set -e  # Exit on error

# ============================================================================
# CORES E FORMATAÇÃO
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ============================================================================
# CONFIGURAÇÕES INICIAIS
# ============================================================================

PROJECT_NAME="${1:-meu-app-android}"
GITHUB_URL="${2:-https://github.com/seu-usuario/seu-repo.git}"
KEYSTORE_PATH="${3:-./keystore/release.jks}"
KEYSTORE_ALIAS="${4:-release-key}"
KEYSTORE_PASSWORD="${5:-sua-senha}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
GRADLE_WRAPPER="./gradlew"
BUILD_TYPE="release"
OUTPUT_DIR="./build-output"
EMULATOR_NAME="${6:-Pixel_4_API_30}"

# ============================================================================
# FUNÇÃO: Verificar Dependências
# ============================================================================
check_dependencies() {
    log_info "Verificando dependências..."
    
    local missing_deps=0
    
    # Verificar Java
    if ! command -v java &> /dev/null; then
        log_warning "Java não encontrado. Instale Java 11 ou superior."
        missing_deps=1
    else
        log_success "Java encontrado: $(java -version 2>&1 | head -n 1)"
    fi
    
    # Verificar Git
    if ! command -v git &> /dev/null; then
        log_warning "Git não encontrado. Instale Git."
        missing_deps=1
    else
        log_success "Git encontrado"
    fi
    
    # Verificar ADB
    if ! command -v adb &> /dev/null; then
        log_warning "ADB não encontrado em PATH. Usando Android SDK..."
        if [ ! -f "$ANDROID_HOME/platform-tools/adb" ]; then
            log_warning "ADB não encontrado em $ANDROID_HOME/platform-tools/"
            log_info "Defina ANDROID_HOME ou instale Android SDK Platform Tools"
        fi
    else
        log_success "ADB encontrado"
    fi
    
    if [ $missing_deps -eq 1 ]; then
        log_warning "Algumas dependências podem estar faltando, continuando..."
    fi
}

# ============================================================================
# FUNÇÃO: Clonar Repositório GitHub
# ============================================================================
clone_repository() {
    log_info "Clonando repositório: $GITHUB_URL"
    
    if [ -d "$PROJECT_NAME" ]; then
        log_warning "Diretório $PROJECT_NAME já existe. Atualizando..."
        cd "$PROJECT_NAME"
        git pull origin main || git pull origin master
        cd ..
    else
        git clone "$GITHUB_URL" "$PROJECT_NAME"
    fi
    
    log_success "Repositório clonado com sucesso"
}

# ============================================================================
# FUNÇÃO: Setup Keystore
# ============================================================================
setup_keystore() {
    log_info "Configurando Keystore..."
    
    if [ ! -f "$KEYSTORE_PATH" ]; then
        log_warning "Keystore não encontrado em: $KEYSTORE_PATH"
        log_info "Gerando novo Keystore..."
        
        mkdir -p "$(dirname "$KEYSTORE_PATH")"
        
        keytool -genkey -v -keystore "$KEYSTORE_PATH" \
            -keyalg RSA -keysize 2048 -validity 10000 \
            -alias "$KEYSTORE_ALIAS" \
            -storepass "$KEYSTORE_PASSWORD" \
            -keypass "$KEYSTORE_PASSWORD" \
            -dname "CN=App,O=Org,L=City,ST=State,C=BR"
        
        log_success "Keystore criado com sucesso"
    else
        log_success "Keystore encontrado: $KEYSTORE_PATH"
    fi
}

# ============================================================================
# FUNÇÃO: Build APK com Gradle
# ============================================================================
build_apk() {
    log_info "Compilando APK (tipo: $BUILD_TYPE)..."
    
    cd "$PROJECT_NAME"
    
    # Verificar se Gradle Wrapper existe
    if [ ! -f "$GRADLE_WRAPPER" ]; then
        log_warning "Gradle Wrapper não encontrado, usando gradle system"
        GRADLE_WRAPPER="gradle"
    fi
    
    # Dar permissão de execução
    chmod +x "$GRADLE_WRAPPER" 2>/dev/null || true
    
    # Build
    if [ "$BUILD_TYPE" = "release" ]; then
        $GRADLE_WRAPPER assembleRelease \
            -Pandroid.useAndroidX=true \
            --stacktrace
    else
        $GRADLE_WRAPPER assembleDebug \
            -Pandroid.useAndroidX=true \
            --stacktrace
    fi
    
    cd ..
    log_success "Build concluído com sucesso"
}

# ============================================================================
# FUNÇÃO: Assinar APK
# ============================================================================
sign_apk() {
    log_info "Assinando APK..."
    
    local unsigned_apk="$PROJECT_NAME/app/build/outputs/apk/$BUILD_TYPE/app-${BUILD_TYPE}-unsigned.apk"
    local signed_apk="$OUTPUT_DIR/app-${BUILD_TYPE}-signed.apk"
    
    mkdir -p "$OUTPUT_DIR"
    
    if [ ! -f "$unsigned_apk" ]; then
        log_error "APK não encontrado: $unsigned_apk"
    fi
    
    # Alinhar APK (otimização)
    log_info "Alinhando APK..."
    zipalign -v 4 "$unsigned_apk" "$signed_apk.aligned" || true
    
    # Assinar
    log_info "Aplicando assinatura digital..."
    jarsigner -verbose -sigalg SHA1withRSA -digestalg SHA1 \
        -keystore "$KEYSTORE_PATH" \
        -storepass "$KEYSTORE_PASSWORD" \
        -keypass "$KEYSTORE_PASSWORD" \
        "$signed_apk.aligned" "$KEYSTORE_ALIAS"
    
    # Verificar
    log_info "Verificando assinatura..."
    jarsigner -verify -verbose -certs "$signed_apk.aligned"
    
    # Renomear final
    mv "$signed_apk.aligned" "$signed_apk"
    
    log_success "APK assinado com sucesso: $signed_apk"
}

# ============================================================================
# FUNÇÃO: Instalar no Emulador (ADB)
# ============================================================================
install_emulator() {
    log_info "Instalando APK no emulador..."
    
    local signed_apk="$OUTPUT_DIR/app-${BUILD_TYPE}-signed.apk"
    
    if [ ! -f "$signed_apk" ]; then
        log_error "APK assinado não encontrado: $signed_apk"
    fi
    
    # Verificar ADB
    local adb_cmd="adb"
    if [ ! -x "$(command -v adb)" ]; then
        adb_cmd="$ANDROID_HOME/platform-tools/adb"
    fi
    
    if [ ! -x "$adb_cmd" ]; then
        log_error "ADB não encontrado. Configure ANDROID_HOME."
    fi
    
    # Aguardar emulador
    log_info "Aguardando emulador..."
    $adb_cmd wait-for-device
    sleep 2
    
    # Instalar
    log_info "Instalando aplicativo..."
    $adb_cmd install -r "$signed_apk"
    
    log_success "APK instalado com sucesso no emulador"
}

# ============================================================================
# FUNÇÃO: Extrair informações do Manifest
# ============================================================================
extract_manifest_info() {
    log_info "Extraindo informações do AndroidManifest..."
    
    local manifest="$PROJECT_NAME/app/src/main/AndroidManifest.xml"
    
    if [ ! -f "$manifest" ]; then
        log_warning "AndroidManifest.xml não encontrado"
        return
    fi
    
    # Extrair package name
    local package_name=$(grep -oP 'package="\K[^"]+' "$manifest" | head -1)
    log_info "Package Name: $package_name"
    
    echo "$package_name"
}

# ============================================================================
# FUNÇÃO: Iniciar App no Emulador
# ============================================================================
launch_app() {
    log_info "Iniciando aplicativo no emulador..."
    
    local package_name=$(extract_manifest_info)
    
    if [ -z "$package_name" ]; then
        log_warning "Package name não identificado, pulando launch"
        return
    fi
    
    local adb_cmd="adb"
    if [ ! -x "$(command -v adb)" ]; then
        adb_cmd="$ANDROID_HOME/platform-tools/adb"
    fi
    
    $adb_cmd shell am start -n "$package_name/.MainActivity" || true
    
    log_success "Aplicativo iniciado"
}

# ============================================================================
# FUNÇÃO: Converter para AAB (Android App Bundle)
# ============================================================================
build_aab() {
    log_info "Compilando Android App Bundle (AAB)..."
    
    cd "$PROJECT_NAME"
    
    if [ ! -f "$GRADLE_WRAPPER" ]; then
        GRADLE_WRAPPER="gradle"
    fi
    
    chmod +x "$GRADLE_WRAPPER" 2>/dev/null || true
    
    $GRADLE_WRAPPER bundleRelease \
        -Pandroid.useAndroidX=true \
        --stacktrace
    
    cd ..
    
    local aab_file="$PROJECT_NAME/app/build/outputs/bundle/${BUILD_TYPE}/app-${BUILD_TYPE}.aab"
    
    if [ -f "$aab_file" ]; then
        cp "$aab_file" "$OUTPUT_DIR/app-release.aab"
        log_success "AAB gerado: $OUTPUT_DIR/app-release.aab"
    fi
}

# ============================================================================
# FUNÇÃO: Preparar para Play Store
# ============================================================================
prepare_playstore() {
    log_info "Preparando arquivos para Play Console..."
    
    mkdir -p "$OUTPUT_DIR/playstore"
    
    local signed_apk="$OUTPUT_DIR/app-${BUILD_TYPE}-signed.apk"
    local aab_file="$OUTPUT_DIR/app-release.aab"
    
    if [ -f "$aab_file" ]; then
        cp "$aab_file" "$OUTPUT_DIR/playstore/"
        log_success "AAB copiado para playstore/"
    fi
    
    if [ -f "$signed_apk" ]; then
        cp "$signed_apk" "$OUTPUT_DIR/playstore/"
        log_success "APK copiado para playstore/"
    fi
    
    # Criar README com instruções
    cat > "$OUTPUT_DIR/playstore/README.md" << 'EOF'
# Play Store Upload Instructions

1. Acesse: https://play.google.com/console
2. Selecione seu aplicativo
3. Vá para: Versões do App > Produção
4. Clique em: Criar versão de lançamento
5. Faça upload do arquivo .aab ou .apk
6. Preencha as informações obrigatórias:
   - Screenshots
   - Descrição
   - Política de Privacidade
7. Envie para revisão

**Importante**: Google recomenda usar .aab (Android App Bundle)
EOF
    
    log_success "Arquivos preparados em: $OUTPUT_DIR/playstore/"
}

# ============================================================================
# FUNÇÃO: Preparar para AppGeyser
# ============================================================================
prepare_appgeyser() {
    log_info "Preparando para AppGeyser (appsgeyser.com)..."
    
    mkdir -p "$OUTPUT_DIR/appgeyser"
    
    local signed_apk="$OUTPUT_DIR/app-${BUILD_TYPE}-signed.apk"
    
    if [ -f "$signed_apk" ]; then
        cp "$signed_apk" "$OUTPUT_DIR/appgeyser/"
        
        cat > "$OUTPUT_DIR/appgeyser/UPLOAD_INSTRUCTIONS.txt" << 'EOF'
=== AppGeyser Upload Guide ===

1. Acesse: https://appsgeyser.com
2. Faça login ou crie conta
3. Clique em: "Criar Novo App"
4. Selecione: "Fazer upload de APK"
5. Selecione o arquivo: app-release-signed.apk
6. Configure nome, ícone, descrição
7. Publique

O AppGeyser irá:
- Gerar link de download direto
- Criar versão para diferentes plataformas
- Fornecer estatísticas de download
EOF
        
        log_success "APK pronto para AppGeyser: $OUTPUT_DIR/appgeyser/"
    fi
}

# ============================================================================
# FUNÇÃO: Gerar Relatório de Build
# ============================================================================
generate_report() {
    log_info "Gerando relatório de build..."
    
    local report="$OUTPUT_DIR/BUILD_REPORT.txt"
    
    cat > "$report" << EOF
╔════════════════════════════════════════════════════════════════╗
║          APK BUILDER AUTOMATION - BUILD REPORT                 ║
╚════════════════════════════════════════════════════════════════╝

📅 Data: $(date)
🏗️  Projeto: $PROJECT_NAME
🔗 GitHub: $GITHUB_URL
📦 Tipo de Build: $BUILD_TYPE
🎯 Emulador: $EMULATOR_NAME

═════════════════════════════════════════════════════════════════

📁 ARQUIVOS GERADOS:

APK Assinado:
  └─ $OUTPUT_DIR/app-${BUILD_TYPE}-signed.apk

AAB (Android App Bundle):
  └─ $OUTPUT_DIR/app-release.aab

Play Store Ready:
  └─ $OUTPUT_DIR/playstore/

AppGeyser Ready:
  └─ $OUTPUT_DIR/appgeyser/

═════════════════════════════════════════════════════════════════

🚀 PRÓXIMOS PASSOS:

1. TESTAR NO EMULADOR:
   - APK já foi instalado automaticamente

2. PUBLICAR NA PLAY STORE:
   - Acesse: https://play.google.com/console
   - Faça upload de: $OUTPUT_DIR/playstore/app-release.aab
   - Preencha informações obrigatórias
   - Envie para revisão

3. PUBLICAR NO APPGEYSER:
   - Acesse: https://appsgeyser.com
   - Faça upload de: $OUTPUT_DIR/appgeyser/app-${BUILD_TYPE}-signed.apk
   - Configure e publique

═════════════════════════════════════════════════════════════════

✅ BUILD CONCLUÍDO COM SUCESSO!

Para mais informações, consulte os arquivos README em cada diretório.

═════════════════════════════════════════════════════════════════
EOF
    
    cat "$report"
}

# ============================================================================
# FUNÇÃO: Menu Principal
# ============================================================================
show_menu() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     APK BUILDER & AUTOMATION - MENU PRINCIPAL                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "1) Executar Pipeline Completo (Clone → Build → Sign → Deploy)"
    echo "2) Clone do GitHub"
    echo "3) Build APK"
    echo "4) Assinar APK"
    echo "5) Instalar no Emulador"
    echo "6) Gerar AAB (Android App Bundle)"
    echo "7) Preparar para Play Store"
    echo "8) Preparar para AppGeyser"
    echo "9) Ver Relatório de Build"
    echo "10) Verificar Dependências"
    echo "0) Sair"
    echo ""
}

# ============================================================================
# FUNÇÃO: Pipeline Completo
# ============================================================================
run_full_pipeline() {
    log_info "Iniciando Pipeline Completo..."
    log_info "Este processo irá: Clone → Build → Sign → Emulate → Deploy"
    echo ""
    
    check_dependencies
    clone_repository
    setup_keystore
    build_apk
    sign_apk
    build_aab
    prepare_playstore
    prepare_appgeyser
    
    log_info "Tentando instalar no emulador..."
    install_emulator || log_warning "Emulador não disponível, pulando instalação"
    
    generate_report
    
    log_success "🎉 PIPELINE COMPLETO CONCLUÍDO COM SUCESSO!"
}

# ============================================================================
# MAIN - Modo Interativo ou Automático
# ============================================================================
main() {
    if [ $# -eq 0 ]; then
        # Modo Interativo
        while true; do
            show_menu
            read -p "Escolha uma opção (0-10): " option
            
            case $option in
                1) run_full_pipeline ;;
                2) clone_repository ;;
                3) build_apk ;;
                4) sign_apk ;;
                5) install_emulator ;;
                6) build_aab ;;
                7) prepare_playstore ;;
                8) prepare_appgeyser ;;
                9) generate_report ;;
                10) check_dependencies ;;
                0) log_success "Encerrando..."; exit 0 ;;
                *) log_error "Opção inválida!" ;;
            esac
        done
    else
        # Modo Automático (full pipeline)
        run_full_pipeline
    fi
}

# ============================================================================
# EXECUTAR
# ============================================================================
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
