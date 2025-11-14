#!/bin/bash

# RL Swarm 启动脚本 - 国内网络优化版 + 自定义IP配置
# 切换到脚本所在目录
cd "$(dirname "$0")"

# ----------- IP配置逻辑 -----------
echo "🔧 检查IP配置..."

# 定义配置文件路径
MANAGER_FILE="code_gen_exp/src/manager.py"
ZSHRC=~/.zshrc
ENV_VAR="RL_SWARM_IP"

# 读取 ~/.zshrc 的 RL_SWARM_IP 环境变量
if grep -q "^export $ENV_VAR=" "$ZSHRC"; then
  CURRENT_IP=$(grep "^export $ENV_VAR=" "$ZSHRC" | tail -n1 | awk -F'=' '{print $2}' | tr -d '[:space:]')
else
  CURRENT_IP=""
fi

# 交互提示（10秒超时）
if [ -n "$CURRENT_IP" ]; then
  echo -n "检测到上次使用的 IP: $CURRENT_IP，是否继续使用？(Y/n, 10秒后默认Y): "
  read -t 10 USE_LAST
  if [[ "$USE_LAST" == "" || "$USE_LAST" =~ ^[Yy]$ ]]; then
    NEW_IP="$CURRENT_IP"
  else
    read -p "请输入新的 IP（替换 38.101.215.15，直接回车跳过IP配置）: " NEW_IP
  fi
else
  read -p "未检测到历史 IP，请输入新的 IP（替换 38.101.215.15，直接回车跳过IP配置）: " NEW_IP
fi

# 如果有新IP，更新配置文件
if [ -n "$NEW_IP" ]; then
  # 每次都将环境变量中的IP写入 ~/.zshrc，保证同步
  sed -i '' "/^export $ENV_VAR=/d" "$ZSHRC" 2>/dev/null || true
  echo "export $ENV_VAR=$NEW_IP" >> "$ZSHRC"
  echo "✅ 已写入IP到配置文件：$NEW_IP"
  
  # 备份原文件
  cp "$MANAGER_FILE" "${MANAGER_FILE}.bak"
  
  # 替换 manager.py 中的 IP
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/38\.101\.215\.15/$NEW_IP/g" "$MANAGER_FILE"
  else
    # Linux
    sed -i "s/38\.101\.215\.15/$NEW_IP/g" "$MANAGER_FILE"
  fi
  
  echo "✅ 已将 manager.py 中的 IP 替换为：$NEW_IP"
  echo "原始文件已备份为：${MANAGER_FILE}.bak"
  
  # 添加路由让该 IP 直连本地网关（不走 VPN）
  if [[ "$OSTYPE" == "darwin"* || "$OSTYPE" == "linux"* ]]; then
    GATEWAY=$(netstat -nr | grep '^default' | awk '{print $2}' | head -n1)
    # 无论路由是否存在，都强制添加/覆盖
    if [[ "$OSTYPE" == "darwin"* ]]; then
      # macOS
      sudo route -n add -host $NEW_IP $GATEWAY 2>/dev/null || sudo route change -host $NEW_IP $GATEWAY 2>/dev/null
      echo "🌐 已为 $NEW_IP 强制添加直连路由（不走 VPN），网关：$GATEWAY"
    else
      # Linux
      sudo route add -host $NEW_IP $GATEWAY 2>/dev/null || sudo route change -host $NEW_IP $GATEWAY 2>/dev/null
      echo "🌐 已为 $NEW_IP 强制添加直连路由（不走 VPN），网关：$GATEWAY"
    fi
  fi
elif [ -n "$CURRENT_IP" ]; then
  echo "ℹ️ 使用上次配置的 IP：$CURRENT_IP"
else
  echo "ℹ️ 未配置IP，将使用默认IP"
fi

# ----------- 网络配置 -----------
# 设置环境变量解决国内网络问题
export HF_ENDPOINT="https://hf-mirror.com"
export TRANSFORMERS_CACHE="./model_cache"
export HF_HUB_DOWNLOAD_TIMEOUT=300
export HUGGINGFACE_ACCESS_TOKEN="None"
export SWARM_CONTRACT="0x7745a8FE4b8D2D2c3BB103F8dCae822746F35Da0"
export GENSYN_RESET_CONFIG=""
export CONNECT_TO_TESTNET=true
# 不设置MODEL_NAME，让系统根据硬件自动选择模型池中的模型
# 官方模型池：
# - 小型模型池: Qwen/Qwen2.5-Coder-0.5B-Instruct
# - 大型模型池: deepseek-ai/deepseek-coder-1.3b-instruct, Qwen/Qwen2.5-Coder-1.5B-Instruct

# 创建模型缓存目录
mkdir -p ./model_cache

# 显示当前IP配置
if [ -f "$MANAGER_FILE" ]; then
  CURRENT_CONFIGURED_IP=$(grep -o "38\.101\.215\.15" "$MANAGER_FILE" | head -n1)
  if [ "$CURRENT_CONFIGURED_IP" != "38.101.215.15" ]; then
    # 获取实际配置的IP
    ACTUAL_IP=$(grep -o "/ip4/[0-9.]*" "$MANAGER_FILE" | head -n1 | sed 's/\/ip4\///')
    echo "🌐 当前配置的IP: $ACTUAL_IP"
  else
    echo "🌐 当前使用默认IP: 38.101.215.15"
  fi
fi

echo "🌐 已设置国内网络优化环境变量："
echo "- HF_ENDPOINT: $HF_ENDPOINT"
echo "- TRANSFORMERS_CACHE: $TRANSFORMERS_CACHE"
echo "- 将根据硬件自动选择官方模型"

# 激活虚拟环境并执行 run_rl_swarm.sh
if [ -d ".venv" ]; then
  echo "🔗 正在激活虚拟环境 .venv..."
  source .venv/bin/activate
  
  # 修复依赖冲突问题
  echo "🔧 检查并修复依赖冲突..."
  pip show transformers huggingface-hub >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    # 检查版本是否冲突
    HF_VERSION=$(pip show huggingface-hub | grep "Version:" | awk '{print $2}')
    if [[ "$HF_VERSION" == "1."* ]]; then
      echo "检测到 huggingface-hub 版本冲突，正在修复..."
      pip install "huggingface-hub>=0.34.0,<1.0.0"
    fi
  fi
else
  echo "⚠️ 未找到 .venv 虚拟环境，正在自动创建..."
  if command -v python3.10 >/dev/null 2>&1; then
    PYTHON=python3.10
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
  else
    echo "❌ 未找到 Python 3.10 或 python3，请先安装。"
    exit 1
  fi
  $PYTHON -m venv .venv
  if [ -d ".venv" ]; then
    echo "✅ 虚拟环境创建成功，正在激活..."
    source .venv/bin/activate
    
    # 安装兼容版本的依赖
    echo "🔧 安装兼容版本的依赖..."
    pip install "huggingface-hub>=0.34.0,<1.0.0"
  else
    echo "❌ 虚拟环境创建失败，跳过激活。"
  fi
fi

# 执行 run_rl_swarm.sh
if [ -f "./run_rl_swarm.sh" ]; then
  echo "🚀 执行 ./run_rl_swarm.sh ..."
  ./run_rl_swarm.sh
else
  echo "❌ 未找到 run_rl_swarm.sh，无法执行。"
fi