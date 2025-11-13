#!/bin/bash

# 切换到脚本所在目录
cd "$(dirname "$0")"

# 激活虚拟环境并执行 run_rl_swarm.sh
if [ -d ".venv" ]; then
  echo "🔗 正在激活虚拟环境 .venv..."
  source .venv/bin/activate
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