#!/bin/sh
# Compila Sussurro.app em build/ e copia para /Applications
set -e
cd "$(dirname "$0")"
APP=build/Sussurro.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 Sources/*.swift -o "$APP/Contents/MacOS/Sussurro"
cp Info.plist "$APP/Contents/"
# ícone: icon.png (gerado por `swift icon.swift`) -> AppIcon.icns
[ -f icon.png ] || swift icon.swift
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# assinatura estável (certificado "Foco Dev" no Chaves): o macOS mantém microfone,
# Acessibilidade e o acesso às chaves entre builds. Não trocar por ad-hoc (-s -).
codesign --force -s "Foco Dev" "$APP"
pkill -x Sussurro || true
rm -rf /Applications/Sussurro.app && cp -R "$APP" /Applications/
# registra no macOS para aparecer em Aplicativos / buscador de apps
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Sussurro.app
echo "ok: /Applications/Sussurro.app"
