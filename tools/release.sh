#!/bin/bash
# Monta o pacote de atualizacao do lusmOS: dist/lusmos-<versao>.tar.gz e o .sha256
# Uso: tools/release.sh            (usa a versao de lusmos/VERSION)
set -e
cd "$(dirname "$0")/.."
VER=$(tr -d '[:space:]' < lusmos/VERSION)
# a versao mostrada no registro de erros acompanha o VERSION
sed -i "s/^local BUILD = \"[^\"]*\"/local BUILD = \"$VER\"/" lusmos/app/main.lua
grep -q "local BUILD = \"$VER\"" lusmos/app/main.lua
mkdir -p dist
PKG="dist/lusmos-$VER.tar.gz"
tar --sort=name --owner=0 --group=0 --mtime='2026-01-01' -czf "$PKG" lusmos boot
( cd dist && sha256sum "lusmos-$VER.tar.gz" > "lusmos-$VER.tar.gz.sha256" )
echo "$PKG"
