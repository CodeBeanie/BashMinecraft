#!/bin/bash

#==============================================================================
# Minecraft Server Installer & Manager
#
# Author: Ian Legrand
# Description: A comprehensive script to install and manage various
#              Minecraft servers (Vanilla, Fabric, Forge, Spigot, Paper, Modpacks).
#              Includes automatic Java version detection and installation via SDKMAN.
#              Features crash protection and auto-restart functionality.
# Compatibility: Linux distributions with SDKMAN support.
#==============================================================================

# --- Configuration ---
# Base directory where all Minecraft servers will be installed.
SERVER_BASE_DIR="$HOME/minecraft_servers"

# Crash protection settings
MAX_CRASHES=3           # Maximum crashes before disabling auto-restart
CRASH_WINDOW=300        # Time window in seconds to count crashes (5 minutes)
RESTART_DELAY=30        # Delay between restart attempts in seconds

# --- Colors for Output ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

#==============================================================================
# UTILITY AND DEPENDENCY FUNCTIONS
#==============================================================================

# --- Log functions for styled output ---
log_info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
log_success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $1"; }

# --- Check for non-Java dependencies ---
check_base_dependencies() {
    log_info "Checking for required base dependencies..."
    local missing_deps=()
    local deps=("wget" "tar" "screen" "tmux" "unzip" "jq" "curl")

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "The following dependencies are missing: ${missing_deps[*]}"
        read -p "Do you want to try and install them now? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y "${missing_deps[@]}"
            elif command -v yum &> /dev/null; then
                sudo yum install -y "${missing_deps[@]}"
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y "${missing_deps[@]}"
            elif command -v pacman &> /dev/null; then
                sudo pacman -S --noconfirm "${missing_deps[@]}"
            else
                log_error "Could not determine package manager. Please install dependencies manually."
                exit 1
            fi

            # Re-check after installation attempt
            for cmd in "${missing_deps[@]}"; do
                 if ! command -v "$cmd" &> /dev/null; then
                    log_error "Failed to install '$cmd'. Please install it manually and re-run the script."
                    exit 1
                 fi
            done
            log_success "All base dependencies are now installed."
        else
            log_error "Aborting. Please install the missing dependencies manually."
            exit 1
        fi
    else
        log_success "All base dependencies are present."
    fi
}

# --- Install SDKMAN if not present ---
install_sdkman() {
    if [ ! -d "$HOME/.sdkman" ]; then
        log_info "SDKMAN not found. Installing SDKMAN..."
        curl -s "https://get.sdkman.io" | bash
        if [ $? -ne 0 ]; then
            log_error "Failed to install SDKMAN. Please install it manually from https://sdkman.io/"
            exit 1
        fi
        log_success "SDKMAN installed successfully."
        log_info "Please restart your terminal or run 'source ~/.bashrc' and then re-run this script."
        exit 0
    fi
}

# --- Source SDKMAN ---
source_sdkman() {
    if [ -f "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
        source "$HOME/.sdkman/bin/sdkman-init.sh"
    else
        log_error "SDKMAN initialization script not found. Please reinstall SDKMAN."
        exit 1
    fi
}

# --- Determine and install the correct Java version for a given MC version ---
resolve_java_dependency() {
    local mc_version="$1"
    local required_java_version=""

    # Extract major and minor version numbers (e.g., from "1.20.4")
    local major_version=$(echo "$mc_version" | cut -d. -f1)
    local minor_version=$(echo "$mc_version" | cut -d. -f2)

    # Determine required Java version based on Minecraft version
    if [[ "$major_version" -eq 1 && "$minor_version" -ge 21 ]]; then
        required_java_version="21"
    elif [[ "$major_version" -eq 1 && "$minor_version" -ge 18 ]]; then
        required_java_version="17"
    elif [[ "$major_version" -eq 1 && "$minor_version" -eq 17 ]]; then
        required_java_version="17"
    else
        # Default to Java 17 for older versions
        required_java_version="17"
    fi

    log_info "Minecraft version ${C_CYAN}$mc_version${C_RESET} requires Java ${C_CYAN}$required_java_version${C_RESET}."

    # Check if required Java version is installed via SDKMAN
    if sdk list java 2>/dev/null | grep -q "${required_java_version}.*installed"; then
        log_success "Java $required_java_version is already installed via SDKMAN."
        return 0
    fi

    log_info "Java $required_java_version not found. Installing via SDKMAN..."
    read -p "Do you want to install Java $required_java_version now? (y/n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        # Install the latest LTS version of the required Java
        local java_identifier
        case $required_java_version in
            "17") java_identifier="17.0.9-tem" ;;
            "21") java_identifier="21.0.1-tem" ;;
            *) java_identifier="${required_java_version}-tem" ;;
        esac

        log_info "Installing Java $java_identifier..."
        sdk install java "$java_identifier"
        if [ $? -ne 0 ]; then
            log_error "Failed to install Java $java_identifier. Please install it manually using: sdk install java $java_identifier"
            return 1
        fi
        log_success "Successfully installed Java $java_identifier."
        return 0
    else
        log_error "Java installation aborted. Cannot proceed with server setup."
        return 1
    fi
}

# --- Get Java path for specific version ---
get_java_path() {
    local version="$1"
    local java_path
    
    # Find the Java installation path for the required version
    java_path=$(find "$HOME/.sdkman/candidates/java" -name "*${version}*" -type d | head -n 1)
    
    if [ -n "$java_path" ] && [ -d "$java_path" ]; then
        echo "$java_path/bin/java"
    else
        # Fallback to system java
        echo "java"
    fi
}

# --- Prompt for user input with validation ---
prompt_input() {
    local prompt_text="$1"
    local var_name="$2"
    while true; do
        read -p "$prompt_text" "$var_name"
        if [ -n "${!var_name}" ]; then
            break
        else
            log_warning "Input cannot be empty."
        fi
    done
}

#==============================================================================
# CRASH PROTECTION FUNCTIONS
#==============================================================================

# --- Initialize crash tracking ---
init_crash_tracking() {
    local server_dir="$1"
    local crash_file="$server_dir/.crash_tracking"
    echo "0" > "$crash_file"
    echo "$(date +%s)" > "$server_dir/.last_crash_time"
}

# --- Record a crash ---
record_crash() {
    local server_dir="$1"
    local crash_file="$server_dir/.crash_tracking"
    local crash_count_file="$server_dir/.crash_count"
    local current_time=$(date +%s)
    
    # Initialize if files don't exist
    [ ! -f "$crash_file" ] && echo "0" > "$crash_file"
    [ ! -f "$crash_count_file" ] && echo "0" > "$crash_count_file"
    
    local last_crash_time=$(cat "$crash_file" 2>/dev/null || echo "0")
    local crash_count=$(cat "$crash_count_file" 2>/dev/null || echo "0")
    
    # Reset crash count if outside the crash window
    if [ $((current_time - last_crash_time)) -gt $CRASH_WINDOW ]; then
        crash_count=0
    fi
    
    crash_count=$((crash_count + 1))
    echo "$current_time" > "$crash_file"
    echo "$crash_count" > "$crash_count_file"
    
    log_warning "Server crash recorded. Crash count in last $((CRASH_WINDOW/60)) minutes: $crash_count"
    
    if [ $crash_count -ge $MAX_CRASHES ]; then
        log_error "Maximum crash limit ($MAX_CRASHES) reached. Disabling auto-restart."
        touch "$server_dir/.auto_restart_disabled"
        return 1
    fi
    
    return 0
}

# --- Check if auto-restart is disabled ---
is_auto_restart_disabled() {
    local server_dir="$1"
    [ -f "$server_dir/.auto_restart_disabled" ]
}

# --- Reset crash tracking ---
reset_crash_tracking() {
    local server_dir="$1"
    rm -f "$server_dir/.crash_tracking" "$server_dir/.crash_count" "$server_dir/.auto_restart_disabled"
    log_success "Crash tracking reset."
}

#==============================================================================
# SERVER INSTALLATION FUNCTIONS
#==============================================================================

# --- Download server JAR from a URL ---
download_jar() {
    local url="$1"
    local dest_path="$2"
    log_info "Downloading server file from: $url"
    if wget -q --show-progress -O "$dest_path" "$url"; then
        log_success "Download complete."
    else
        log_error "Failed to download server file. Please check the URL and your connection."
        rm -f "$dest_path" # Clean up partial download
        exit 1
    fi
}

# --- Install Vanilla Server ---
install_vanilla() {
    local version="$1"
    local server_dir="$2"
    log_info "Fetching available Vanilla versions..."
    manifest=$(wget -qO- https://launchermeta.mojang.com/mc/game/version_manifest.json)
    if [ -z "$manifest" ]; then
        log_error "Could not fetch Minecraft version manifest."
        return 1
    fi
    version_url=$(echo "$manifest" | jq -r ".versions[] | select(.id==\"$version\") | .url")
    if [ -z "$version_url" ]; then
        log_error "Version '$version' not found."
        log_info "Available release versions: $(echo "$manifest" | jq -r '.versions[] | select(.type=="release") | .id' | tr '\n' ' ')"
        return 1
    fi
    server_jar_url=$(wget -qO- "$version_url" | jq -r '.downloads.server.url')
    if [ -z "$server_jar_url" ]; then
        log_error "Could not find server JAR URL for version '$version'."
        return 1
    fi
    download_jar "$server_jar_url" "$server_dir/server.jar"
}

# --- Install PaperMC Server ---
install_paper() {
    local version="$1"
    local server_dir="$2"
    log_info "Fetching latest Paper build for version $version..."
    build=$(wget -qO- "https://api.papermc.io/v2/projects/paper/versions/$version/builds" | jq -r '.builds | map(select(.channel=="default")) | .[-1].build')
    if [ -z "$build" ] || [ "$build" == "null" ]; then
        log_error "Could not find a stable build for Paper $version."
        log_info "Check available versions at https://papermc.io/downloads"
        return 1
    fi
    local jar_name="paper-$version-$build.jar"
    local download_url="https://api.papermc.io/v2/projects/paper/versions/$version/builds/$build/downloads/$jar_name"
    download_jar "$download_url" "$server_dir/server.jar"
}

# --- Install Forge Server ---
install_forge() {
    local version="$1"
    local server_dir="$2"
    log_info "Fetching available Forge versions for Minecraft $version..."
    forge_versions_json=$(wget -qO- "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
    if [ -z "$forge_versions_json" ]; then
        log_error "Could not fetch Forge version data."
        return 1
    fi
    forge_version=$(echo "$forge_versions_json" | jq -r ".promos[\"$version-recommended\"] // .promos[\"$version-latest\"]")
    if [ -z "$forge_version" ] || [ "$forge_version" == "null" ]; then
        log_error "Could not find a recommended or latest Forge build for Minecraft $version."
        log_info "Please check available versions manually at https://files.minecraftforge.net/"
        return 1
    fi
    log_info "Found Forge version: $forge_version"
    local installer_url="https://maven.minecraftforge.net/net/minecraftforge/forge/$version-$forge_version/forge-$version-$forge_version-installer.jar"
    local installer_jar="$server_dir/forge_installer.jar"
    download_jar "$installer_url" "$installer_jar"
    log_info "Running Forge installer..."
    local java_path=$(get_java_path "17")
    (cd "$server_dir" && "$java_path" -jar "$installer_jar" --installServer)
    if [ $? -ne 0 ]; then log_error "Forge installer failed. Check the output above."; return 1; fi
    # Newer forge versions use a run.sh script.
    if [ -f "$server_dir/run.sh" ]; then
        log_info "Forge created a run.sh script. Adapting it."
        mv "$server_dir/run.sh" "$server_dir/start.sh"
        chmod +x "$server_dir/start.sh"
        rm "$installer_jar"
        return 0 # Skip default start script creation
    else
        log_error "Could not find the installed Forge server JAR or run.sh. Installation may have failed."
        return 1
    fi
}

# --- Install Fabric Server ---

install_fabric() {
    local version="$1"
    local server_dir="$2"
    log_info "Fetching Fabric installer..."
    
    # Get latest Fabric installer version
    local installer_url="https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml"
    local latest_installer_version=$(wget -qO- "$installer_url" | grep '<latest>' | sed -e 's/.*<latest>\(.*\)<\/latest>.*/\1/')
    if [ -z "$latest_installer_version" ]; then 
        log_error "Could not determine the latest Fabric installer version."
        return 1
    fi
    
    local installer_jar_url="https://maven.fabricmc.net/net/fabricmc/fabric-installer/$latest_installer_version/fabric-installer-$latest_installer_version.jar"
    local installer_jar="$server_dir/fabric_installer.jar"
    download_jar "$installer_jar_url" "$installer_jar"
    
    log_info "Running Fabric installer..."
    local java_path=$(get_java_path "17")
    
    # Run the installer with proper flags
    (cd "$server_dir" && "$java_path" -jar "$installer_jar" server -mcversion "$version" -downloadMinecraft -dir .)
    
    if [ $? -ne 0 ]; then 
        log_error "Fabric installer failed."
        return 1
    fi
    
    # Clean up installer
    rm -f "$installer_jar"
    
    # The Fabric installer creates fabric-server-launch.jar as the main server jar
    if [ -f "$server_dir/fabric-server-launch.jar" ]; then
        log_success "Fabric server installed successfully."
        log_info "Fabric uses fabric-server-launch.jar as the main server file."
        # Don't rename it - keep it as fabric-server-launch.jar
    else
        log_error "Fabric installation failed - fabric-server-launch.jar not found."
        log_info "Contents of server directory:"
        ls -la "$server_dir"
        return 1
    fi
}





# --- Install Modpack ---
install_modpack() {
    local server_dir="$1"
    echo "Modpack installation options:"
    echo "1) CurseForge modpack (provide pack ID)"
    echo "2) Modrinth modpack (provide pack ID)"
    echo "3) Manual ZIP file (provide file path)"
    read -p "Choose option [1-3]: " modpack_choice
    
    case $modpack_choice in
        1) install_curseforge_modpack "$server_dir" ;;
        2) install_modrinth_modpack "$server_dir" ;;
        3) install_manual_modpack "$server_dir" ;;
        *) log_error "Invalid option."; return 1 ;;
    esac
}

# --- Install CurseForge Modpack ---
install_curseforge_modpack() {
    local server_dir="$1"
    prompt_input "Enter CurseForge modpack ID: " pack_id
    log_info "Fetching CurseForge modpack information..."
    
    # This is a simplified implementation - in practice, you'd need proper CF API integration
    log_warning "CurseForge modpack installation requires manual setup."
    log_info "Please download the server files manually and place them in: $server_dir"
    log_info "Then create a start.sh script or ensure server.jar exists."
}

# --- Install Modrinth Modpack ---
install_modrinth_modpack() {
    local server_dir="$1"
    prompt_input "Enter Modrinth modpack ID: " pack_id
    log_info "Fetching Modrinth modpack information..."
    
    # This is a simplified implementation - you'd need proper Modrinth API integration
    log_warning "Modrinth modpack installation requires manual setup."
    log_info "Please download the server files manually and place them in: $server_dir"
    log_info "Then create a start.sh script or ensure server.jar exists."
}

# --- Install Manual Modpack ---
install_manual_modpack() {
    local server_dir="$1"
    prompt_input "Enter path to modpack ZIP file: " zip_path
    
    if [ ! -f "$zip_path" ]; then
        log_error "File not found: $zip_path"
        return 1
    fi
    
    log_info "Extracting modpack..."
    unzip -q "$zip_path" -d "$server_dir"
    
    # Look for common server files
    if [ -f "$server_dir/server.jar" ]; then
        log_success "Found server.jar"
    elif [ -f "$server_dir/start.sh" ]; then
        log_success "Found start.sh script"
    else
        log_warning "No server.jar or start.sh found. You may need to configure the server manually."
    fi
}

# --- Create the start script with crash protection ---

create_start_script() {
    local server_dir="$1"
    local mem_alloc="$2"
    local mc_version="$3"
    
    if [ -f "$server_dir/start.sh" ]; then
        log_warning "start.sh already exists (likely from Forge or modpack). Backing up and creating new one."
        mv "$server_dir/start.sh" "$server_dir/start.sh.backup"
    fi
    
    log_info "Creating start.sh script with crash protection..."
    local java_path=$(get_java_path "17")
    
    # Determine the correct server jar name
    local server_jar="server.jar"
    if [ -f "$server_dir/fabric-server-launch.jar" ]; then
        server_jar="fabric-server-launch.jar"
    fi
    
    cat > "$server_dir/start.sh" << EOF
#!/bin/bash
# Start script with crash protection generated by Minecraft Manager
cd "\$(dirname "\$0")"

# Configuration
SERVER_JAR="$server_jar"
JAVA_PATH="$java_path"
JAVA_ARGS="-Xms${mem_alloc} -Xmx${mem_alloc}"
MAX_CRASHES=$MAX_CRASHES
CRASH_WINDOW=$CRASH_WINDOW
RESTART_DELAY=$RESTART_DELAY

# Check if server jar exists
if [ ! -f "\$SERVER_JAR" ]; then
    echo "[ERROR] Server jar file '\$SERVER_JAR' not found!"
    echo "Available files:"
    ls -la
    exit 1
fi

# Crash protection functions
record_crash() {
    local crash_file=".crash_tracking"
    local crash_count_file=".crash_count"
    local current_time=\$(date +%s)
    
    [ ! -f "\$crash_file" ] && echo "0" > "\$crash_file"
    [ ! -f "\$crash_count_file" ] && echo "0" > "\$crash_count_file"
    
    local last_crash_time=\$(cat "\$crash_file" 2>/dev/null || echo "0")
    local crash_count=\$(cat "\$crash_count_file" 2>/dev/null || echo "0")
    
    # Reset crash count if outside the crash window
    if [ \$((current_time - last_crash_time)) -gt \$CRASH_WINDOW ]; then
        crash_count=0
    fi
    
    crash_count=\$((crash_count + 1))
    echo "\$current_time" > "\$crash_file"
    echo "\$crash_count" > "\$crash_count_file"
    
    echo "[CRASH PROTECTION] Server crash recorded. Crash count in last \$((CRASH_WINDOW/60)) minutes: \$crash_count"
    
    if [ \$crash_count -ge \$MAX_CRASHES ]; then
        echo "[CRASH PROTECTION] Maximum crash limit (\$MAX_CRASHES) reached. Disabling auto-restart."
        touch ".auto_restart_disabled"
        return 1
    fi
    
    return 0
}

# Main server loop
while true; do
    if [ -f ".auto_restart_disabled" ]; then
        echo "[CRASH PROTECTION] Auto-restart is disabled due to too many crashes."
        echo "Remove .auto_restart_disabled file to re-enable auto-restart."
        break
    fi
    
    echo "[SERVER] Starting Minecraft server..."
    echo "[SERVER] Java path: \$JAVA_PATH"
    echo "[SERVER] Java args: \$JAVA_ARGS"
    echo "[SERVER] Server jar: \$SERVER_JAR"
    echo "[SERVER] Time: \$(date)"
    
    # Start the server
    "\$JAVA_PATH" \$JAVA_ARGS -jar "\$SERVER_JAR" nogui
    
    # Check exit code
    exit_code=\$?
    echo "[SERVER] Server stopped with exit code: \$exit_code"
    
    if [ \$exit_code -eq 0 ]; then
        echo "[SERVER] Server stopped normally."
        break
    else
        echo "[SERVER] Server crashed!"
        if ! record_crash; then
            break
        fi
        echo "[SERVER] Restarting in \$RESTART_DELAY seconds..."
        sleep \$RESTART_DELAY
    fi
done
EOF
    
    chmod +x "$server_dir/start.sh"
    log_success "Created start.sh with crash protection"
}



# --- Accept the EULA ---
accept_eula() {
    local server_dir="$1"
    log_info "Accepting Minecraft EULA..."
    echo "eula=true" > "$server_dir/eula.txt"
    log_success "EULA accepted."
}

# --- Main installation process ---
install_new_server() {
    echo -e "${C_CYAN}--- New Minecraft Server Installation ---${C_RESET}"
    echo "Select the server type to install:"
    select server_type in "Vanilla" "Fabric" "Forge" "Paper" "Spigot(use Paper)" "Modpack"; do
        if [[ "$server_type" == "Spigot(use Paper)" ]]; then server_type="Paper"; fi
        if [[ -n "$server_type" ]]; then break; else log_warning "Invalid option."; fi
    done
    
    if [[ "$server_type" == "Modpack" ]]; then
        prompt_input "Enter a name for this modpack server: " server_name
        local server_dir="$SERVER_BASE_DIR/$server_name"
        if [ -d "$server_dir" ]; then
            log_error "A server directory for '$server_name' already exists."
            read -p "Overwrite it? (y/n) THIS IS DESTRUCTIVE: " choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then rm -rf "$server_dir"; else log_info "Installation aborted."; return; fi
        fi
        mkdir -p "$server_dir"
        log_success "Created server directory: $server_dir"
        
        install_modpack "$server_dir"
        prompt_input "Enter memory allocation (e.g., 2G, 4G): " mem_alloc
        create_start_script "$server_dir" "$mem_alloc" "unknown"
        accept_eula "$server_dir"
        init_crash_tracking "$server_dir"
        log_success "Modpack installation complete!"
        log_info "You can now manage it from the main menu."
        return
    fi
    
    prompt_input "Enter the Minecraft version (e.g., 1.21): " mc_version

    # --- Resolve Java dependency based on MC version ---
    if ! resolve_java_dependency "$mc_version"; then
        log_error "Java requirement not met. Aborting installation."
        return 1
    fi

    prompt_input "Enter memory allocation (e.g., 2G, 4G): " mem_alloc
    local server_name="${server_type,,}_${mc_version}"
    local server_dir="$SERVER_BASE_DIR/$server_name"
    if [ -d "$server_dir" ]; then
        log_error "A server directory for '$server_name' already exists."
        read -p "Overwrite it? (y/n) THIS IS DESTRUCTIVE: " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then rm -rf "$server_dir"; else log_info "Installation aborted."; return; fi
    fi
    mkdir -p "$server_dir"
    log_success "Created server directory: $server_dir"

    case $server_type in
        "Vanilla") install_vanilla "$mc_version" "$server_dir" ;;
        "Paper") install_paper "$mc_version" "$server_dir" ;;
        "Forge") install_forge "$mc_version" "$server_dir" ;;
        "Fabric") install_fabric "$mc_version" "$server_dir" ;;
    esac

    if [ ! -f "$server_dir/server.jar" ] && [ ! -f "$server_dir/start.sh" ] && [ ! -f "$server_dir/fabric-server-launch.jar" ]; then
        log_error "Server JAR not found after installation attempt. Aborting."
        rm -rf "$server_dir"
        return 1
    fi

    create_start_script "$server_dir" "$mem_alloc" "$mc_version"
    accept_eula "$server_dir"
    init_crash_tracking "$server_dir"
    log_success "Installation of $server_type $mc_version complete!"
    log_info "You can now manage it from the main menu."
}

#==============================================================================
# SERVER MANAGEMENT FUNCTIONS
#==============================================================================

# --- Select an existing server ---
select_server() {
    echo "Select a server to manage:"
    local servers=()
    while IFS= read -r line; do servers+=("$line"); done < <(find "$SERVER_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ ${#servers[@]} -eq 0 ]; then
        log_error "No servers found in $SERVER_BASE_DIR"
        return 1
    fi

    select server_path in "${servers[@]}"; do
        if [ -n "$server_path" ] && [ -d "$server_path" ]; then
            selected_server_name=$(basename "$server_path")
            manage_server "$server_path" "$selected_server_name"
            break
        else
            log_warning "Invalid selection."
        fi
    done
    main_menu
}

# --- Start the server in a detached session ---
start_server() {
    local server_dir="$1"
    local session_name="$2"
    if screen -list | grep -q "$session_name"; then
        log_warning "Server session '$session_name' is already running."
        echo "To attach, run: screen -r $session_name"
        return
    fi
    if [ ! -f "$server_dir/start.sh" ]; then
        log_error "start.sh not found in $server_dir. Cannot start server."
        return
    fi
    
    # Reset crash tracking on manual start
    if [ -f "$server_dir/.auto_restart_disabled" ]; then
        read -p "Auto-restart is disabled due to crashes. Reset crash tracking? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            reset_crash_tracking "$server_dir"
        fi
    fi
    
    log_info "Starting server in a detached screen session named '$session_name'..."
    screen -dmS "$session_name" bash "$server_dir/start.sh"
    sleep 2
    if screen -list | grep -q "$session_name"; then
        log_success "Server started successfully with crash protection enabled."
        echo "To attach: ${C_CYAN}screen -r $session_name${C_RESET}"
        echo "To detach: ${C_YELLOW}Ctrl+A, then D${C_RESET}"
    else
        log_error "Failed to start server session. Check for errors by running ./start.sh manually."
    fi
}

# --- Stop the server ---
stop_server() {
    local session_name="$1"
    if ! screen -list | grep -q "$session_name"; then log_warning "Server session '$session_name' is not running."; return; fi
    log_info "Sending 'stop' command to the server..."
    screen -S "$session_name" -p 0 -X stuff "say Server is shutting down in 10 seconds...$(printf '\r')"
    sleep 10
    screen -S "$session_name" -p 0 -X stuff "stop$(printf '\r')"
    echo -n "Waiting for server to shut down gracefully (up to 30s)..."
    for i in {1..30}; do
        if ! screen -list | grep -q "$session_name"; then
            echo ""; log_success "Server '$session_name' stopped successfully."; return
        fi
        echo -n "."; sleep 1
    done
    log_warning "Server did not stop gracefully. Forcing termination."
    screen -S "$session_name" -X quit
    log_success "Server session '$session_name' terminated."
}

# --- Check server status ---
check_status() {
    local session_name="$1"
    local server_dir="$2"
    if screen -list | grep -q "$session_name"; then
        log_success "Server '$session_name' is RUNNING."
        local pid=$(screen -list | grep "$session_name" | awk '{print $1}' | cut -d. -f1)
        local start_time=$(ps -p "$pid" -o lstart=)
        local uptime=$(ps -p "$pid" -o etime= | tr -d ' ')
        log_info "Process ID: $pid | Start Time: $start_time | Uptime: $uptime"
        
        # Show crash tracking status
        if [ -f "$server_dir/.crash_count" ]; then
            local crash_count=$(cat "$server_dir/.crash_count" 2>/dev/null || echo "0")
            if [ "$crash_count" -gt 0 ]; then
                log_warning "Recent crashes: $crash_count"
            fi
        fi
        
        if [ -f "$server_dir/.auto_restart_disabled" ]; then
            log_warning "Auto-restart is DISABLED due to excessive crashes."
        fi
    else
        log_error "Server '$session_name' is STOPPED."
    fi
}

# --- Backup the world folder ---
backup_world() {
    local server_dir="$1"
    local session_name="$2"
    local world_name=$(grep 'level-name' "$server_dir/server.properties" 2>/dev/null | cut -d'=' -f2)
    [ -z "$world_name" ] && world_name="world"
    local world_path="$server_dir/$world_name"
    if [ ! -d "$world_path" ]; then log_error "World directory '$world_path' not found!"; return; fi
    local backup_dir="$server_dir/backups"; mkdir -p "$backup_dir"

    if screen -list | grep -q "$session_name"; then
        log_info "Disabling auto-saving on the server..."
        screen -S "$session_name" -p 0 -X stuff "save-off$(printf '\r')"
        screen -S "$session_name" -p 0 -X stuff "save-all$(printf '\r')"
        sleep 5
    fi
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local backup_file="$backup_dir/${world_name}_backup_${timestamp}.tar.gz"
    log_info "Creating backup of '$world_name' to $backup_file..."
    if tar -czf "$backup_file" -C "$server_dir" "$world_name"; then
        log_success "Backup created successfully."
    else
        log_error "Backup failed."
    fi
    if screen -list | grep -q "$session_name"; then
        log_info "Re-enabling auto-saving on the server..."
        screen -S "$session_name" -p 0 -X stuff "save-on$(printf '\r')"
    fi
}

# --- View server logs ---
view_logs() {
    local server_dir="$1"
    local session_name="$2"
    
    if [ -f "$server_dir/logs/latest.log" ]; then
        log_info "Showing last 50 lines of server log..."
        tail -n 50 "$server_dir/logs/latest.log"
    else
        log_warning "No log file found."
    fi
    
    if screen -list | grep -q "$session_name"; then
        echo -e "\n${C_CYAN}Server is running. To view live logs, attach to screen session:${C_RESET}"
        echo "screen -r $session_name"
    fi
}

# --- Manage crash protection ---
manage_crash_protection() {
    local server_dir="$1"
    local session_name="$2"
    
    echo -e "\n${C_CYAN}--- Crash Protection Management ---${C_RESET}"
    echo "1) View crash status"
    echo "2) Reset crash tracking"
    echo "3) Enable/disable auto-restart"
    echo "4) View crash logs"
    echo "5) Back"
    
    read -p "Enter your choice [1-5]: " choice
    case $choice in
        1)
            local crash_count=$(cat "$server_dir/.crash_count" 2>/dev/null || echo "0")
            local last_crash=$(cat "$server_dir/.crash_tracking" 2>/dev/null || echo "0")
            
            if [ "$crash_count" -gt 0 ]; then
                local last_crash_time=$(date -d @"$last_crash" 2>/dev/null || echo "Unknown")
                log_info "Crash count in current window: $crash_count"
                log_info "Last crash time: $last_crash_time"
            else
                log_success "No recent crashes recorded."
            fi
            
            if [ -f "$server_dir/.auto_restart_disabled" ]; then
                log_warning "Auto-restart is DISABLED"
            else
                log_success "Auto-restart is ENABLED"
            fi
            ;;
        2)
            reset_crash_tracking "$server_dir"
            ;;
        3)
            if [ -f "$server_dir/.auto_restart_disabled" ]; then
                rm -f "$server_dir/.auto_restart_disabled"
                log_success "Auto-restart enabled."
            else
                touch "$server_dir/.auto_restart_disabled"
                log_warning "Auto-restart disabled."
            fi
            ;;
        4)
            if [ -f "$server_dir/crash-reports" ]; then
                log_info "Recent crash reports:"
                ls -lt "$server_dir/crash-reports/" | head -10
            else
                log_info "No crash reports found."
            fi
            ;;
        5)
            return
            ;;
        *)
            log_warning "Invalid option."
            ;;
    esac
    
    read -n 1 -s -r -p "Press any key to continue..."
    manage_crash_protection "$server_dir" "$session_name"
}

# --- Update server ---
update_server() {
    local server_dir="$1"
    local session_name="$2"
    local server_name=$(basename "$server_dir")
    
    if screen -list | grep -q "$session_name"; then
        log_warning "Server is currently running. Please stop it before updating."
        return
    fi
    
    # Try to detect server type from directory name or files
    local server_type=""
    if [[ "$server_name" =~ ^vanilla_ ]]; then
        server_type="Vanilla"
    elif [[ "$server_name" =~ ^paper_ ]]; then
        server_type="Paper"
    elif [[ "$server_name" =~ ^fabric_ ]]; then
        server_type="Fabric"
    elif [[ "$server_name" =~ ^forge_ ]]; then
        server_type="Forge"
    elif [ -f "$server_dir/fabric-server-launch.jar" ] || ls "$server_dir"/fabric-server-mc.*.jar >/dev/null 2>&1; then
        server_type="Fabric"
    elif [ -f "$server_dir/forge-*.jar" ]; then
        server_type="Forge"
    else
        log_warning "Could not detect server type. Manual update may be required."
        return
    fi
    
    # Extract version from directory name
    local current_version=$(echo "$server_name" | grep -o '[0-9]\+\.[0-9]\+\(\.[0-9]\+\)*' | head -1)
    
    if [ -z "$current_version" ]; then
        log_warning "Could not detect current version. Manual update may be required."
        return
    fi
    
    log_info "Detected: $server_type $current_version"
    prompt_input "Enter new version (or press Enter to keep $current_version): " new_version
    
    if [ -z "$new_version" ]; then
        new_version="$current_version"
    fi
    
    log_info "Updating $server_type from $current_version to $new_version..."
    
    # Backup current server jar
    if [ -f "$server_dir/server.jar" ]; then
        cp "$server_dir/server.jar" "$server_dir/server.jar.backup"
        log_info "Backed up current server.jar"
    fi
    
    # Download new version
    case $server_type in
        "Vanilla") install_vanilla "$new_version" "$server_dir" ;;
        "Paper") install_paper "$new_version" "$server_dir" ;;
        "Fabric") install_fabric "$new_version" "$server_dir" ;;
        "Forge") install_forge "$new_version" "$server_dir" ;;
    esac
    
    if [ $? -eq 0 ]; then
        log_success "Server updated successfully!"
        log_info "Backup of old server.jar is available as server.jar.backup"
    else
        log_error "Update failed. Restoring backup..."
        if [ -f "$server_dir/server.jar.backup" ]; then
            mv "$server_dir/server.jar.backup" "$server_dir/server.jar"
        fi
    fi
}

# --- Management menu for a selected server ---
manage_server() {
    local server_dir="$1"
    local session_name="$2"
    while true; do
        echo -e "\n${C_CYAN}--- Managing Server: $session_name ---${C_RESET}"
        echo "1) Start Server"
        echo "2) Stop Server"
        echo "3) Check Status"
        echo "4) Backup World"
        echo "5) View Logs"
        echo "6) Crash Protection"
        echo "7) Update Server"
        echo "8) Attach Info"
        echo "9) Back to Menu"
        read -p "Enter your choice [1-9]: " choice
        case $choice in
            1) start_server "$server_dir" "$session_name" ;;
            2) stop_server "$session_name" ;;
            3) check_status "$session_name" "$server_dir" ;;
            4) backup_world "$server_dir" "$session_name" ;;
            5) view_logs "$server_dir" "$session_name" ;;
            6) manage_crash_protection "$server_dir" "$session_name" ;;
            7) update_server "$server_dir" "$session_name" ;;
            8) log_info "To attach, run: ${C_CYAN}screen -r $session_name${C_RESET}" ;;
            9) return ;;
            *) log_warning "Invalid option." ;;
        esac
        read -n 1 -s -r -p "Press any key to continue..."
    done
}

#==============================================================================
# MAIN MENU & SCRIPT START
#==============================================================================

main_menu() {
    clear
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo -e "${C_CYAN}    Minecraft Server Management Script     ${C_RESET}"
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo "1) Install a new Minecraft server"
    echo "2) Manage an existing Minecraft server"
    echo "3) View SDKMAN Java versions"
    echo "4) Exit"
    read -p "Enter your choice [1-4]: " choice
    case $choice in
        1) install_new_server; main_menu ;;
        2) select_server ;; # This will return to main_menu on its own
        3) sdk list java; read -n 1 -s -r -p "Press any key to continue..."; main_menu ;;
        4) echo "Exiting script. Goodbye!"; exit 0 ;;
        *) log_warning "Invalid choice."; sleep 2; main_menu ;;
    esac
}

#==============================================================================
# SCRIPT INITIALIZATION
#==============================================================================

# --- Initial Checks ---
if [ "$EUID" -eq 0 ]; then
  log_error "This script should not be run as root. Run it as a regular user."
  exit 1
fi

# Check and install SDKMAN if needed
install_sdkman
source_sdkman

# Check other dependencies
check_base_dependencies

# Create base directory
mkdir -p "$SERVER_BASE_DIR"

# Start main menu
main_menu
