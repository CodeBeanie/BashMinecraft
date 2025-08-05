#!/bin/bash

#==============================================================================
# Minecraft Server Installer & Manager
#
# Author: Ian Legrand
# Description: A comprehensive script to install and manage various
#              Minecraft servers (Vanilla, Fabric, Forge, Spigot, Paper, Modpacks).
#              Includes automatic Java version detection and installation via SDKMAN.
#              Features crash protection, auto-restart functionality, and a
#              server properties editor.
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
    # Minecraft 1.21+ requires Java 21
    if [[ "$major_version" -eq 1 && "$minor_version" -ge 21 ]]; then
        required_java_version="21"
    # Minecraft 1.17 - 1.20.x requires Java 17
    elif [[ "$major_version" -eq 1 && "$minor_version" -ge 17 ]]; then
        required_java_version="17"
    else
        # Default to Java 17 for older versions not explicitly handled
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
            "17") java_identifier="17.0.9-tem" ;; # Example Temurin 17 LTS
            "21") java_identifier="21.0.1-tem" ;; # Example Temurin 21 LTS
            *) java_identifier="${required_java_version}-tem" ;; # Fallback for other versions
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
    # This searches for directories containing the version number under .sdkman/candidates/java
    java_path=$(find "$HOME/.sdkman/candidates/java" -maxdepth 2 -type d -name "*${version}*" | head -n 1)
    
    if [ -n "$java_path" ] && [ -d "$java_path" ]; then
        echo "$java_path/bin/java"
    else
        # Fallback to system java if SDKMAN path not found (less reliable)
        log_warning "Could not find Java $version path via SDKMAN. Falling back to system 'java' command."
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
    # Create or reset crash tracking files
    echo "0" > "$server_dir/.crash_count"
    echo "$(date +%s)" > "$server_dir/.last_crash_time"
    rm -f "$server_dir/.auto_restart_disabled" # Ensure auto-restart is enabled initially
}

# --- Record a crash ---
record_crash() {
    local server_dir="$1"
    local crash_count_file="$server_dir/.crash_count"
    local last_crash_time_file="$server_dir/.last_crash_time"
    local current_time=$(date +%s)
    
    # Initialize if files don't exist
    [ ! -f "$crash_count_file" ] && echo "0" > "$crash_count_file"
    [ ! -f "$last_crash_time_file" ] && echo "0" > "$last_crash_time_file"
    
    local last_crash_time=$(cat "$last_crash_time_file" 2>/dev/null || echo "0")
    local crash_count=$(cat "$crash_count_file" 2>/dev/null || echo "0")
    
    # Reset crash count if outside the crash window
    if [ $((current_time - last_crash_time)) -gt $CRASH_WINDOW ]; then
        crash_count=0
    fi
    
    crash_count=$((crash_count + 1))
    echo "$current_time" > "$last_crash_time_file" # Update last crash time
    echo "$crash_count" > "$crash_count_file"     # Update crash count
    
    log_warning "Server crash recorded. Crash count in last $((CRASH_WINDOW/60)) minutes: $crash_count"
    
    if [ $crash_count -ge $MAX_CRASHES ]; then
        log_error "Maximum crash limit ($MAX_CRASHES) reached. Disabling auto-restart."
        touch "$server_dir/.auto_restart_disabled"
        return 1 # Indicate that auto-restart should be disabled
    fi
    
    return 0 # Indicate that auto-restart can continue
}

# --- Check if auto-restart is disabled ---
is_auto_restart_disabled() {
    local server_dir="$1"
    [ -f "$server_dir/.auto_restart_disabled" ]
}

# --- Reset crash tracking ---
reset_crash_tracking() {
    local server_dir="$1"
    rm -f "$server_dir/.crash_count" "$server_dir/.last_crash_time" "$server_dir/.auto_restart_disabled"
    log_success "Crash tracking reset and auto-restart enabled."
}

#==============================================================================
# SERVER INSTALLATION FUNCTIONS
#==============================================================================

# --- Download server JAR from a URL ---
download_jar() {
    local url="$1"
    local dest_path="$2"
    log_info "Downloading server file from: $url"
    # Use --progress=bar:force for consistent progress bar even in non-TTY
    if wget -q --show-progress -O "$dest_path" "$url"; then
        log_success "Download complete."
    else
        log_error "Failed to download server file from $url. Please check the URL and your connection."
        rm -f "$dest_path" # Clean up partial download
        return 1 # Indicate failure
    fi
    return 0 # Indicate success
}

# --- Install Vanilla Server ---
install_vanilla() {
    local version="$1"
    local server_dir="$2"
    log_info "Fetching available Vanilla versions..."
    local manifest=$(wget -qO- https://launchermeta.mojang.com/mc/game/version_manifest.json)
    if [ -z "$manifest" ]; then
        log_error "Could not fetch Minecraft version manifest."
        return 1
    fi
    local version_url=$(echo "$manifest" | jq -r ".versions[] | select(.id==\"$version\") | .url")
    if [ -z "$version_url" ] || [ "$version_url" == "null" ]; then
        log_error "Version '$version' not found in Mojang's manifest."
        log_info "Available release versions: $(echo "$manifest" | jq -r '.versions[] | select(.type=="release") | .id' | tr '\n' ' ')"
        return 1
    fi
    local server_jar_url=$(wget -qO- "$version_url" | jq -r '.downloads.server.url')
    if [ -z "$server_jar_url" ] || [ "$server_jar_url" == "null" ]; then
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
    
    local api_url="https://api.papermc.io/v2/projects/paper/versions/$version/builds"
    local response=$(wget -qO- "$api_url")
    
    if [ -z "$response" ]; then
        log_error "Could not fetch PaperMC API response for version $version from $api_url."
        return 1
    fi

    # Try to get the latest build from the 'default' channel first
    local build=$(echo "$response" | jq -r '.builds | map(select(.channel=="default")) | .[-1].build')

    if [ -z "$build" ] || [ "$build" == "null" ]; then
        log_warning "No 'default' channel build found for Paper $version. Trying to find any latest build."
        # Fallback: get the absolute latest build number regardless of channel
        build=$(echo "$response" | jq -r '.builds | .[-1].build')
        if [ -z "$build" ] || [ "$build" == "null" ]; then
            log_error "Could not find any build for Paper $version."
            log_info "Check available versions and builds at https://papermc.io/downloads"
            return 1
        fi
        log_info "Found build $build (not from 'default' channel, may be experimental)."
    else
        log_info "Found latest 'default' build: $build"
    fi

    local jar_name="paper-$version-$build.jar"
    local download_url="https://api.papermc.io/v2/projects/paper/versions/$version/builds/$build/downloads/$jar_name"
    
    log_info "Attempting to download Paper JAR from: $download_url"
    download_jar "$download_url" "$server_dir/server.jar"
}

# --- Install Forge Server ---
install_forge() {
    local version="$1"
    local server_dir="$2"
    log_info "Fetching available Forge versions for Minecraft $version..."
    local forge_versions_json=$(wget -qO- "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")
    if [ -z "$forge_versions_json" ]; then
        log_error "Could not fetch Forge version data."
        return 1
    fi
    local forge_version=$(echo "$forge_versions_json" | jq -r ".promos[\"$version-recommended\"] // .promos[\"$version-latest\"]")
    if [ -z "$forge_version" ] || [ "$forge_version" == "null" ]; then
        log_error "Could not find a recommended or latest Forge build for Minecraft $version."
        log_info "Please check available versions manually at https://files.minecraftforge.net/"
        return 1
    fi
    log_info "Found Forge version: $forge_version"
    local installer_url="https://maven.minecraftforge.net/net/minecraftforge/forge/$version-$forge_version/forge-$version-$forge_version-installer.jar"
    local installer_jar="$server_dir/forge_installer.jar"
    
    if ! download_jar "$installer_url" "$installer_jar"; then
        return 1
    fi

    log_info "Running Forge installer..."
    # Use Java 17 for Forge installer as it's generally compatible
    local java_path_for_installer=$(get_java_path "17") 
    (cd "$server_dir" && "$java_path_for_installer" -jar "$installer_jar" --installServer)
    if [ $? -ne 0 ]; then 
        log_error "Forge installer failed. Check the output above."
        return 1
    fi
    
    # Newer forge versions create a run.sh script.
    if [ -f "$server_dir/run.sh" ]; then
        log_info "Forge created a run.sh script. Adapting it to start.sh."
        mv "$server_dir/run.sh" "$server_dir/start.sh"
        chmod +x "$server_dir/start.sh"
        rm "$installer_jar"
        return 0 # Indicate success and skip default start script creation
    elif [ -f "$server_dir/forge-*.jar" ]; then
        # For older Forge versions that create a direct JAR
        log_info "Forge installed a server JAR directly. Renaming to server.jar."
        mv "$server_dir/forge-"*.jar "$server_dir/server.jar" 2>/dev/null
        rm "$installer_jar"
        return 0
    else
        log_error "Could not find the installed Forge server JAR or run.sh. Installation may have failed."
        rm -f "$installer_jar"
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
    
    if ! download_jar "$installer_jar_url" "$installer_jar"; then
        return 1
    fi
    
    log_info "Running Fabric installer..."
    # Use Java 17 for Fabric installer as it's generally compatible
    local java_path_for_installer=$(get_java_path "17")
    
    # Run the installer with proper flags
    (cd "$server_dir" && "$java_path_for_installer" -jar "$installer_jar" server -mcversion "$version" -downloadMinecraft -dir .)
    
    if [ $? -ne 0 ]; then 
        log_error "Fabric installer failed. Check the output above."
        rm -f "$installer_jar"
        return 1
    fi
    
    # Clean up installer
    rm -f "$installer_jar"
    
    # The Fabric installer creates fabric-server-launch.jar as the main server jar
    if [ -f "$server_dir/fabric-server-launch.jar" ]; then
        log_success "Fabric server installed successfully."
        log_info "Fabric uses fabric-server-launch.jar as the main server file."
        # Do not rename it - keep it as fabric-server-launch.jar
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
    
    log_warning "CurseForge modpack installation via API is complex and not fully automated in this script."
    log_info "Please download the server files manually (e.g., from CurseForge website) and place them in: $server_dir"
    log_info "Then ensure there's a 'server.jar' or a 'start.sh' script in the directory."
    log_info "You might need to manually run the Forge/Fabric installer included with the modpack."
    return 1 # Indicate that manual steps are required
}

# --- Install Modrinth Modpack ---
install_modrinth_modpack() {
    local server_dir="$1"
    prompt_input "Enter Modrinth modpack ID: " pack_id
    log_info "Fetching Modrinth modpack information..."
    
    log_warning "Modrinth modpack installation via API is complex and not fully automated in this script."
    log_info "Please download the server files manually (e.g., from Modrinth website) and place them in: $server_dir"
    log_info "Then ensure there's a 'server.jar' or a 'start.sh' script in the directory."
    log_info "You might need to manually run the Forge/Fabric installer included with the modpack."
    return 1 # Indicate that manual steps are required
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
    if unzip -q "$zip_path" -d "$server_dir"; then
        log_success "Modpack extracted successfully."
    else
        log_error "Failed to extract modpack ZIP file."
        return 1
    fi
    
    # Look for common server files
    if [ -f "$server_dir/server.jar" ]; then
        log_success "Found server.jar in extracted modpack."
    elif [ -f "$server_dir/start.sh" ]; then
        log_success "Found start.sh script in extracted modpack."
    elif [ -f "$server_dir/fabric-server-launch.jar" ]; then
        log_success "Found fabric-server-launch.jar in extracted modpack."
    else
        log_warning "No common server JAR (server.jar, fabric-server-launch.jar) or start.sh found."
        log_warning "You may need to manually configure the server's main JAR or start script."
    fi
    return 0
}

# --- Create the start script with crash protection ---
create_start_script() {
    local server_dir="$1"
    local mem_alloc="$2"
    local mc_version="$3" # This is the Minecraft version string (e.g., "1.21.8")
    
    # If a start.sh already exists (e.g., from Forge or a modpack), back it up
    if [ -f "$server_dir/start.sh" ]; then
        log_warning "start.sh already exists. Backing it up to start.sh.backup."
        mv "$server_dir/start.sh" "$server_dir/start.sh.backup"
    fi
    
    log_info "Creating start.sh script with crash protection..."
    
    # Determine the correct Java version based on the Minecraft version
    local required_java_version=""
    local major_version=$(echo "$mc_version" | cut -d. -f1)
    local minor_version=$(echo "$mc_version" | cut -d. -f2)

    if [[ "$major_version" -eq 1 && "$minor_version" -ge 21 ]]; then
        required_java_version="21"
    elif [[ "$major_version" -eq 1 && "$minor_version" -ge 17 ]]; then
        required_java_version="17"
    else
        required_java_version="17" # Default for older versions
    fi

    local java_path=$(get_java_path "$required_java_version")
    
    # Determine the correct server jar name
    local server_jar="server.jar" # Default
    if [ -f "$server_dir/fabric-server-launch.jar" ]; then
        server_jar="fabric-server-launch.jar"
    elif [ -f "$server_dir/forge-*.jar" ]; then
        # This is a heuristic, as Forge JAR names can vary.
        # If forge_installer didn't create run.sh, it might leave a forge-*.jar
        server_jar=$(basename "$server_dir/forge-"*.jar 2>/dev/null)
        if [ -z "$server_jar" ]; then
            log_warning "Could not auto-detect Forge main JAR. Defaulting to server.jar. Please verify."
            server_jar="server.jar"
        fi
    fi

    cat > "$server_dir/start.sh" << EOF
#!/bin/bash
# Start script with crash protection generated by Minecraft Manager
# This script ensures the correct Java version is used and handles server restarts.

# Change to the server directory
cd "\$(dirname "\$0")"

# Configuration
SERVER_JAR="$server_jar"
JAVA_PATH="$java_path"
JAVA_ARGS="-Xms${mem_alloc} -Xmx${mem_alloc}" # Memory allocation for Java
MAX_CRASHES=$MAX_CRASHES           # Max crashes before auto-restart is disabled
CRASH_WINDOW=$CRASH_WINDOW         # Time window in seconds to count crashes
RESTART_DELAY=$RESTART_DELAY       # Delay between restart attempts in seconds

# Check if server jar exists
if [ ! -f "\$SERVER_JAR" ]; then
    echo "[ERROR] Server jar file '\$SERVER_JAR' not found!"
    echo "Please ensure the correct server JAR is in this directory or update SERVER_JAR in this script."
    echo "Available files in this directory:"
    ls -la
    exit 1
fi

# Crash protection functions (local to this script)
record_crash() {
    local crash_count_file=".crash_count"
    local last_crash_time_file=".last_crash_time"
    local current_time=\$(date +%s)
    
    # Initialize files if they don't exist
    [ ! -f "\$crash_count_file" ] && echo "0" > "\$crash_count_file"
    [ ! -f "\$last_crash_time_file" ] && echo "0" > "\$last_crash_time_file"
    
    local last_crash_time=\$(cat "\$last_crash_time_file" 2>/dev/null || echo "0")
    local crash_count=\$(cat "\$crash_count_file" 2>/dev/null || echo "0")
    
    # Reset crash count if outside the crash window
    if [ \$((current_time - last_crash_time)) -gt \$CRASH_WINDOW ]; then
        crash_count=0
    fi
    
    crash_count=\$((crash_count + 1))
    echo "\$current_time" > "\$last_crash_time_file" # Update last crash time
    echo "\$crash_count" > "\$crash_count_file"     # Update crash count
    
    echo "[CRASH PROTECTION] Server crash recorded. Crash count in last \$((CRASH_WINDOW/60)) minutes: \$crash_count"
    
    if [ \$crash_count -ge \$MAX_CRASHES ]; then
        echo "[CRASH PROTECTION] Maximum crash limit (\$MAX_CRASHES) reached. Disabling auto-restart."
        touch ".auto_restart_disabled" # Create a flag file to disable auto-restart
        return 1 # Indicate that auto-restart should be disabled
    fi
    
    return 0 # Indicate that auto-restart can continue
}

# Main server loop
while true; do
    # Check if auto-restart has been explicitly disabled
    if [ -f ".auto_restart_disabled" ]; then
        echo "[CRASH PROTECTION] Auto-restart is disabled due to too many crashes."
        echo "To re-enable, remove the '.auto_restart_disabled' file from the server directory."
        break # Exit the loop, server will not restart
    fi
    
    echo "[SERVER] Starting Minecraft server..."
    echo "[SERVER] Java executable: \$JAVA_PATH"
    echo "[SERVER] Java arguments: \$JAVA_ARGS"
    echo "[SERVER] Server JAR: \$SERVER_JAR"
    echo "[SERVER] Current Time: \$(date)"
    
    # Start the server using the determined Java path and JAR
    "\$JAVA_PATH" \$JAVA_ARGS -jar "\$SERVER_JAR" nogui
    
    # Capture the exit code of the server process
    exit_code=\$?
    echo "[SERVER] Server stopped with exit code: \$exit_code"
    
    if [ \$exit_code -eq 0 ]; then
        echo "[SERVER] Server stopped normally (exit code 0)."
        break # Exit the loop for normal shutdown
    else
        echo "[SERVER] Server crashed or stopped unexpectedly!"
        # Record the crash and check if auto-restart should be disabled
        if ! record_crash; then
            break # If record_crash returns 1, max crashes reached, stop auto-restart
        fi
        echo "[SERVER] Restarting in \$RESTART_DELAY seconds..."
        sleep \$RESTART_DELAY # Wait before attempting restart
    fi
done
EOF
    
    chmod +x "$server_dir/start.sh"
    log_success "Created start.sh with crash protection and correct Java path."
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
        # Alias Spigot to Paper as Paper is a highly optimized Spigot fork
        if [[ "$server_type" == "Spigot(use Paper)" ]]; then server_type="Paper"; fi
        if [[ -n "$server_type" ]]; then break; else log_warning "Invalid option."; fi
    done
    
    # Handle Modpack installation separately as it has different prompts
    if [[ "$server_type" == "Modpack" ]]; then
        prompt_input "Enter a unique name for this modpack server: " server_name
        local server_dir="$SERVER_BASE_DIR/$server_name"
        if [ -d "$server_dir" ]; then
            log_error "A server directory for '$server_name' already exists."
            read -p "Overwrite it? (y/n) THIS IS DESTRUCTIVE: " choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then rm -rf "$server_dir"; else log_info "Installation aborted."; return; fi
        fi
        mkdir -p "$server_dir" || { log_error "Failed to create server directory."; return 1; }
        log_success "Created server directory: $server_dir"
        
        # Call modpack installation function
        if ! install_modpack "$server_dir"; then
            log_error "Modpack installation failed. Aborting."
            rm -rf "$server_dir" # Clean up partially created directory
            return 1
        fi

        # Modpacks might need specific Java versions, prompt for it or try to deduce
        prompt_input "Enter the Minecraft version this modpack is for (e.g., 1.20.1, 1.21.8): " mc_version_for_modpack
        if ! resolve_java_dependency "$mc_version_for_modpack"; then
            log_error "Java requirement for modpack not met. Aborting installation."
            rm -rf "$server_dir"
            return 1
        fi

        prompt_input "Enter memory allocation (e.g., 2G, 4G, 8G): " mem_alloc
        
        # Create start script for modpack, passing the MC version for Java resolution
        create_start_script "$server_dir" "$mem_alloc" "$mc_version_for_modpack"
        
        accept_eula "$server_dir"
        init_crash_tracking "$server_dir"
        log_success "Modpack installation complete!"
        log_info "You can now manage it from the main menu."
        return
    fi
    
    # For standard server types (Vanilla, Fabric, Forge, Paper)
    prompt_input "Enter the Minecraft version (e.g., 1.21.8, 1.20.4): " mc_version

    # Resolve and install Java dependency based on MC version
    if ! resolve_java_dependency "$mc_version"; then
        log_error "Java requirement not met. Aborting installation."
        return 1
    fi

    prompt_input "Enter memory allocation (e.g., 2G, 4G, 8G): " mem_alloc
    
    # Construct a default server name
    local server_name="${server_type,,}_${mc_version}"
    local server_dir="$SERVER_BASE_DIR/$server_name"
    
    # Check if server directory already exists and prompt for overwrite
    if [ -d "$server_dir" ]; then
        log_error "A server directory for '$server_name' already exists."
        read -p "Overwrite it? (y/n) THIS IS DESTRUCTIVE: " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then rm -rf "$server_dir"; else log_info "Installation aborted."; return; fi
    fi
    
    mkdir -p "$server_dir" || { log_error "Failed to create server directory."; return 1; }
    log_success "Created server directory: $server_dir"

    # Call the appropriate installation function
    case $server_type in
        "Vanilla") install_vanilla "$mc_version" "$server_dir" ;;
        "Paper") install_paper "$mc_version" "$server_dir" ;;
        "Forge") install_forge "$mc_version" "$server_dir" ;;
        "Fabric") install_fabric "$mc_version" "$server_dir" ;;
        *) log_error "Unknown server type selected. Aborting installation."; rm -rf "$server_dir"; return 1 ;;
    esac

    # Verify that a server JAR or start script was created
    if [ ! -f "$server_dir/server.jar" ] && [ ! -f "$server_dir/start.sh" ] && [ ! -f "$server_dir/fabric-server-launch.jar" ]; then
        log_error "Server JAR or start script not found after installation attempt. Aborting."
        rm -rf "$server_dir" # Clean up partially created directory
        return 1
    fi

    # Create the main start script for the server
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
    # Find all directories under SERVER_BASE_DIR and sort them
    while IFS= read -r line; do servers+=("$line"); done < <(find "$SERVER_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ ${#servers[@]} -eq 0 ]; then
        log_error "No Minecraft servers found in $SERVER_BASE_DIR."
        read -n 1 -s -r -p "Press any key to continue to main menu..."
        return 1
    fi

    # Present a selection menu to the user
    select server_path in "${servers[@]}"; do
        if [ -n "$server_path" ] && [ -d "$server_path" ]; then
            selected_server_name=$(basename "$server_path")
            manage_server "$server_path" "$selected_server_name"
            break # Exit the select loop after managing a server
        else
            log_warning "Invalid selection. Please choose a number from the list."
        fi
    done
    # Returns to main_menu after server management is done
}

# --- Start the server in a detached screen session ---
start_server() {
    local server_dir="$1"
    local session_name="$2"
    
    # Check if a screen session with this name is already running
    if screen -list | grep -q "$session_name"; then
        log_warning "Server session '$session_name' is already running."
        echo "To attach to it, run: ${C_CYAN}screen -r $session_name${C_RESET}"
        return
    fi
    
    # Check if the start script exists
    if [ ! -f "$server_dir/start.sh" ]; then
        log_error "start.sh not found in $server_dir. Cannot start server."
        log_info "Please ensure the server is properly installed or create a start.sh script."
        return
    fi
    
    # Prompt to reset crash tracking if auto-restart was previously disabled
    if [ -f "$server_dir/.auto_restart_disabled" ]; then
        read -p "Auto-restart was previously disabled due to crashes. Reset crash tracking and re-enable? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            reset_crash_tracking "$server_dir"
        else
            log_info "Auto-restart remains disabled. Server will start but not auto-restart on crash."
        fi
    fi
    
    log_info "Starting server in a detached screen session named '${C_CYAN}$session_name${C_RESET}'..."
    # Execute the start.sh script in a new detached screen session
    screen -dmS "$session_name" bash "$server_dir/start.sh"
    sleep 2 # Give screen a moment to start
    
    # Verify if the screen session started successfully
    if screen -list | grep -q "$session_name"; then
        log_success "Server started successfully with crash protection enabled."
        echo "To attach to the server console: ${C_CYAN}screen -r $session_name${C_RESET}"
        echo "To detach from the console (without stopping the server): ${C_YELLOW}Ctrl+A, then D${C_RESET}"
    else
        log_error "Failed to start server session. Check for errors by running '$server_dir/start.sh' manually in a terminal."
    fi
}

# --- Stop the server ---
stop_server() {
    local session_name="$1"
    # Check if the server's screen session is running
    if ! screen -list | grep -q "$session_name"; then 
        log_warning "Server session '$session_name' is not running."
        return
    fi
    
    log_info "Sending 'stop' command to the server console..."
    # Send 'say' message to inform players
    screen -S "$session_name" -p 0 -X stuff "say Server is shutting down in 10 seconds...$(printf '\r')"
    sleep 10
    # Send the 'stop' command
    screen -S "$session_name" -p 0 -X stuff "stop$(printf '\r')"
    
    echo -n "Waiting for server to shut down gracefully (up to 30s)..."
    for i in {1..30}; do
        if ! screen -list | grep -q "$session_name"; then
            echo ""; log_success "Server '$session_name' stopped successfully."; return
        fi
        echo -n "."; sleep 1
    done
    
    log_warning "Server did not shut down gracefully within 30 seconds. Forcing termination."
    # If it didn't stop, force quit the screen session
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
        local start_time=$(ps -p "$pid" -o lstart= 2>/dev/null)
        local uptime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
        log_info "Process ID: ${C_CYAN}$pid${C_RESET} | Start Time: ${C_CYAN}$start_time${C_RESET} | Uptime: ${C_CYAN}$uptime${C_RESET}"
        
        # Show crash tracking status
        local crash_count=$(cat "$server_dir/.crash_count" 2>/dev/null || echo "0")
        if [ "$crash_count" -gt 0 ]; then
            log_warning "Recent crashes in current window: $crash_count (Max: $MAX_CRASHES)"
        else
            log_info "No recent crashes recorded."
        fi
        
        if [ -f "$server_dir/.auto_restart_disabled" ]; then
            log_warning "Auto-restart is DISABLED for this server due to excessive crashes."
        else
            log_info "Auto-restart is ENABLED for this server."
        fi
    else
        log_error "Server '$session_name' is STOPPED."
        if [ -f "$server_dir/.auto_restart_disabled" ]; then
            log_warning "Auto-restart is DISABLED for this server."
        fi
    fi
}

# --- Backup the world folder ---
backup_world() {
    local server_dir="$1"
    local session_name="$2"
    
    # Try to get world name from server.properties, default to "world"
    local world_name=$(grep 'level-name' "$server_dir/server.properties" 2>/dev/null | cut -d'=' -f2)
    [ -z "$world_name" ] && world_name="world" # Default world name
    
    local world_path="$server_dir/$world_name"
    if [ ! -d "$world_path" ]; then 
        log_error "World directory '$world_path' not found! Cannot create backup."
        return
    fi
    
    local backup_dir="$server_dir/backups"
    mkdir -p "$backup_dir" || { log_error "Failed to create backups directory."; return; }

    # If server is running, temporarily disable auto-saving for a consistent backup
    if screen -list | grep -q "$session_name"; then
        log_info "Server is running. Disabling auto-saving and forcing a save..."
        screen -S "$session_name" -p 0 -X stuff "save-off$(printf '\r')"
        screen -S "$session_name" -p 0 -X stuff "save-all$(printf '\r')"
        sleep 5 # Give server time to save
    else
        log_info "Server is stopped. Proceeding with backup."
    fi
    
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local backup_file="$backup_dir/${world_name}_backup_${timestamp}.tar.gz"
    log_info "Creating compressed backup of '$world_name' to $backup_file..."
    
    # Create a gzipped tar archive of the world folder
    if tar -czf "$backup_file" -C "$server_dir" "$world_name"; then
        log_success "Backup created successfully."
    else
        log_error "Backup failed. Check permissions and disk space."
    fi
    
    # Re-enable auto-saving if the server was running
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
        log_info "Showing last 50 lines of server log (${C_CYAN}$server_dir/logs/latest.log${C_RESET})..."
        tail -n 50 "$server_dir/logs/latest.log"
    else
        log_warning "No 'latest.log' file found in '$server_dir/logs/'."
        log_info "Logs might not have been generated yet or are in a different location."
    fi
    
    if screen -list | grep -q "$session_name"; then
        echo -e "\n${C_CYAN}Server is currently running. To view live logs and interact with the console, attach to the screen session:${C_RESET}"
        echo "  ${C_CYAN}screen -r $session_name${C_RESET}"
    fi
}

# --- Manage crash protection settings ---
manage_crash_protection() {
    local server_dir="$1"
    local session_name="$2"
    
    while true; do
        echo -e "\n${C_CYAN}--- Crash Protection Management for $session_name ---${C_RESET}"
        echo "1) View current crash status"
        echo "2) Reset crash tracking (re-enables auto-restart)"
        echo "3) Manually enable/disable auto-restart"
        echo "4) View crash reports (if generated by Minecraft)"
        echo "5) Back to Server Management"
        
        read -p "Enter your choice [1-5]: " choice
        case $choice in
            1)
                local crash_count=$(cat "$server_dir/.crash_count" 2>/dev/null || echo "0")
                local last_crash_time_epoch=$(cat "$server_dir/.last_crash_time" 2>/dev/null || echo "0")
                
                if [ "$crash_count" -gt 0 ]; then
                    local last_crash_readable_time=$(date -d @"$last_crash_time_epoch" 2>/dev/null || echo "Unknown")
                    log_info "Crash count in current window: ${C_CYAN}$crash_count${C_RESET} (Max allowed: $MAX_CRASHES)"
                    log_info "Last recorded crash: ${C_CYAN}$last_crash_readable_time${C_RESET}"
                else
                    log_success "No recent crashes recorded in the current window."
                fi
                
                if [ -f "$server_dir/.auto_restart_disabled" ]; then
                    log_warning "Auto-restart is currently DISABLED."
                else
                    log_success "Auto-restart is currently ENABLED."
                fi
                ;;
            2)
                reset_crash_tracking "$server_dir"
                ;;
            3)
                if [ -f "$server_dir/.auto_restart_disabled" ]; then
                    rm -f "$server_dir/.auto_restart_disabled"
                    log_success "Auto-restart has been ENABLED."
                else
                    touch "$server_dir/.auto_restart_disabled"
                    log_warning "Auto-restart has been DISABLED."
                fi
                ;;
            4)
                if [ -d "$server_dir/crash-reports" ]; then
                    log_info "Listing recent crash reports in '$server_dir/crash-reports/':"
                    ls -lt "$server_dir/crash-reports/" | head -n 10 # Show latest 9 reports + header
                    if [ $(ls "$server_dir/crash-reports/" | wc -l) -eq 0 ]; then
                        log_info "No crash reports found in this directory."
                    fi
                else
                    log_info "No 'crash-reports' directory found for this server."
                fi
                ;;
            5)
                return # Exit this submenu
                ;;
            *)
                log_warning "Invalid option. Please enter a number between 1 and 5."
                ;;
        esac
        read -n 1 -s -r -p "Press any key to continue..."
    done
}

# --- Update server ---
update_server() {
    local server_dir="$1"
    local session_name="$2"
    local server_name=$(basename "$server_dir")
    
    if screen -list | grep -q "$session_name"; then
        log_warning "Server is currently running. Please stop it before attempting an update."
        return
    fi
    
    # Attempt to detect server type and current Minecraft version from directory name
    local server_type=""
    local current_mc_version=""

    if [[ "$server_name" =~ ^vanilla_([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        server_type="Vanilla"
        current_mc_version="${BASH_REMATCH[1]}"
    elif [[ "$server_name" =~ ^paper_([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        server_type="Paper"
        current_mc_version="${BASH_REMATCH[1]}"
    elif [[ "$server_name" =~ ^fabric_([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        server_type="Fabric"
        current_mc_version="${BASH_REMATCH[1]}"
    elif [[ "$server_name" =~ ^forge_([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        server_type="Forge"
        current_mc_version="${BASH_REMATCH[1]}"
    else
        log_warning "Could not reliably detect server type or Minecraft version from directory name '$server_name'."
        log_info "This update function works best for servers installed by this script."
        log_info "For modpacks or manually installed servers, manual update may be required."
        return
    fi
    
    if [ -z "$current_mc_version" ]; then
        log_warning "Could not detect current Minecraft version. Manual update may be required."
        return
    fi
    
    log_info "Detected server type: ${C_CYAN}$server_type${C_RESET}, Current Minecraft version: ${C_CYAN}$current_mc_version${C_RESET}"
    prompt_input "Enter the NEW Minecraft version (e.g., 1.21.8, 1.20.6). Press Enter to update to the latest build of current version: " new_version_input
    
    local new_mc_version="$new_version_input"
    if [ -z "$new_mc_version" ]; then
        new_mc_version="$current_mc_version" # Update to latest build of current version
        log_info "Updating to latest build for current version: $new_mc_version"
    else
        log_info "Attempting to update from $current_mc_version to $new_mc_version"
    fi

    # Resolve Java dependency for the new MC version
    if ! resolve_java_dependency "$new_mc_version"; then
        log_error "Java requirement for new Minecraft version not met. Aborting update."
        return 1
    fi
    
    # Backup current server JAR before attempting update
    if [ -f "$server_dir/server.jar" ]; then
        cp "$server_dir/server.jar" "$server_dir/server.jar.backup"
        log_info "Backed up current server.jar to server.jar.backup"
    elif [ -f "$server_dir/fabric-server-launch.jar" ]; then
        cp "$server_dir/fabric-server-launch.jar" "$server_dir/fabric-server-launch.jar.backup"
        log_info "Backed up current fabric-server-launch.jar to fabric-server-launch.jar.backup"
    fi
    
    local update_successful=0
    case $server_type in
        "Vanilla") 
            if install_vanilla "$new_mc_version" "$server_dir"; then update_successful=1; fi
            ;;
        "Paper") 
            if install_paper "$new_mc_version" "$server_dir"; then update_successful=1; fi
            ;;
        "Fabric") 
            if install_fabric "$new_mc_version" "$server_dir"; then update_successful=1; fi
            ;;
        "Forge") 
            if install_forge "$new_mc_version" "$server_dir"; then update_successful=1; fi
            ;;
        *)
            log_error "Update for server type '$server_type' is not supported by this script."
            ;;
    esac
    
    if [ "$update_successful" -eq 1 ]; then
        log_success "Server updated successfully to version $new_mc_version!"
        # Re-create start script in case Java path or JAR name changed
        local mem_alloc=$(grep 'JAVA_ARGS' "$server_dir/start.sh.backup" 2>/dev/null | sed -n 's/.*-Xms\([^ ]*\) -Xmx\([^ ]*\).*/\1/p')
        [ -z "$mem_alloc" ] && mem_alloc="2G" # Default if not found
        create_start_script "$server_dir" "$mem_alloc" "$new_mc_version"
    else
        log_error "Server update failed. Attempting to restore backup..."
        if [ -f "$server_dir/server.jar.backup" ]; then
            mv "$server_dir/server.jar.backup" "$server_dir/server.jar"
            log_success "Restored server.jar from backup."
        elif [ -f "$server_dir/fabric-server-launch.jar.backup" ]; then
            mv "$server_dir/fabric-server-launch.jar.backup" "$server_dir/fabric-server-launch.jar"
            log_success "Restored fabric-server-launch.jar from backup."
        else
            log_warning "No backup found or restoration failed. Manual intervention may be required."
        fi
    fi
}

# --- [NEW] Helper to read a property from server.properties ---
get_property() {
    local file="$1"
    local key="$2"
    local default_value="$3"
    if [ ! -f "$file" ]; then
        echo "$default_value"
        return
    fi
    local value=$(grep "^${key}=" "$file" | cut -d'=' -f2-)
    if [ -z "$value" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

# --- [NEW] Helper to update a property in server.properties ---
update_property() {
    local file="$1"
    local key="$2"
    local value="$3"
    # Escape special characters for sed
    local escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')

    if grep -qE "^${key}=" "$file"; then
        # Key exists, update it
        sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$file"
    else
        # Key does not exist, append it
        echo "${key}=${escaped_value}" >> "$file"
    fi
    log_success "Set '$key' to '$escaped_value'."
}

# --- [NEW] Edit server.properties ---
edit_server_properties() {
    local server_dir="$1"
    local properties_file="$server_dir/server.properties"

    if [ ! -f "$properties_file" ]; then
        log_error "server.properties file not found in $server_dir"
        log_info "Please start the server at least once to generate the file."
        return
    fi

    while true; do
        clear
        echo -e "\n${C_CYAN}--- Edit Server Properties ---${C_RESET}"
        echo -e "${C_YELLOW}NOTE: The server must be restarted for these changes to take effect.${C_RESET}"
        echo
        echo "1)  MOTD (Description):   $(get_property "$properties_file" "motd" "A Minecraft Server")"
        echo "2)  Gamemode:             $(get_property "$properties_file" "gamemode" "survival")"
        echo "3)  Difficulty:           $(get_property "$properties_file" "difficulty" "easy")"
        echo "4)  PVP:                  $(get_property "$properties_file" "pvp" "true")"
        echo "5)  Hardcore:             $(get_property "$properties_file" "hardcore" "false")"
        echo "6)  Whitelist:            $(get_property "$properties_file" "white-list" "false")"
        echo "7)  Max Players:          $(get_property "$properties_file" "max-players" "20")"
        echo "8)  View Distance:        $(get_property "$properties_file" "view-distance" "10")"
        echo "9)  Allow Flight:         $(get_property "$properties_file" "allow-flight" "false")"
        echo "10) Online Mode:          $(get_property "$properties_file" "online-mode" "true")"
        echo "11) Spawn Protection:     $(get_property "$properties_file" "spawn-protection" "16")"
        echo "12) Level Seed:           $(get_property "$properties_file" "level-seed")"
        echo "13) Back to Server Management"
        echo

        read -p "Enter your choice [1-13]: " choice
        case $choice in
            1)
                read -p "Enter new MOTD (server description): " new_motd
                update_property "$properties_file" "motd" "$new_motd"
                ;;
            2)
                read -p "Enter new Gamemode (survival, creative, adventure, spectator): " new_gamemode
                if [[ "$new_gamemode" =~ ^(survival|creative|adventure|spectator)$ ]]; then
                    update_property "$properties_file" "gamemode" "$new_gamemode"
                else
                    log_error "Invalid gamemode."
                fi
                ;;
            3)
                read -p "Enter new Difficulty (peaceful, easy, normal, hard): " new_difficulty
                if [[ "$new_difficulty" =~ ^(peaceful|easy|normal|hard)$ ]]; then
                    update_property "$properties_file" "difficulty" "$new_difficulty"
                else
                    log_error "Invalid difficulty."
                fi
                ;;
            4)
                read -p "Enable PVP? (true/false): " new_pvp
                if [[ "$new_pvp" =~ ^(true|false)$ ]]; then
                    update_property "$properties_file" "pvp" "$new_pvp"
                else
                    log_error "Invalid input. Please enter 'true' or 'false'."
                fi
                ;;
            5)
                read -p "Enable Hardcore mode? (true/false): " new_hardcore
                if [[ "$new_hardcore" =~ ^(true|false)$ ]]; then
                    update_property "$properties_file" "hardcore" "$new_hardcore"
                else
                    log_error "Invalid input. Please enter 'true' or 'false'."
                fi
                ;;
            6)
                read -p "Enable Whitelist? (true/false): " new_whitelist
                if [[ "$new_whitelist" =~ ^(true|false)$ ]]; then
                    update_property "$properties_file" "white-list" "$new_whitelist"
                else
                    log_error "Invalid input. Please enter 'true' or 'false'."
                fi
                ;;
            7)
                read -p "Enter Max Players (e.g., 20): " new_max_players
                if [[ "$new_max_players" =~ ^[0-9]+$ ]]; then
                    update_property "$properties_file" "max-players" "$new_max_players"
                else
                    log_error "Invalid input. Please enter a number."
                fi
                ;;
            8)
                read -p "Enter View Distance (e.g., 10): " new_view_distance
                if [[ "$new_view_distance" =~ ^[0-9]+$ && "$new_view_distance" -ge 3 && "$new_view_distance" -le 32 ]]; then
                    update_property "$properties_file" "view-distance" "$new_view_distance"
                else
                    log_error "Invalid input. Please enter a number between 3 and 32."
                fi
                ;;
            9)
                read -p "Allow Flight? (true/false): " new_allow_flight
                if [[ "$new_allow_flight" =~ ^(true|false)$ ]]; then
                    update_property "$properties_file" "allow-flight" "$new_allow_flight"
                else
                    log_error "Invalid input. Please enter 'true' or 'false'."
                fi
                ;;
            10)
                read -p "Enable Online Mode (premium accounts only)? (true/false): " new_online_mode
                if [[ "$new_online_mode" =~ ^(true|false)$ ]]; then
                    update_property "$properties_file" "online-mode" "$new_online_mode"
                else
                    log_error "Invalid input. Please enter 'true' or 'false'."
                fi
                ;;
            11)
                read -p "Enter Spawn Protection radius (0 for none): " new_spawn_prot
                if [[ "$new_spawn_prot" =~ ^[0-9]+$ ]]; then
                    update_property "$properties_file" "spawn-protection" "$new_spawn_prot"
                else
                    log_error "Invalid input. Please enter a number."
                fi
                ;;
            12)
                read -p "Enter new Level Seed (leave blank for random): " new_seed
                update_property "$properties_file" "level-seed" "$new_seed"
                ;;
            13)
                return # Exit this submenu
                ;;
            *)
                log_warning "Invalid option."
                ;;
        esac
        # Pause to show result
        if [[ "$choice" != "13" ]]; then
            read -n 1 -s -r -p "Press any key to continue..."
        fi
    done
}

# --- [UPDATED] Management menu for a selected server ---
manage_server() {
    local server_dir="$1"
    local session_name="$2"
    while true; do
        clear # Clear screen for better readability
        echo -e "\n${C_GREEN}===========================================${C_RESET}"
        echo -e "${C_CYAN}--- Managing Server: $session_name ---${C_RESET}"
        echo -e "${C_GREEN}===========================================${C_RESET}"
        echo "1) Start Server"
        echo "2) Stop Server"
        echo "3) Check Status"
        echo "4) Edit Server Properties"
        echo "5) Backup World"
        echo "6) View Logs"
        echo "7) Crash Protection Settings"
        echo "8) Update Server Version"
        echo "9) Show Screen Attach Info"
        echo "10) Back to Main Menu"
        read -p "Enter your choice [1-10]: " choice
        case $choice in
            1) start_server "$server_dir" "$session_name" ;;
            2) stop_server "$session_name" ;;
            3) check_status "$session_name" "$server_dir" ;;
            4) edit_server_properties "$server_dir" ;;
            5) backup_world "$server_dir" "$session_name" ;;
            6) view_logs "$server_dir" "$session_name" ;;
            7) manage_crash_protection "$server_dir" "$session_name" ;;
            8) update_server "$server_dir" "$session_name" ;;
            9) log_info "To attach to the server console: ${C_CYAN}screen -r $session_name${C_RESET}"; sleep 3 ;;
            10) return ;; # Exit this function, returning to select_server which then goes to main_menu
            *) log_warning "Invalid option. Please enter a number between 1 and 10." ;;
        esac
        # Only prompt to continue if not returning to main menu immediately
        if [[ "$choice" != "10" ]]; then
            read -n 1 -s -r -p "Press any key to continue..."
        fi
    done
}

#==============================================================================
# MAIN MENU & SCRIPT START
#==============================================================================

main_menu() {
    clear # Clear screen for a clean menu display
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo -e "${C_CYAN}    Minecraft Server Management Script     ${C_RESET}"
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo "1) Install a new Minecraft server"
    echo "2) Manage an existing Minecraft server"
    echo "3) View SDKMAN Java versions"
    echo "4) Exit"
    read -p "Enter your choice [1-4]: " choice
    case $choice in
        1) install_new_server; main_menu ;; # After installation, return to main menu
        2) select_server ;; # This function will handle returning to main_menu on its own
        3) sdk list java; read -n 1 -s -r -p "Press any key to continue..."; main_menu ;;
        4) echo "Exiting script. Goodbye!"; exit 0 ;;
        *) log_warning "Invalid choice. Please enter a number between 1 and 4."; sleep 2; main_menu ;;
    esac
}

#==============================================================================
# SCRIPT INITIALIZATION
#==============================================================================

# --- Initial Checks ---
# Ensure the script is not run as root for security and proper user environment
if [ "$EUID" -eq 0 ]; then
  log_error "This script should not be run as root. Please run it as a regular user."
  exit 1
fi

# Check and install SDKMAN if needed, then source its initialization script
install_sdkman
source_sdkman

# Check for other necessary system dependencies (wget, tar, screen, etc.)
check_base_dependencies

# Create the base directory for all Minecraft servers if it doesn't exist
mkdir -p "$SERVER_BASE_DIR"

# Start the main menu loop
main_menu
