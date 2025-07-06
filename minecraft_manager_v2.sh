#!/bin/bash

#======================================================================================
# Minecraft Server Installer & Manager v2 (Merged)
#
# Author: Ian Legrand
# Description: A comprehensive TUI-based script to install and manage Minecraft servers.
#              Combines the full feature set of the original script with the dialog-based
#              UI, external config, and metadata-driven management of V2.
# Compatibility: Linux distributions with dialog, SDKMAN, and common utilities.
#======================================================================================

# --- Script Metadata ---
SCRIPT_VERSION="2.0"
CONFIG_DIR="$HOME/.config/minecraft-manager"
CONFIG_FILE="$CONFIG_DIR/manager.conf"

# --- Colors for Logging (for background tasks) ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'

# --- Log Functions (for non-UI messages) ---
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
    mkdir -p "$SERVER_BASE_DIR"
}

# --- Check for Dependencies ---
check_dependencies() {
    log_info "Checking for required dependencies..."
    local missing_deps=()
    local deps=("wget" "tar" "unzip" "jq" "curl" "dialog")
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

ui_infobox() { dialog --title "Info" --infobox "$1" 8 50; sleep 2; }
ui_msgbox() { dialog --title "${1:-Message}" --msgbox "$2" 10 60; }
ui_yesno() { dialog --title "$1" --yesno "$2" 8 60; return $?; }
ui_inputbox() { dialog --title "${1:-Input}" --inputbox "$2" 10 60 "$3" 2>&1 >/dev/tty; }
ui_menu() { dialog --title "$1" --menu "$2" 16 60 12 "$@" 2>&1 >/dev/tty; }
ui_fselect() { dialog --title "$1" --fselect "$2" 14 78 2>&1 >/dev/tty; }

#======================================================================================
# METADATA, JAVA, AND CRASH FUNCTIONS
#======================================================================================

write_server_meta() {
    local server_dir="$1"; shift; local server_type="$1"; shift; local mc_version="$1"; shift; local mem_alloc="$1"
    cat > "$server_dir/.server_meta" <<EOF
SERVER_TYPE=$server_type
MC_VERSION=$mc_version
MEM_ALLOC=$mem_alloc
EOF
}

read_server_meta() {
    local server_dir="$1"
    if [ -f "$server_dir/.server_meta" ]; then
        source "$server_dir/.server_meta"
    else
        SERVER_TYPE="unknown"; MC_VERSION="unknown"; MEM_ALLOC="2G"
    fi
}

resolve_java_dependency() {
    local mc_version="$1"; local required_java_version
    local major_version=$(echo "$mc_version" | cut -d. -f2)

    if [[ "$major_version" -ge 21 ]]; then required_java_version="21"
    elif [[ "$major_version" -ge 17 ]]; then required_java_version="17"
    else required_java_version="17"; fi

    log_info "Minecraft $mc_version requires Java $required_java_version."
    if sdk list java 2>/dev/null | grep -q " ${required_java_version}.* installed"; then
        return 0
    fi
    
    local latest_lts=$(sdk list java | grep -Eo "${required_java_version}\.[0-9]+\.[0-9]+-tem" | sort -V | tail -n 1)
    if [ -z "$latest_lts" ]; then
        ui_msgbox "Error" "Could not find a suitable Temurin build for Java $required_java_version via SDKMAN."
        return 1
    fi

    if ui_yesno "Java Required" "Java $required_java_version is not installed. Install version '$latest_lts' now?"; then
        ( sdk install java "$latest_lts" ) | dialog --title "Java Installation" --programbox "Installing Java $latest_lts..." 20 80
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            ui_msgbox "Error" "Failed to install Java. Please check the output."
            return 1
        fi
        ui_msgbox "Success" "Successfully installed Java $latest_lts."
    else
        return 1
    fi
}

get_java_path() {
    local version="$1"
    local java_path=$(find "$HOME/.sdkman/candidates/java" -maxdepth 1 -type d -name "${version}*" | sort -V | tail -n 1)
    if [ -n "$java_path" ]; then echo "$java_path/bin/java"; else echo "java"; fi
}

reset_crash_tracking() {
    local server_dir="$1"
    rm -f "$server_dir/.crash_count" "$server_dir/.last_crash_time" "$server_dir/.auto_restart_disabled"
    ui_msgbox "Success" "Crash tracking reset and auto-restart has been re-enabled."
}

#======================================================================================
# INSTALLATION FUNCTIONS
#======================================================================================

download_jar_with_progress() {
    local url="$1"; local dest_path="$2"; local title="$3"
    wget --progress=bar:force -O "$dest_path" "$url" 2>&1 | \
    stdbuf -o0 awk '/%/{print $2, $7}' | \
    while read -r percent time; do echo "${percent//%}"; done | \
    dialog --title "Downloading" --gauge "$title\n$url" 10 70 0
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        ui_msgbox "Error" "Download failed. Please check the URL and your connection."
        rm -f "$dest_path"; return 1
    fi
}

install_vanilla() {
    local version="$1"; local server_dir="$2"
    local manifest=$(curl -s https://launchermeta.mojang.com/mc/game/version_manifest.json)
    local version_url=$(echo "$manifest" | jq -r ".versions[] | select(.id==\"$version\") | .url")
    [ -z "$version_url" ] && { ui_msgbox "Error" "Version '$version' not found."; return 1; }
    local server_jar_url=$(curl -s "$version_url" | jq -r '.downloads.server.url')
    [ -z "$server_jar_url" ] && { ui_msgbox "Error" "Could not find server JAR for '$version'."; return 1; }
    download_jar_with_progress "$server_jar_url" "$server_dir/server.jar" "Downloading Vanilla $version"
}

install_paper() {
    local version="$1"; local server_dir="$2"
    local build=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/$version" | jq -r '.builds[-1]')
    [ -z "$build" ] || [ "$build" == "null" ] && { ui_msgbox "Error" "Could not find a build for Paper $version."; return 1; }
    local jar_name="paper-$version-$build.jar"
    local download_url="https://api.papermc.io/v2/projects/paper/versions/$version/builds/$build/downloads/$jar_name"
    download_jar_with_progress "$download_url" "$server_dir/server.jar" "Downloading Paper $version"
}

install_fabric() {
    local version="$1"; local server_dir="$2"
    local latest_installer_version=$(curl -s "https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml" | grep '<latest>' | sed 's/.*<latest>\(.*\)<\/latest>.*/\1/')
    local installer_jar_url="https://maven.fabricmc.net/net/fabricmc/fabric-installer/$latest_installer_version/fabric-installer-$latest_installer_version.jar"
    local installer_jar="$server_dir/fabric_installer.jar"
    download_jar_with_progress "$installer_jar_url" "$installer_jar" "Downloading Fabric Installer" || return 1
    local java_path=$(get_java_path "17")
    (cd "$server_dir" && "$java_path" -jar "$installer_jar" server -mcversion "$version" -downloadMinecraft) | dialog --title "Fabric Installer" --programbox "Running Fabric installer..." 20 80
    rm "$installer_jar"
    [ -f "$server_dir/fabric-server-launch.jar" ] || { ui_msgbox "Error" "Fabric installation failed."; return 1; }
}

install_forge() {
    local version="$1"; local server_dir="$2"
    local forge_versions_json=$(curl -s "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
    local forge_version=$(echo "$forge_versions_json" | jq -r ".promos[\"$version-recommended\"] // .promos[\"$version-latest\"]")
    [ -z "$forge_version" ] || [ "$forge_version" == "null" ] && { ui_msgbox "Error" "Could not find Forge build for MC $version."; return 1; }
    ui_infobox "Found Forge version: $forge_version"
    local installer_url="https://maven.minecraftforge.net/net/minecraftforge/forge/$version-$forge_version/forge-$version-$forge_version-installer.jar"
    local installer_jar="$server_dir/forge_installer.jar"
    download_jar_with_progress "$installer_url" "$installer_jar" "Downloading Forge Installer" || return 1
    local java_path_for_installer=$(get_java_path "17")
    (cd "$server_dir" && "$java_path_for_installer" -jar "$installer_jar" --installServer) | dialog --title "Forge Installer" --programbox "Running Forge installer..." 20 80
    rm -f "$installer_jar"
    if [ -f "$server_dir/run.sh" ]; then
        mv "$server_dir/run.sh" "$server_dir/start.sh.original"
    elif [ -f "$server_dir/forge-*.jar" ]; then
        mv "$server_dir/forge-"*.jar "$server_dir/server.jar" 2>/dev/null
    else
        ui_msgbox "Error" "Forge installation failed to produce a server JAR or run script."
        return 1
    fi
}

install_manual_modpack() {
    local server_dir="$1"
    local zip_path=$(ui_fselect "Select the modpack ZIP file" "$HOME/")
    [ -z "$zip_path" ] || [ ! -f "$zip_path" ] && { ui_msgbox "Error" "Invalid file selected."; return 1; }

    (unzip -o "$zip_path" -d "$server_dir") | dialog --title "Extracting" --programbox "Extracting modpack..." 20 80
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        ui_msgbox "Error" "Failed to extract modpack ZIP file."
        return 1
    fi
    ui_msgbox "Success" "Modpack extracted. You may need to run an included installer manually and then recreate the start script from the management menu."
}

install_modpack() {
    local server_dir="$1"
    local choice=$(ui_menu "Modpack Installation" "Choose modpack source:" \
        "CurseForge" "Not automated. Provides instructions." \
        "Modrinth" "Not automated. Provides instructions." \
        "Manual" "Install from a local ZIP file.")
    [ -z "$choice" ] && return 1
    case "$choice" in
        "Manual") install_manual_modpack "$server_dir" ;;
        *) ui_msgbox "Manual Installation Required" "Automated installation for $choice is not supported. Please download the server pack, place it in '$server_dir', and extract it. Then, recreate the start script from the management menu."; return 1 ;;
    esac
}

# --- Enhanced Start Script Creation (from V1) ---
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

record_crash() {
    local crash_count_file=".crash_count"; local last_crash_time_file=".last_crash_time"
    local current_time=\$(date +%s)
    [ ! -f "\$crash_count_file" ] && echo "0" > "\$crash_count_file"
    [ ! -f "\$last_crash_time_file" ] && echo "0" > "\$last_crash_time_file"
    local last_crash_time=\$(cat "\$last_crash_time_file" 2>/dev/null || echo "0")
    local crash_count=\$(cat "\$crash_count_file" 2>/dev/null || echo "0")
    if [ \$((current_time - last_crash_time)) -gt \$CRASH_WINDOW ]; then crash_count=0; fi
    crash_count=\$((crash_count + 1))
    echo "\$current_time" > "\$last_crash_time_file"
    echo "\$crash_count" > "\$crash_count_file"
    echo "[CRASH] Crash recorded. Count in last \$((CRASH_WINDOW/60)) min: \$crash_count"
    if [ \$crash_count -ge \$MAX_CRASHES ]; then
        echo "[CRASH] Max crash limit reached. Disabling auto-restart."
        touch ".auto_restart_disabled"
        return 1
    fi
    return 0
}

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
    if ! record_crash; then break; fi
    echo "Server crashed! Restarting in \$RESTART_DELAY seconds..."
    sleep \$RESTART_DELAY
done
EOF
    chmod +x "$server_dir/start.sh"
    log_success "Created/Updated start.sh with optimized settings."
}

#======================================================================================
# MANAGEMENT WORKFLOWS
#======================================================================================

backup_world() {
    local server_dir="$1"; local session_name="$2"
    local world_name=$(grep 'level-name' "$server_dir/server.properties" 2>/dev/null | cut -d'=' -f2)
    [ -z "$world_name" ] && world_name="world"
    local world_path="$server_dir/$world_name"
    [ ! -d "$world_path" ] && { ui_msgbox "Error" "World directory '$world_path' not found!"; return; }
    
    local backup_dir="$server_dir/backups"; mkdir -p "$backup_dir"
    
    if "$SESSION_MANAGER" -list | grep -q -w "$session_name"; then
        ui_infobox "Saving world..."
        "$SESSION_MANAGER" -S "$session_name" -p 0 -X stuff "save-off^M"
        "$SESSION_MANAGER" -S "$session_name" -p 0 -X stuff "save-all^M"
        sleep 5
    fi
    
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local backup_file="$backup_dir/${world_name}_backup_${timestamp}.tar.gz"
    
    (tar -czf "$backup_file" -C "$server_dir" "$world_name") | dialog --title "Backup" --gauge "Creating backup..." 10 70
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        ui_msgbox "Success" "Backup created successfully at:\n$backup_file"
    else
        ui_msgbox "Error" "Backup failed. Check permissions and disk space."
    fi

    if "$SESSION_MANAGER" -list | grep -q -w "$session_name"; then
        "$SESSION_MANAGER" -S "$session_name" -p 0 -X stuff "save-on^M"
    fi
}

update_server() {
    local server_dir="$1"
    read_server_meta "$server_dir"
    
    if [[ "$SERVER_TYPE" == "unknown" || "$SERVER_TYPE" == "Modpack" ]]; then
        ui_msgbox "Error" "Cannot auto-update this server type ($SERVER_TYPE). Please update manually."
        return
    fi
    
    local new_mc_version=$(ui_inputbox "Update Server" "Enter the NEW Minecraft version for $SERVER_TYPE (current is $MC_VERSION):" "$MC_VERSION")
    [ -z "$new_mc_version" ] && return
    
    if ! resolve_java_dependency "$new_mc_version"; then return; fi
    
    # Backup JAR
    local main_jar="server.jar"; [ -f "$server_dir/fabric-server-launch.jar" ] && main_jar="fabric-server-launch.jar"
    cp "$server_dir/$main_jar" "$server_dir/$main_jar.backup"

    local install_ok=0
    case $SERVER_TYPE in
        "Paper") install_paper "$new_mc_version" "$server_dir" && install_ok=1 ;;
        "Fabric") install_fabric "$new_mc_version" "$server_dir" && install_ok=1 ;;
        "Vanilla") install_vanilla "$new_mc_version" "$server_dir" && install_ok=1 ;;
        "Forge") install_forge "$new_mc_version" "$server_dir" && install_ok=1 ;;
    esac

    if [ "$install_ok" -eq 1 ]; then
        write_server_meta "$server_dir" "$SERVER_TYPE" "$new_mc_version" "$MEM_ALLOC"
        create_start_script "$server_dir"
        ui_msgbox "Success" "Server updated to $new_mc_version and start script recreated."
    else
        ui_msgbox "Error" "Update failed. Restoring original server JAR."
        mv "$server_dir/$main_jar.backup" "$server_dir/$main_jar"
    fi
}

manage_crash_protection() {
    local server_dir="$1"; local session_name="$2"
    while true; do
        local status_msg="Auto-Restart is ENABLED."
        [ -f "$server_dir/.auto_restart_disabled" ] && status_msg="Auto-Restart is DISABLED."
        local choice=$(ui_menu "Crash Protection: $session_name" "$status_msg" \
            "Status" "View current crash count and times." \
            "Reset" "Reset tracking and re-enable auto-restart." \
            "Toggle" "Manually enable or disable auto-restart." \
            "Back" "Return to server management.")
        case "$choice" in
            "Status")
                local count=$(cat "$server_dir/.crash_count" 2>/dev/null || echo 0)
                local time_epoch=$(cat "$server_dir/.last_crash_time" 2>/dev/null || echo 0)
                local time_str=$(date -d "@$time_epoch" 2>/dev/null || echo "N/A")
                ui_msgbox "Crash Status" "Crash count: $count (Max: $MAX_CRASHES)\nLast crash: $time_str\n$status_msg"
                ;;
            "Reset") reset_crash_tracking "$server_dir" ;;
            "Toggle")
                if [ -f "$server_dir/.auto_restart_disabled" ]; then
                    rm -f "$server_dir/.auto_restart_disabled"
                else
                    touch "$server_dir/.auto_restart_disabled"
                fi
                ;;
            "Back"|"") return ;;
        esac
    done
}

#======================================================================================
# MAIN WORKFLOWS
#======================================================================================

install_new_server() {
    local server_type=$(ui_menu "New Server" "Select server type:" "Paper" "High-performance Spigot fork." "Fabric" "Lightweight modding toolchain." "Forge" "The original modding API." "Vanilla" "The original experience." "Modpack" "Install from a ZIP file.")
    [ -z "$server_type" ] && return
    
    local mc_version_prompt="Enter Minecraft Version (e.g., 1.21.1):"
    [ "$server_type" == "Modpack" ] && mc_version_prompt="Enter the MC Version for this modpack:"
    local mc_version=$(ui_inputbox "Version" "$mc_version_prompt")
    [ -z "$mc_version" ] && return
    
    local mem_alloc=$(ui_inputbox "Memory" "Enter Memory Allocation (e.g., 4G):" "4G")
    [ -z "$mem_alloc" ] && return
    
    local server_name="${server_type,,}_${mc_version}"
    local server_dir="$SERVER_BASE_DIR/$server_name"
    
    if [ -d "$server_dir" ]; then
        if ! ui_yesno "Warning" "Server '$server_name' already exists. Overwrite? THIS IS DESTRUCTIVE."; then return; fi
        rm -rf "$server_dir"
    fi
    mkdir -p "$server_dir"
    
    if ! resolve_java_dependency "$mc_version"; then rm -rf "$server_dir"; return; fi
    
    local install_ok=0
    case $server_type in
        "Paper") install_paper "$mc_version" "$server_dir" && install_ok=1 ;;
        "Fabric") install_fabric "$mc_version" "$server_dir" && install_ok=1 ;;
        "Vanilla") install_vanilla "$mc_version" "$server_dir" && install_ok=1 ;;
        "Forge") install_forge "$mc_version" "$server_dir" && install_ok=1 ;;
        "Modpack") install_modpack "$server_dir" && install_ok=1 ;;
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
    
    [ ${#servers[@]} -eq 0 ] && { ui_msgbox "No Servers" "No servers found in $SERVER_BASE_DIR."; return; }
    
    for server_path in "${servers[@]}"; do
        read_server_meta "$server_path"
        options+=("$(basename "$server_path")" "Type: $SERVER_TYPE, MC: $MC_VERSION")
    done
    
    local choice=$(ui_menu "Manage Server" "Select a server:" "${options[@]}")
    [ -z "$choice" ] && return
    
    local server_dir="$SERVER_BASE_DIR/$choice"; local session_name="$choice"
    
    while true; do
        local status_str
        # BUG FIX: Use -list and quote variable
        if "$SESSION_MANAGER" -list 2>/dev/null | grep -q -w "$session_name"; then
            status_str="RUNNING"
        else
            status_str="STOPPED"
        fi
        
        local mgmt_choice=$(ui_menu "Managing: $choice" "Status: $status_str" \
            "Start" "Start the server." \
            "Stop" "Stop the server gracefully." \
            "Attach" "Attach to the server console." \
            "Backup" "Backup the world folder." \
            "Update" "Update server version." \
            "Crash-Settings" "Manage crash protection." \
            "Recreate-Script" "Recreate the start.sh script." \
            "Back" "Return to main menu.")
        
        case "$mgmt_choice" in
            "Start")
                ui_infobox "Starting server..."
                "$SESSION_MANAGER" -dmS "$session_name" bash "$server_dir/start.sh"
                ;;
            "Stop")
                ui_infobox "Stopping server..."
                "$SESSION_MANAGER" -S "$session_name" -p 0 -X stuff "say Server shutting down in 10s...^M"
                sleep 10
                "$SESSION_MANAGER" -S "$session_name" -p 0 -X stuff "stop^M"
                ;;
            "Attach")
                clear
                # Using exec to replace the script process with the session manager
                # This ensures the terminal state is properly restored on exit.
                if [[ "$SESSION_MANAGER" == "tmux" ]]; then
                    exec tmux attach-session -t "$session_name"
                else
                    exec screen -r "$session_name"
                fi
                ;;
            "Backup") backup_world "$server_dir" "$session_name" ;;
            "Update") update_server "$server_dir" ;;
            "Crash-Settings") manage_crash_protection "$server_dir" "$session_name" ;;
            "Recreate-Script")
                create_start_script "$server_dir"
                ui_msgbox "Success" "The start.sh script has been recreated."
                ;;
            "Back" | "") return ;;
        esac
    done
}

#======================================================================================
# SCRIPT ENTRYPOINT
#======================================================================================

clear
if [ "$EUID" -eq 0 ]; then log_error "Do not run this script as root."; exit 1; fi
load_config
check_dependencies
setup_sdkman

while true; do
    choice=$(ui_menu "Minecraft Manager v$SCRIPT_VERSION" "What would you like to do?" \
        1 "Install a new server" \
        2 "Manage an existing server" \
        3 "View installed Java versions" \
        4 "Exit")

    case $choice in
        1) install_new_server ;;
        2) manage_server ;;
        3) (sdk list java) | dialog --title "Installed Java Versions" --programbox 20 80 ;;
        4 | "") clear; log_info "Goodbye!"; exit 0 ;;
    esac
done
