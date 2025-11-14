#!/usr/bin/env bash

set -euo pipefail

# General arguments
ROOT=$PWD

export IDENTITY_PATH
export GENSYN_RESET_CONFIG
export CONNECT_TO_TESTNET=true
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes
export SWARM_CONTRACT="0x7745a8FE4b8D2D2c3BB103F8dCae822746F35Da0"
export HUGGINGFACE_ACCESS_TOKEN="None"
export HF_ENDPOINT="https://hf-mirror.com"  # 使用国内镜像
export HF_HUB_ENABLE_HF_TRANSFER="1"  # 启用hf-transfer加速下载
export TRANSFORMERS_CACHE="./model_cache"  # 本地模型缓存目录

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

DOCKER=${DOCKER:-""}
GENSYN_RESET_CONFIG=${GENSYN_RESET_CONFIG:-""}

# Bit of a workaround for the non-root docker container.
if [ -n "$DOCKER" ]; then
    volumes=(
        /home/gensyn/rl_swarm/modal-login/temp-data
        /home/gensyn/rl_swarm/keys
        /home/gensyn/rl_swarm/configs
        /home/gensyn/rl_swarm/logs
    )

    for volume in ${volumes[@]}; do
        sudo chown -R 1001:1001 $volume
    done
fi

# Will ignore any visible GPUs if set.
CPU_ONLY=${CPU_ONLY:-""}

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Function to clean up the server process upon exit
cleanup() {
    echo_green ">> Shutting down trainer..."

    # Remove modal credentials if they exist
    rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true

    # Kill Python training processes specifically
    pkill -f "python -m code_gen_exp.runner.swarm_launcher" 2>/dev/null || true
    pkill -f "python.*code_gen_exp" 2>/dev/null || true
    pkill -f "swarm_launcher" 2>/dev/null || true
    
    # Kill any tail processes that might be watching logs
    pkill -f "tail -f.*training_" 2>/dev/null || true
    
    # Kill modal-login/yarn processes
    pkill -f "modal-login" 2>/dev/null || true
    pkill -f "yarn.*start" 2>/dev/null || true
    pkill -f "next-server" 2>/dev/null || true
    pkill -f "node.*3000" 2>/dev/null || true
    
    # Force kill processes on port 3000
    PORT_3000_PID=$(lsof -ti:3000 2>/dev/null)
    if [ -n "$PORT_3000_PID" ]; then
        kill $PORT_3000_PID 2>/dev/null || true
        sleep 1
        # If still running, force kill
        kill -9 $PORT_3000_PID 2>/dev/null || true
    fi
    
    # Kill all processes belonging to this script's process group
    kill -- -$$ 2>/dev/null || true
    
    # Force kill if graceful shutdown doesn't work
    sleep 2
    pkill -9 -f "python.*code_gen_exp" 2>/dev/null || true
    pkill -9 -f "swarm_launcher" 2>/dev/null || true
    pkill -9 -f "tail -f.*training_" 2>/dev/null || true
    pkill -9 -f "next-server" 2>/dev/null || true
    pkill -9 -f "node.*3000" 2>/dev/null || true

    exit 0
}

errnotify() {
    echo_red ">> An error was detected while running rl-swarm. See $ROOT/logs for full logs."
}

trap cleanup EXIT
trap errnotify ERR

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn

EOF

# Create logs directory if it doesn't exist
mkdir -p "$ROOT/logs"

if [ "$CONNECT_TO_TESTNET" = true ]; then
    # Run modal_login server.
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login
    # Check if the yarn command exists; if not, install Yarn.

    # Node.js + NVM setup
    if ! command -v node > /dev/null 2>&1; then
        echo "Node.js not found. Installing NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        nvm install node
    else
        echo "Node.js is already installed: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        # Detect Ubuntu (including WSL Ubuntu) and install Yarn accordingly
        if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
            echo "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt update && sudo apt install -y yarn
        else
            echo "Yarn not found. Installing Yarn globally with npm (no profile edits)…"
            # This lands in $NVM_DIR/versions/node/<ver>/bin which is already on PATH
            npm install -g --silent yarn
        fi
    fi

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS version
        sed -i '' "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"

    else
        # Linux version
        sed -i "3s/.*/SWARM_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi


    # Docker image already builds it, no need to again.
    if [ -z "$DOCKER" ]; then
        yarn install --immutable
        echo "Building server"
        yarn build > "$ROOT/logs/yarn.log" 2>&1
    fi
    yarn start >> "$ROOT/logs/yarn.log" 2>&1 & # Run in background and log output

    SERVER_PID=$!  # Store the process ID
    echo "Started server process: $SERVER_PID"
    sleep 5


    cd ..

    echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5  # Wait for 5 seconds before checking again
    done
    echo "Found userData.json. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "Your ORG_ID is set to: $ORG_ID"

    # Wait until the API key is activated by the client
    echo "Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API key is activated! Proceeding..."
            break
        else
            echo "Waiting for API key to be activated..."
            sleep 5
        fi
    done
fi

echo_green ">> Getting requirements..."
pip install --upgrade pip

echo_green ">> Installing GenRL..."
# 解决依赖冲突问题：确保 huggingface-hub 版本与 transformers 兼容
pip install "huggingface-hub>=0.34.0,<1.0.0"

# 尝试修复 HuggingFace 连接问题
echo_green ">> Fixing HuggingFace connectivity..."
if [ -f "fix_hf_connectivity.sh" ]; then
    ./fix_hf_connectivity.sh
else
    echo "警告: fix_hf_connectivity.sh 脚本未找到，跳过网络修复"
fi

# Ollama already running as part of the docker compose file
if [ -z "$DOCKER" ]; then
    echo_green ">> Installing Ollama requires 'sudo' privileges. As an alternative, please use the Docker installation path as described in README.md"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Install brew if not already installed
        if ! command -v brew > /dev/null 2>&1; then
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        # Install ollama if not already installed
        if ! command -v ollama > /dev/null 2>&1; then
            brew install ollama
        fi
    else
        # Install ollama if not already installed
        if ! command -v ollama > /dev/null 2>&1; then
            curl -fsSL https://ollama.com/install.sh | sh -s -- -y
        fi
    fi
    # Start ollama server if not already running, check by running ollama list
    if ! ollama list > /dev/null 2>&1; then
        echo ">> Starting ollama server..."
        nohup ollama serve > /tmp/ollama.log 2>&1 &
    fi
fi

pip install -r code_gen_exp/requirements.txt

if [ ! -d "$ROOT/configs" ]; then
    mkdir "$ROOT/configs"
fi  
if [ -f "$ROOT/configs/code-gen-swarm.yaml" ]; then
    # Use cmp -s for a silent comparison. If different, backup and copy.
    if ! cmp -s "$ROOT/code_gen_exp/config/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml"; then
        if [ -z "$GENSYN_RESET_CONFIG" ]; then
            echo_green ">> Found differences in code-gen-swarm.yaml. If you would like to reset to the default, set GENSYN_RESET_CONFIG to a non-empty value."
        else
            echo_green ">> Found differences in code-gen-swarm.yaml. Backing up existing config."
            mv "$ROOT/configs/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml.bak"
            cp "$ROOT/code_gen_exp/config/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml"
        fi
    fi
else
    # If the config doesn't exist, just copy it.
    cp "$ROOT/code_gen_exp/config/code-gen-swarm.yaml" "$ROOT/configs/code-gen-swarm.yaml"
fi

if [ -n "$DOCKER" ]; then
    # Make it easier to edit the configs on Linux systems.
    sudo chmod -R 0777 /home/gensyn/rl_swarm/configs
fi

echo_green ">> Done!"

# Set default values without interactive prompts
HUGGINGFACE_ACCESS_TOKEN="None"
echo_green ">> Using default Hugging Face settings (no model push)"
echo_green ">> Using default model from config"

echo -en $RESET_TEXT
echo_green ">> Good luck in the swarm!"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

# Function to clean up before retry
cleanup_for_retry() {
    echo_green ">> Cleaning up before retry..."
    
    # Clear any lingering python processes
    pkill -f "code_gen_exp.runner.swarm_launcher" 2>/dev/null || true
    pkill -f "python.*code_gen_exp" 2>/dev/null || true
    
    # Check modal-login server status
    if [ "$CONNECT_TO_TESTNET" = true ]; then
        if lsof -i :3000 >/dev/null 2>&1; then
            echo_green ">> Modal-login server is running on port 3000"
        else
            echo_red ">> Modal-login server is not running. Restarting..."
            
            # Kill any lingering yarn/node processes
            pkill -f "modal-login" 2>/dev/null || true
            pkill -f "yarn.*start" 2>/dev/null || true
            sleep 2
            
            cd modal-login
            yarn start >> "$ROOT/logs/yarn.log" 2>&1 &
            SERVER_PID=$!
            echo ">> Restarted modal-login server with PID: $SERVER_PID"
            cd ..
        fi
    fi
    
    # Clear any lock files or temporary files
    rm -f "$ROOT"/*.lock 2>/dev/null || true
    rm -f "$ROOT"/logs/*.lock 2>/dev/null || true
    
    # Clear old training log files (keep the most recent 5)
    if [ -d "$ROOT/logs" ]; then
        find "$ROOT/logs" -name "training_*.log" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi
    
    # Wait a bit for system resources to be released
    sleep 2
}

# Function to start training
start_training() {
    echo_green ">> Starting RL Swarm training..."
    
    # Create training log file
    local training_log="$ROOT/logs/training_$(date +%Y%m%d_%H%M%S).log"
    
    # Start training process in background and get PID
    python -m code_gen_exp.runner.swarm_launcher \
        --config-path "$ROOT/code_gen_exp/config" \
        --config-name "code-gen-swarm.yaml" > "$training_log" 2>&1 &
    
    local training_pid=$!
    echo_blue ">> Training process started with PID: $training_pid"
    echo_blue ">> Training log: $training_log"
    
    # Start log display in real-time
    tail -f "$training_log" &
    local tail_pid=$!
    
    # Wait for training process to complete
    wait $training_pid
    local exit_code=$?
    
    # Stop log display
    kill $tail_pid 2>/dev/null || true
    
    echo_blue ">> Training process completed with exit code: $exit_code"
    
    # Check training log for DHT connection errors or other serious errors
    if [ -f "$training_log" ]; then
        # Check for typical error patterns
        if grep -q "TypeError: cannot unpack non-iterable NoneType object" "$training_log" 2>/dev/null; then
            echo_red ">> Detected DHT connection error in training logs"
            echo_red ">> Error details saved to: $training_log"
            return 1  # Force return error code
        fi
        
        if grep -q "Exception occurred during game run" "$training_log" 2>/dev/null; then
            echo_red ">> Detected game runtime exception in training logs"
            echo_red ">> Error details saved to: $training_log"
            return 1  # Force return error code
        fi
        
        # Check for other common error patterns
        if grep -q "Traceback (most recent call last)" "$training_log" 2>/dev/null; then
            echo_red ">> Detected Python exception in training logs"
            echo_red ">> Error details saved to: $training_log"
            return 1  # Force return error code
        fi
    fi
    
    return $exit_code
}

# Training function with retry logic
run_training_with_retry() {
    local MAX_RETRIES=60
    local RETRY_DELAY=30
    
    for attempt in $(seq 1 $MAX_RETRIES); do
        echo_green ">> Training attempt $attempt/$MAX_RETRIES"
        
        set +e  # Manually capture exit code to avoid premature exit due to -e
        start_training
        exit_code=$?
        set -e
        
        if [ $exit_code -eq 0 ]; then
            echo_green ">> Training completed successfully!"
            cleanup
            exit 0
        elif [ $exit_code -eq 137 ]; then
            echo_red ">> Training attempt $attempt was killed by system (SIGKILL)"
            echo_red ">> This usually indicates memory issues or system resource constraints"
        elif [ $exit_code -eq 143 ]; then
            echo_red ">> Training attempt $attempt was terminated (SIGTERM or timeout)"
            echo_red ">> This may indicate the process was stuck or killed due to inactivity"
         elif [ $exit_code -eq 1 ]; then
            # DHT connection failure or other runtime error
            echo_red ">> Training attempt $attempt failed with DHT/runtime error (exit code 1)"
            echo_red ">> This usually indicates network connectivity or DHT synchronization issues"
        else
            echo_red ">> Training attempt $attempt failed with exit code $exit_code"
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            cleanup_for_retry
            echo_green ">> Waiting ${RETRY_DELAY}s before retry..."
            sleep $RETRY_DELAY
        else
            echo_red ">> All $MAX_RETRIES attempts failed. Final exit code: $exit_code"
            cleanup
            exit 1
        fi
    done
}

# Now start the retry logic
run_training_with_retry