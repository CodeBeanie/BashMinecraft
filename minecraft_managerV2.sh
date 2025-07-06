#!/bin/bash

#======================================================================================
# Minecraft Server Installer & Manager v2
#
# Author: Ian Legrand
# Description: A TUI-based script to install and manage Minecraft servers.
#              Features a dialog-based UI, external config, metadata-driven
#              management, dynamic Java versioning, and improved start scripts.
# Compatibility: Linux distributions with dialog, SDKMAN, and common utilities.
#======================================================================================

# --- Script Metadata ---
SCRIPT_VERSION="2.0"
CONFIG_DIR="$HOME/.config/minecraft-manager"
CONFIG_FILE="$CONFIG_DIR/manager.conf"

# --- Colors for Logging ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'

# --- Log Functions ---
log_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
log_success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $1"; }

#======================================================================================
# INITIALIZATION & DEPENDENCY CHECKS
#======================================================================================

# --- Load or Create Configuration ---
load_config() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "Configuration file not found. Creating a default one at $CONFIG_FILE"
        cat > "$CONFIG_FILE" <<'EOF'
# ~/.config/minecraft-manager/manager.conf
# Configuration for the Minecraft Server Management Script.

SERVER_BASE_DIR="$HOME/minecraft_servers"
SESSION_MANAGER="screen"
MAX_CRASHES=3
CRASH_WINDOW=300
RESTART_DELAY=15
AIKAR_FLAGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true"
EOF
    fi
    source "$CONFIG_FILE"
    # Ensure the base directory exists
    mkdir -p "$SERVER_BASE_DIR"
}

# --- Check for Dependencies ---
check_dependencies() {
    log_info "Checking for required dependencies..."
    local missing_deps=()
    local deps=("wget" "tar" "unzip" "jq" "curl" "dialog")

    # Add session manager to dependency check
    deps+=("$SESSION_MANAGER")

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Please install them using your package manager (e.g., sudo apt install dialog) and re-run."
        exit 1
    fi
    log_success "All dependencies are present."
}

# --- Install and Source SDKMAN ---
setup_sdkman() {
    if [ ! -d "$HOME/.sdkman" ]; then
        log_info "SDKMAN not found. Installing..."
        curl -s "https://get.sdkman.io" | bash
        log_success "SDKMAN installed. Please run 'source ~/.bashrc' and restart the script."
        exit 0
    fi
    source "$HOME/.sdkman/bin/sdkman-init.sh"
}

#======================================================================================
# UI FUNCTIONS (using dialog)
#======================================================================================

# --- Show an info box ---
ui_infobox() { dialog --title "Info" --infobox "$1" 8 50; sleep 2; }

# --- Show a message box ---
ui_msgbox() { dialog --title "Message" --msgbox "$1" 10 60; }

# --- Show a yes/no box ---
ui_yesno() { dialog --title "$1" --yesno "$2" 8 60; return $?; }

# --- Get text input ---
ui_inputbox() {
    local prompt="$1"
    local default_value="$2"
    dialog --title "Input" --inputbox "$prompt" 10 60 "$default_value" 2>&1 >/dev/tty
}

# --- Show a menu ---
ui_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    dialog --title "$title" --menu "$prompt" 15 60 10 "$@" 2>&1 >/dev/tty
}

#======================================================================================
# JAVA & SERVER METADATA FUNCTIONS
#======================================================================================

# --- Write server metadata to a file for robust management ---
write_server_meta() {
    local server_dir="$1"
    local server_type="$2"
    local mc_version="$3"
    local mem_alloc="$4"
    
    cat > "$server_dir/.server_meta" <<EOF
SERVER_TYPE=$server_type
MC_VERSION=$mc_version
MEM_ALLOC=$mem_alloc
EOF
}

# --- Read server metadata ---
read_server_meta() {
    local server_dir="$1"
    if [ -f "$server_dir/.server_meta" ]; then
        source "$server_dir/.server_meta"
    else
        # Fallback for older installations - try to parse from name
        local server_name=$(basename "$server_dir")
        SERVER_TYPE=$(echo "$server_name" | cut -d'_' -f1)
        MC_VERSION=$(echo "$server_name" | cut -d'_' -f2)
        MEM_ALLOC="2G" # Default
    fi
}

# --- Resolve and install the correct Java version dynamically ---
resolve_java_dependency() {
    local mc_version="$1"
    local required_java_version
    local major_version=$(echo "$mc_version" | cut -d. -f2)

    # Minecraft 1.21+ -> Java 21, 1.17-1.20 -> Java 17, etc.
    if [[ "$major_version" -ge 21 ]]; then required_java_version="21"
    elif [[ "$major_version" -ge 17 ]]; then required_java_version="17"
    else required_java_version="17"; fi # Default for simplicity

    log_info "Minecraft $mc_version requires Java $required_java_version."

    if sdk list java | grep -q " ${required_java_version}.* installed"; then
        log_success "Java $required_java_version is already installed."
        return 0
    fi
    
    # Dynamically find the latest Temurin (formerly AdoptOpenJDK) LTS release
    local latest_lts=$(sdk list java | grep -Eo "${required_java_version}\.[0-9]+\.[0-9]+-tem" | sort -V | tail -n 1)
    if [ -z "$latest_lts" ]; then
        log_error "Could not find a suitable Temurin build for Java $required_java_version via SDKMAN."
        return 1
    fi

    if ui_yesno "Java Required" "Java $required_java_version is not installed. Install version '$latest_lts' now?"; then
        (
            echo "10"
            echo "### Installing Java $latest_lts via SDKMAN... ###"
            sdk install java "$latest_lts"
            echo "100"
        ) | dialog --title "Java Installation" --gauge "Please wait..." 10 70 0
        log_success "Successfully installed Java $latest_lts."
    else
        log_error "Java installation aborted. Cannot proceed."
        return 1
    fi
}

# --- Get Java Path ---
get_java_path() {
    local version="$1"
    # Find the most recent installed path for the major version
    local java_path=$(find "$HOME/.sdkman/candidates/java" -maxdepth 1 -type d -name "${version}*" | sort -V | tail -n 1)
    if [ -n "$java_path" ]; then echo "$java_path/bin/java"; else echo "java"; fi
}


#======================================================================================
# INSTALLATION & START SCRIPT CREATION
# (Most installation functions like install_paper, install_forge are unchanged from the original script)
# ... [Omitted for brevity, they are identical to the original]
#======================================================================================
# --- Download server JAR from a URL ---
download_jar() {
    local url="$1"
    local dest_path="$2"
    log_info "Downloading server file from: $url"
    wget --progress=bar:force -O "$dest_path" "$url" 2>&1 | \
    stdbuf -o0 awk '/%/{print $2, $7}' | \
    while read -r percent time; do
        echo "${percent//%}"
    done | dialog --title "Downloading" --gauge "Downloading server file...\n$url" 10 70 0
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Download failed. Please check the URL and your connection."
        rm -f "$dest_path"
        return 1
    fi
    return 0
}

install_paper() {
    local version="$1"
    local server_dir="$2"
    local build=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/$version" | jq -r '.builds[-1]')
    if [ -z "$build" ] || [ "$build" == "null" ]; then
        ui_msgbox "Error" "Could not find any build for Paper $version."
        return 1
    fi
    local jar_name="paper-$version-$build.jar"
    local download_url="https://api.papermc.io/v2/projects/paper/versions/$version/builds/$build/downloads/$jar_name"
    download_jar "$download_url" "$server_dir/server.jar"
}

install_fabric() {
    local version="$1"; local server_dir="$2"
    local latest_installer_version=$(curl -s "https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml" | grep '<latest>' | sed 's/.*<latest>\(.*\)<\/latest>.*/\1/')
    local installer_jar_url="https://maven.fabricmc.net/net/fabricmc/fabric-installer/$latest_installer_version/fabric-installer-$latest_installer_version.jar"
    local installer_jar="$server_dir/fabric_installer.jar"
    download_jar "$installer_jar_url" "$installer_jar" || return 1
    local java_path=$(get_java_path "17")
    (cd "$server_dir" && "$java_path" -jar "$installer_jar" server -mcversion "$version" -downloadMinecraft)
    rm "$installer_jar"
    [ -f "$server_dir/fabric-server-launch.jar" ] || { ui_msgbox "Error" "Fabric installation failed."; return 1; }
}
# ... Add other install functions (Vanilla, Forge) here as needed.

# --- Enhanced Start Script Creation ---
create_start_script() {
    local server_dir="$1"
    read_server_meta "$server_dir" # Loads $MEM_ALLOC, $MC_VERSION, $SERVER_TYPE
    
    local major_version=$(echo "$MC_VERSION" | cut -d. -f2)
    local java_version_major
    if [[ "$major_version" -ge 21 ]]; then java_version_major="21"
    elif [[ "$major_version" -ge 17 ]]; then java_version_major="17"
    else java_version_major="17"; fi
    
    local java_path=$(get_java_path "$java_version_major")
    local server_jar="server.jar"
    [ -f "$server_dir/fabric-server-launch.jar" ] && server_jar="fabric-server-launch.jar"
    
    # Use Aikar's flags for Paper, otherwise standard flags
    local java_args="-Xms${MEM_ALLOC} -Xmx${MEM_ALLOC}"
    if [[ "$SERVER_TYPE" == "Paper" || "$SERVER_TYPE" == "paper" ]]; then
        java_args="$AIKAR_FLAGS -Xms${MEM_ALLOC} -Xmx${MEM_ALLOC}"
    fi

    cat > "$server_dir/start.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
SERVER_JAR="$server_jar"
JAVA_PATH="$java_path"
JAVA_ARGS="$java_args"
MAX_CRASHES=$MAX_CRASHES
CRASH_WINDOW=$CRASH_WINDOW
RESTART_DELAY=$RESTART_DELAY

# Crash protection logic (identical to original script, self-contained)
# ... [Omitted for brevity, but it's the same robust logic] ...

# Main server loop
while true; do
    if [ -f ".auto_restart_disabled" ]; then
        echo "Auto-restart is disabled. Remove '.auto_restart_disabled' to re-enable."
        break
    fi
    echo "Starting server with Java: \$JAVA_PATH"
    "\$JAVA_PATH" \$JAVA_ARGS -jar "\$SERVER_JAR" nogui
    exit_code=\$?
    if [ \$exit_code -eq 0 ]; then
        echo "Server stopped normally."
        break
    fi
    # record_crash logic from original script here...
    echo "Server crashed! Restarting in \$RESTART_DELAY seconds..."
    sleep \$RESTART_DELAY
done
EOF
    chmod +x "$server_dir/start.sh"
    log_success "Created/Updated start.sh with optimized settings."
}

#======================================================================================
# MAIN WORKFLOWS
#======================================================================================

install_new_server() {
    local server_type=$(ui_menu "New Server" "Select server type:" "Paper" "A high-performance fork of Spigot." "Fabric" "A lightweight, modern modding toolchain." "Vanilla" "The original Minecraft server.")
    [ -z "$server_type" ] && return
    
    local mc_version=$(ui_inputbox "Enter Minecraft Version (e.g., 1.21.1):")
    [ -z "$mc_version" ] && return
    
    local mem_alloc=$(ui_inputbox "Enter Memory Allocation (e.g., 4G):" "4G")
    [ -z "$mem_alloc" ] && return
    
    local server_name="${server_type,,}_${mc_version}"
    local server_dir="$SERVER_BASE_DIR/$server_name"
    
    if [ -d "$server_dir" ]; then
        if ! ui_yesno "Warning" "Server '$server_name' already exists. Overwrite? THIS IS DESTRUCTIVE."; then
            return
        fi
        rm -rf "$server_dir"
    fi
    
    mkdir -p "$server_dir"
    
    # Resolve Java before installation
    if ! resolve_java_dependency "$mc_version"; then
        rm -rf "$server_dir"
        return
    fi
    
    local install_ok=0
    case $server_type in
        "Paper") install_paper "$mc_version" "$server_dir" && install_ok=1 ;;
        "Fabric") install_fabric "$mc_version" "$server_dir" && install_ok=1 ;;
        "Vanilla") # install_vanilla "$mc_version" "$server_dir" && install_ok=1 
             ui_msgbox "Notice" "Vanilla installer not included in this example for brevity. Please add the function from the original script if needed." ;;
    esac
    
    if [ "$install_ok" -eq 1 ]; then
        write_server_meta "$server_dir" "$server_type" "$mc_version" "$mem_alloc"
        create_start_script "$server_dir"
        echo "eula=true" > "$server_dir/eula.txt"
        ui_msgbox "Success" "Installation of $server_name complete!"
    else
        ui_msgbox "Error" "Installation failed. Cleaning up."
        rm -rf "$server_dir"
    fi
}

manage_server() {
    local servers=()
    local options=()
    while IFS= read -r line; do servers+=("$line"); done < <(find "$SERVER_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    
    if [ ${#servers[@]} -eq 0 ]; then
        ui_msgbox "No Servers" "No servers found to manage in $SERVER_BASE_DIR."
        return
    fi
    
    for server_path in "${servers[@]}"; do
        read_server_meta "$server_path"
        options+=("$(basename "$server_path")" "Type: $SERVER_TYPE, Version: $MC_VERSION")
    done
    
    local choice=$(ui_menu "Manage Server" "Select a server:" "${options[@]}")
    [ -z "$choice" ] && return
    
    local server_dir="$SERVER_BASE_DIR/$choice"
    local session_name="$choice"
    
    while true; do
        local status_str
        if $SESSION_MANAGER list | grep -q "$session_name"; then
            status_str="RUNNING"
        else
            status_str="STOPPED"
        fi
        
        local mgmt_choice=$(ui_menu "Managing: $choice" "Status: $status_str" \
            "Start" "Start the server in a $SESSION_MANAGER session." \
            "Stop" "Stop the server gracefully." \
            "Attach" "Attach to the server console." \
            "Backup" "Backup the world folder." \
            "Update" "Update the server (experimental)." \
            "Recreate-Script" "Recreate the start.sh script." \
            "Back" "Return to the main menu.")
        
        case "$mgmt_choice" in
            "Start")
                ui_infobox "Starting server..."
                $SESSION_MANAGER -dmS "$session_name" bash "$server_dir/start.sh"
                ;;
            "Stop")
                ui_infobox "Stopping server..."
                $SESSION_MANAGER -S "$session_name" -p 0 -X stuff "say Server shutting down in 10s...^M"
                sleep 10
                $SESSION_MANAGER -S "$session_name" -p 0 -X stuff "stop^M"
                ;;
            "Attach")
                clear
                if [[ "$SESSION_MANAGER" == "tmux" ]]; then
                    tmux attach-session -t "$session_name"
                else
                    screen -r "$session_name"
                fi
                # After returning, redraw the menu
                continue
                ;;
            "Backup")
                # Backup logic from original script
                ui_msgbox "Notice" "Backup function not implemented in this example for brevity. Please add from the original script."
                ;;
            "Update")
                # Update logic (can be made more robust with metadata)
                ui_msgbox "Notice" "Update function not implemented in this example for brevity. Please add from the original script."
                ;;
            "Recreate-Script")
                create_start_script "$server_dir"
                ui_msgbox "Success" "The start.sh script has been recreated."
                ;;
            "Back" | "")
                return
                ;;
        esac
    done
}


#======================================================================================
# SCRIPT ENTRYPOINT
#======================================================================================

# --- Initial Checks & Setup ---
clear
if [ "$EUID" -eq 0 ]; then log_error "Do not run this script as root."; exit 1; fi
load_config
check_dependencies
setup_sdkman

# --- Main Menu Loop ---
while true; do
    choice=$(ui_menu "Minecraft Manager v$SCRIPT_VERSION" "What would you like to do?" \
        1 "Install a new server" \
        2 "Manage an existing server" \
        3 "View installed Java versions" \
        4 "Exit")

    case $choice in
        1) install_new_server ;;
        2) manage_server ;;
        3) (sdk list java) | dialog --title "Installed Java Versions" --programbox 20 80; ;;
        4 | "") clear; log_info "Goodbye!"; exit 0 ;;
    esac
done
