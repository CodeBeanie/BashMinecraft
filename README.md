Minecraft Server Manager Script
A comprehensive Bash script designed to simplify the installation and management of various Minecraft server types (Vanilla, Fabric, Forge, Paper, Modpacks) on Linux systems. It includes automatic Java version detection and installation via SDKMAN, robust crash protection with auto-restart functionality, and a user-friendly menu-driven interface.
🚀 Features
Multi-Server Type Support: Install Vanilla, Fabric, Forge, and PaperMC servers.
Modpack Support: Basic support for installing modpacks from ZIP archives (CurseForge/Modrinth require manual download).
Automated Java Management: Automatically detects and installs the correct Java Development Kit (JDK) version required for specific Minecraft versions using SDKMAN!.
Memory Allocation: Configure server memory (RAM) during installation.
Crash Protection:
Monitors server crashes within a defined time window.
Automatically restarts the server up to a configurable maximum number of times.
Disables auto-restart if the crash limit is reached to prevent endless loops.
Provides options to reset crash tracking and manually enable/disable auto-restart.
Server Management:
Start/Stop: Start and gracefully stop Minecraft servers.
Status Check: View server running status, process ID, uptime, and crash protection status.
World Backup: Create gzipped tar archives of your Minecraft world folders.
Log Viewer: Easily view the latest server logs.
Server Update: Attempt to update existing Vanilla, Paper, Fabric, or Forge servers to newer Minecraft versions or the latest build of their current version.
Screen Integration: Servers run in screen sessions, allowing for easy detachment and re-attachment to the server console.
Dependency Check: Automatically checks for and offers to install necessary system dependencies (wget, tar, screen, tmux, unzip, jq, curl).
EULA Acceptance: Automatically accepts the Minecraft EULA.
User-Friendly Interface: Menu-driven interaction for ease of use.
💻 Compatibility
This script is designed for Linux distributions that support bash and common package managers (apt-get, yum, dnf, pacman). It heavily relies on SDKMAN! for Java management.
📋 Prerequisites
The script will attempt to install most of these, but it's good to be aware:
Bash: The shell itself (usually pre-installed).
curl: Used for installing SDKMAN.
wget: Used for downloading server JARs.
tar: Used for creating world backups.
screen: Used for running servers in detached sessions.
tmux: (Optional, but checked) A terminal multiplexer.
unzip: Used for extracting modpack ZIPs.
jq: A lightweight and flexible command-line JSON processor, essential for parsing API responses (Mojang, PaperMC).
SDKMAN!: The script will prompt and attempt to install SDKMAN! if it's not found. It's crucial for managing Java versions.
Important: This script should NOT be run as root. Run it as a regular user.
🚀 Installation & Setup
Download the script:
wget https://raw.githubusercontent.com/your-username/your-repo-name/main/minecraft_manager.sh -O minecraft_manager.sh

(Replace your-username and your-repo-name with your actual GitHub details if you fork/host it.)
Make the script executable:
chmod +x minecraft_manager.sh


Run the script:
./minecraft_manager.sh


The first time you run it, the script will check for and offer to install SDKMAN! and other system dependencies.
If SDKMAN! is installed, you might be prompted to restart your terminal or source ~/.bashrc (or your shell's equivalent) before re-running the script. Follow the on-screen instructions.
🎮 Usage
Upon running the script, you'll be presented with the main menu:
===========================================
    Minecraft Server Management Script     
===========================================
1) Install a new Minecraft server
2) Manage an existing Minecraft server
3) View SDKMAN Java versions
4) Exit
Enter your choice [1-4]: 


1. Install a new Minecraft server
Select Server Type: Choose between Vanilla, Fabric, Forge, Paper (Spigot is aliased to Paper), or Modpack.
Minecraft Version: Enter the desired Minecraft version (e.g., 1.21.5, 1.19.4). The script will automatically determine and install the correct Java version for it.
Memory Allocation: Specify the RAM for your server (e.g., 2G, 4G, 8G).
Server Name: A default name like paper_1.21.5 will be suggested, but you can customize it.
Installation Process: The script will download the necessary files, create the server directory, generate a start.sh script with crash protection, and accept the EULA.
Modpack Installation Notes:
For CurseForge and Modrinth modpacks, the script currently provides a simplified approach. You will likely need to manually download the server files (usually a ZIP) from their respective websites and then use the "Manual ZIP file" option, or place the extracted files in the server directory created by the script.
After extracting a modpack, you might need to manually verify the main server JAR or start script within the server directory if the script cannot auto-detect it.
2. Manage an existing Minecraft server
This option lists all servers found in your ~/minecraft_servers directory. Select a server to access its management menu:
--- Managing Server: your_server_name ---
1) Start Server
2) Stop Server
3) Check Status
4) Backup World
5) View Logs
6) Crash Protection Settings
7) Update Server Version
8) Show Screen Attach Info
9) Back to Main Menu


Start Server: Launches the server in a detached screen session. You'll get instructions on how to attach to its console.
Stop Server: Sends a graceful stop command to the server.
Check Status: Displays if the server is running, its PID, uptime, and current crash protection status.
Backup World: Creates a gzipped tar archive of your server's world folder in a backups subdirectory. If the server is running, it will temporarily disable auto-saving for a consistent backup.
View Logs: Shows the last 50 lines of the latest.log file.
Crash Protection Settings: Allows you to view crash counts, reset crash tracking, and manually enable/disable the auto-restart feature.
Update Server Version: Attempts to update the server. You can specify a new Minecraft version or update to the latest build of the current version. Always back up your server before updating!
Show Screen Attach Info: Provides the command to re-attach to your server's console.
3. View SDKMAN Java versions
Lists all Java versions installed via SDKMAN. Useful for debugging Java-related issues.
4. Exit
Exits the script.
🛡️ Crash Protection Explained
The script implements a basic crash protection mechanism:
Tracking: It records crashes in .crash_count and .last_crash_time files within each server's directory.
Window: Crashes are counted within a CRASH_WINDOW (default: 5 minutes). If a crash occurs outside this window, the count resets.
Limit: If the number of crashes reaches MAX_CRASHES (default: 3) within the CRASH_WINDOW, auto-restart is disabled by creating a .auto_restart_disabled flag file.
Restart Delay: After a crash, the server waits for RESTART_DELAY (default: 30 seconds) before attempting a restart.
Resetting: You can reset the crash tracking (and re-enable auto-restart) via the "Crash Protection Settings" menu.
☕ Java Version Management
The resolve_java_dependency function automatically determines the recommended Java version for your chosen Minecraft version:
Minecraft 1.21+: Requires Java 21.
Minecraft 1.17 - 1.20.x: Requires Java 17.
Older Versions: Defaults to Java 17.
If the required Java version is not found via SDKMAN, the script will prompt you to install it. The start.sh script generated for each server will explicitly use the correct Java executable path from your SDKMAN installations.
🤝 Contributing
Contributions are welcome! If you find bugs, have suggestions for improvements, or want to add new features, please feel free to:
Fork the repository.
Create a new branch (git checkout -b feature/your-feature).
Make your changes.
Commit your changes (git commit -am 'Add new feature').
Push to the branch (git push origin feature/your-feature).
Create a new Pull Request.
📄 License
This project is licensed under the MIT License - see the LICENSE file for details.
👤 Author
Ian Legrand (Original Author)

