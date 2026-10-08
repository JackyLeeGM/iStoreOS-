#!/bin/sh
set -e

echo "🚀 开始安装 HomeProxy (APK 格式)..."
apk update || true
apk add --allow-untrusted *.apk

echo "✅ HomeProxy 安装完成！"
