#!/bin/bash

# Function to detect and set host architecture
setup_platform() {
    ARCH=$(uname -m)
    OS=$(uname -s)
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        export EMULATOR="/bin/box64"
        export DOCKER_PLATFORM="linux/arm64"
    else
        export DOCKER_PLATFORM="linux/amd64"
    fi
    # Detect OS for mods path
    if [[ "$OS" == *"MINGW"* ]] || [[ "$OS" == *"MSYS"* ]] || [[ "$OS" == *"CYGWIN"* ]]; then
        # Windows detected
        export OS_TYPE="windows"
        # Use %APPDATA% which is available in Windows bash environments
        export MODS_PATH="${APPDATA}/Factorio/mods"
        # Fallback if APPDATA isn't available
        if [ -z "$MODS_PATH" ] || [ "$MODS_PATH" == "/Factorio/mods" ]; then
            export MODS_PATH="${USERPROFILE}/AppData/Roaming/Factorio/mods"
        fi
    else
        # Assume Unix-like OS (Linux, macOS)
        export OS_TYPE="unix"
        export MODS_PATH="~/Applications/Factorio.app/Contents/Resources/mods"
    fi
    # Expand leading ~ in MODS_PATH so docker-compose gets an absolute path
    if [[ "$MODS_PATH" == ~* ]]; then
        MODS_PATH="${HOME}${MODS_PATH:1}"
    fi
    echo "Detected architecture: $ARCH, using platform: $DOCKER_PLATFORM"
    echo "Using mods path: $MODS_PATH"
}

# Function to check for docker compose command
setup_compose_cmd() {
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker not found. Please install Docker."
        exit 1
    fi
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        echo "Error: Docker Compose not found. Please install Docker Compose."
        exit 1
    fi
}

# Generate the dynamic docker-compose.yml file
generate_compose_file() {
    NUM_INSTANCES=${1:-1}
    SCENARIO=${2:-"default_lab_scenario"}
    COMMAND=${3:-"--start-server-load-scenario ${SCENARIO}"}

    # Build optional mods volume block based on ATTACH_MOD
    MODS_VOLUME=""
    if [ "$ATTACH_MOD" = true ]; then
        MODS_VOLUME=$(printf "    - source: %s\n      target: /opt/factorio/mods\n      type: bind\n" "$MODS_PATH")
    fi

    # Build optional save file volume block based on SAVE_ADDED
    SAVE_VOLUME=""
    if [ "$SAVE_ADDED" = true ]; then
        # Check if SAVE_FILE is a .zip file
        if [[ "$SAVE_FILE" != *.zip ]]; then
            echo "Error: Save file must be a .zip file."
            exit 1
        fi
        
        # Create saves directory if it doesn't exist
        mkdir -p ../../.fle/saves
        
        # Get the save file name (basename)
        SAVE_FILE_NAME=$(basename "$SAVE_FILE")
        
        # Copy the save file to the local saves directory
        cp "$SAVE_FILE" "../../.fle/saves/$SAVE_FILE_NAME"
        
        # Create variable for the container path
        CONTAINER_SAVE_PATH="/opt/factorio/saves/$SAVE_FILE_NAME"
        
        SAVE_VOLUME="    - source: ../../.fle/saves
      target: /opt/factorio/saves
      type: bind"
      COMMAND="--start-server ${SAVE_FILE_NAME}"
    fi
    
    # Validate scenario
    if [ "$SCENARIO" != "open_world" ] && [ "$SCENARIO" != "default_lab_scenario" ]; then
        echo "Error: Scenario must be either 'open_world' or 'default_lab_scenario'."
        exit 1
    fi
    
    # Validate input
    if ! [[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]]; then
        echo "Error: Number of instances must be a positive integer."
        exit 1
    fi
    
    if [ "$NUM_INSTANCES" -lt 1 ] || [ "$NUM_INSTANCES" -gt 33 ]; then
        echo "Error: Number of instances must be between 1 and 33."
        exit 1
    fi
    
    # Space Age: keep the DLC data dirs and use the DLC-enabled mod-list.
    # Default (vanilla): delete the DLC dirs so clients without Space Age can sync.
    if [ "$SPACE_AGE" = true ]; then
        DLC_STRIP=""
        MODS_DIR="mods-space-age"
        echo "Space Age DLC: enabled"
    else
        DLC_STRIP="rm -rf /opt/factorio/data/elevated-rails /opt/factorio/data/quality /opt/factorio/data/recycler /opt/factorio/data/space-age && "
        MODS_DIR="mods"
    fi

    # Create the docker-compose file
    cat > docker-compose.yml << EOF
version: '3'

services:
EOF
    
    # Rootless Docker (daemon runs as the user, no docker group): container root maps
    # to the host user, so run as root to keep user-owned bind mounts writable, and
    # skip host networking, whose "host" is rootlesskit's private namespace there.
    CONTAINER_USER="factorio"
    USE_HOST_NET="${FLE_HOST_NETWORK:-}"
    if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        CONTAINER_USER="0:0"
        if [ "$USE_HOST_NET" = "1" ]; then
            echo "FLE_HOST_NETWORK ignored: rootless Docker has no host network; using mapped ports."
            USE_HOST_NET=""
        fi
    fi

    # Add the specified number of factorio services
    for i in $(seq 0 $(($NUM_INSTANCES - 1))); do
        UDP_PORT=$((34197 + i))
        TCP_PORT=$((27000 + i))
        # per-instance server settings so the LAN list tells the servers apart
        if [ "$i" = "0" ]; then ROLE="campaign"; else ROLE="design lab $i"; fi
        sed "s/\"name\": \"\([^\"]*\)\"/\"name\": \"\1 - ${ROLE}\"/" config/server-settings.json > config/server-settings-${i}.json
        # FLE_HOST_NETWORK=1: host networking so LAN broadcasts reach real clients (the
        # Multiplayer > LAN browser); each server listens on its own host ports directly.
        if [ "$USE_HOST_NET" = "1" ]; then
            GAME_PORT=$UDP_PORT; RCON_PORT=$TCP_PORT
            NETWORK_BLOCK="    network_mode: host"
            # Bind to the LAN address so the LAN listing advertises a joinable address
            # (with a bare --port the server advertises 0.0.0.0:PORT).
            LAN_IP="${FLE_BIND_IP:-$(hostname -I | awk '{print $1}')}"
            BIND_ARG="--bind ${LAN_IP}:${GAME_PORT}"
        else
            GAME_PORT=34197; RCON_PORT=27015
            BIND_ARG="--port 34197"
            NETWORK_BLOCK="    ports:
    - ${UDP_PORT}:34197/udp
    - ${TCP_PORT}:27015/tcp"
        fi
        
        cat >> docker-compose.yml << EOF
  factorio_${i}:
    image: factoriotools/factorio:${FLE_FACTORIO_VERSION:-2.1.24}
    platform: \${DOCKER_PLATFORM:-linux/amd64}
    command: /bin/sh -c '${DLC_STRIP}exec ${EMULATOR} /opt/factorio/bin/x64/factorio ${COMMAND}
      ${BIND_ARG} --server-settings /opt/factorio/config/server-settings-${i}.json --map-gen-settings
      /opt/factorio/config/map-gen-settings.json --map-settings /opt/factorio/config/map-settings.json
      --server-banlist /opt/factorio/config/server-banlist.json --rcon-port ${RCON_PORT}
      --rcon-password "factorio" --server-whitelist /opt/factorio/config/server-whitelist.json
      --use-server-whitelist --server-adminlist /opt/factorio/config/server-adminlist.json
      --mod-directory /opt/factorio/mods --map-gen-seed 44340'
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 1024m
    entrypoint: []
${NETWORK_BLOCK}
    pull_policy: missing
    restart: unless-stopped
    user: "${CONTAINER_USER}"
    volumes:
    - source: ./scenarios
      target: /opt/factorio/scenarios
      type: bind
    - source: ./config
      target: /opt/factorio/config
      type: bind
    - source: ../../.fle/data/_screenshots
      target: /opt/factorio/script-output
      type: bind
    - source: ./${MODS_DIR}
      target: /opt/factorio/mods
      type: bind
${SAVE_VOLUME}
EOF
    done
    
    echo "Generated docker-compose.yml with $NUM_INSTANCES Factorio instance(s) using scenario $SCENARIO"
}

# Function to start Factorio cluster
start_cluster() {
    NUM_INSTANCES=$1
    SCENARIO=$2
    
    setup_platform
    setup_compose_cmd
    
    # Generate the docker-compose file
    generate_compose_file "$NUM_INSTANCES" "$SCENARIO"
    
    # Run the docker-compose file
    echo "Starting $NUM_INSTANCES Factorio instance(s) with scenario $SCENARIO..."
    export NUM_INSTANCES  # Make it available to docker-compose
    $COMPOSE_CMD -f docker-compose.yml up -d
    
    echo "Factorio cluster started with $NUM_INSTANCES instance(s) using platform $DOCKER_PLATFORM and scenario $SCENARIO"
}

# Function to stop Factorio cluster
stop_cluster() {
    setup_compose_cmd
    
    if [ -f "docker-compose.yml" ]; then
        echo "Stopping Factorio cluster..."
        $COMPOSE_CMD -f docker-compose.yml down
        echo "Cluster stopped."
    else
        echo "Error: docker-compose.yml not found. No cluster to stop."
        exit 1
    fi
}

# Function to restart Factorio cluster
restart_cluster() {
    setup_compose_cmd
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "Error: docker-compose.yml not found. No cluster to restart."
        exit 1
    fi
    
    echo "Restarting existing Factorio services without regenerating docker-compose..."
    $COMPOSE_CMD -f docker-compose.yml restart
    echo "Factorio services restarted."
}

# Show usage information
show_help() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  start         Start Factorio instances (default command)"
    echo "  stop          Stop all running instances"
    echo "  restart       Restart the current cluster with the same configuration"
    echo "  help          Show this help message"
    echo ""
    echo "Options:"
    echo "  -n NUMBER     Number of Factorio instances to run (1-33, default: 1)"
    echo "  -s SCENARIO   Scenario to run (open_world or default_lab_scenario, default: default_lab_scenario)"
    echo "  -sv SAVE_FILE, --use_save SAVE_FILE Use a .zip save file from factorio"
    echo "  -m, --attach_mods Attach mods to the instances"
    echo "  --space-age   Run with the Space Age DLC enabled (or set FLE_SPACE_AGE=1)"
    echo ""
    echo "Examples:"
    echo "  $0                           Start 1 instance with default_lab_scenario"
    echo "  $0 -n 5                      Start 5 instances with default_lab_scenario"
    echo "  $0 -n 3 -s open_world        Start 3 instances with open_world"
    echo "  $0 start -n 10 -s open_world Start 10 instances with open_world"
    echo "  $0 stop                      Stop all running instances"
    echo "  $0 restart                   Restart the current cluster"
}

# Main script execution
COMMAND="start"
NUM_INSTANCES=1
SCENARIO="default_lab_scenario"
SAVE_FILE=""
EMULATOR=""

# Boolean: attach mods or not
ATTACH_MOD=false
# Boolean: run with the Space Age DLC (also enabled by FLE_SPACE_AGE=1)
case "${FLE_SPACE_AGE,,}" in 1|true|yes) SPACE_AGE=true ;; *) SPACE_AGE=false ;; esac
SAVE_ADDED=false

# Parse args (supporting both short and long options)
while [[ $# -gt 0 ]]; do
  case "$1" in
    start|stop|restart|help)
      COMMAND="$1"
      shift
      ;;
    -n|--number)
      if [[ -z "$2" || "$2" == -* ]]; then
        echo "Error: -n|--number requires an argument."
        show_help
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: Number of instances must be a positive integer."
        exit 1
      fi
      NUM_INSTANCES="$2"
      shift 2
      ;;
    -s|--scenario)
      if [[ -z "$2" || "$2" == -* ]]; then
        echo "Error: -s|--scenario requires an argument."
        show_help
        exit 1
      fi
      case "$2" in
        open_world|default_lab_scenario)
          SCENARIO="$2"
          ;;
        *)
          echo "Error: Scenario must be either 'open_world' or 'default_lab_scenario'."
          exit 1
          ;;
      esac
      shift 2
      ;;
    -sv|--use_save)
      if [[ -z "$2" || "$2" == -* ]]; then
        echo "Error: -sv|--use_save requires an argument."
        show_help
        exit 1
      fi
      if [[ ! -f "$2" ]]; then
        echo "Error: Save file '$2' does not exist."
        exit 1
      fi
      SAVE_FILE="$2"
      SAVE_ADDED=true
      shift 2
      ;;
    -m|--attach_mods)
      ATTACH_MOD=true
      shift
      ;;
    --space-age)
      SPACE_AGE=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: Invalid option: $1"
      show_help
      exit 1
      ;;
    *)
      # Unrecognized positional; ignore and continue
      shift
      ;;
  esac
done

# Execute the appropriate command
case "$COMMAND" in
    start)
        start_cluster "$NUM_INSTANCES" "$SCENARIO"
        ;;
    stop)
        stop_cluster
        ;;
    restart)
        restart_cluster
        ;;
    help)
        show_help
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_help
        exit 1
        ;;
esac
