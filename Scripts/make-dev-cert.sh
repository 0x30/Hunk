#!/bin/zsh
# 创建本机自签代码签名证书「Hunk Dev」，让本地构建拥有稳定签名身份：
# TCC 文件权限授权（文稿/桌面等）跨构建保留，不再每次重新弹窗。
# 只需运行一次；之后 make-app.sh 检测到该证书会自动使用。
set -euo pipefail

NAME="Hunk Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✅ 证书「$NAME」已存在，无需重复创建"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/conf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:hunk >/dev/null 2>&1

security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P hunk -T /usr/bin/codesign >/dev/null

echo "→ 把证书设为系统信任的代码签名证书（需要一次管理员密码）…"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$TMP/cert.pem"

echo "✅ 已创建并信任证书「$NAME」"
echo "   · 下次 Scripts/make-app.sh 构建会自动用它签名"
echo "   · 首次签名时若钥匙串弹窗，选「始终允许」"
echo "   · 换用新身份后第一次启动会再问一轮文件权限，之后就稳定了"
