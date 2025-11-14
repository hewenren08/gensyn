#!/bin/bash

# HuggingFace 网络连接修复脚本
echo "🔧 正在修复 HuggingFace 网络连接问题..."

# 设置多个备用镜像
HF_MIRRORS=(
    "https://hf-mirror.com"
    "https://huggingface.co.mirror.c70.cn"
    "https://hf.isg-services.com"
    "https://hf.tencent-cloud.com"
)

# 测试镜像连接性
test_mirror() {
    local mirror=$1
    echo "测试镜像: $mirror"
    timeout 10 curl -s "$mirror" >/dev/null 2>&1
    return $?
}

# 找到可用的镜像
for mirror in "${HF_MIRRORS[@]}"; do
    if test_mirror "$mirror"; then
        echo "✅ 镜像可用: $mirror"
        export HF_ENDPOINT="$mirror"
        break
    else
        echo "❌ 镜像不可用: $mirror"
    fi
done

# 设置额外的网络优化环境变量
export HF_HUB_ENABLE_HF_TRANSFER="1"
export HF_HUB_DOWNLOAD_TIMEOUT=600
export TRANSFORMERS_OFFLINE=0
export HF_HUB_DISABLE_TELEMETRY=1

# 尝试安装 hf-transfer 加速下载
pip install -q hf-transfer 2>/dev/null || echo "hf-transfer 安装失败，将使用常规下载"

echo "已设置以下环境变量："
echo "- HF_ENDPOINT: $HF_ENDPOINT"
echo "- HF_HUB_ENABLE_HF_TRANSFER: $HF_HUB_ENABLE_HF_TRANSFER"
echo "- HF_HUB_DOWNLOAD_TIMEOUT: $HF_HUB_DOWNLOAD_TIMEOUT"
echo "- TRANSFORMERS_OFFLINE: $TRANSFORMERS_OFFLINE"

echo "网络修复完成！"