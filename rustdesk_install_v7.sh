#!/bin/bash

# --- START OF FINAL REVISED SCRIPT (v6) ---

# Set -e: Exit immediately if a command exits with a non-zero status.
# Set -u: Treat unset variables as an error when substituting.
# Set -o pipefail: If any command in a pipeline fails, the whole pipeline fails.
set -euo pipefail

# Function to display messages with timestamps and emphasis
log_message() {
    echo -e "\n\e[1;34m$(date '+%Y-%m-%d %H:%M:%S') - $1\e[0m" # Bold blue message
}

# Function to display warning messages
warn_message() {
    echo -e "\n\e[1;33m$(date '+%Y-%m-%d %H:%M:%S') - WARNING: $1\e[0m" # Bold yellow warning
}

# Function to execute commands, display output, and handle errors robustly
# Returns 0 on success, 1 on failure.
execute_command() {
    local cmd="$1"
    log_message "Executing command: \e[1;33m$cmd\e[0m" # Bold yellow command
    
    if ! eval "$cmd" 2>&1; then
        log_message "\e[1;31mERROR: Command failed.\e[0m Please review the output above." # Bold red error
        return 1 # Return 1 instead of exiting directly, to allow conditional logic
    fi
    return 0
}

# Get current Fedora version
FEDORA_VERSION=$(grep -oP 'VERSION_ID=\K\d+' /etc/os-release)
log_message "Detected Fedora version: ${FEDORA_VERSION}"

log_message "Starting RustDesk setup for Fedora ${FEDORA_VERSION} with Windows client compatibility."
log_message "This script will attempt to install RustDesk using the Copr repository first. If that fails (e.g., if a build for Fedora ${FEDORA_VERSION} is not yet available), it will offer to install via Flatpak."

log_message "Step 1: Updating your system to ensure all packages are current."
log_message "This is crucial for system stability, security, and to prevent potential package conflicts during installation."
execute_command "sudo dnf update -y"
execute_command "sudo dnf upgrade -y"

log_message "Step 2: Attempting to add the RustDesk Copr repository."
log_message "RustDesk is not included in Fedora's official repositories. The atim/rustdesk Copr repository is the officially recommended way to install it as an RPM."
log_message "If this step fails with a '404 Not Found' error, it means the Copr repository maintainer has not yet built RustDesk for Fedora ${FEDORA_VERSION}."

# Ensure dnf-plugins-core is installed for 'copr' functionality.
if ! execute_command "sudo dnf install -y dnf-plugins-core"; then
    log_message "Failed to install dnf-plugins-core. This is critical for Copr. Exiting."
    exit 1
fi

# Attempt to enable Copr.
if ! execute_command "sudo dnf copr enable atim/rustdesk -y"; then
    warn_message "Failed to enable atim/rustdesk Copr repository for Fedora ${FEDORA_VERSION}."
    warn_message "This often happens if the Copr maintainer has not yet built packages for the latest Fedora release."
    log_message "You have two main options:"
    log_message "1. Wait: Check the Copr page (https://copr.fedorainfracloud.org/coprs/atim/rustdesk/) later for Fedora ${FEDORA_VERSION} builds."
    log_message "2. Install via Flatpak: This is a highly recommended and robust alternative that is less dependent on specific Fedora releases."

    read -p "$(log_message "Do you want to proceed with Flatpak installation instead? (y/N): ")" -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_message "Proceeding with Flatpak installation."

        log_message "Step 2b: Installing RustDesk via Flatpak."
        log_message "Flatpak provides sandboxed applications, which is a very reliable way to install RustDesk regardless of your specific Fedora release."
        
        execute_command "sudo dnf install -y flatpak"
        execute_command "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
        execute_command "flatpak install flathub com.rustdesk.RustDesk -y"

        log_message "RustDesk Flatpak installation complete!"
        log_message "You can launch RustDesk using: flatpak run com.rustdesk.RustDesk"
        log_message "Or find it in your applications menu."
        
        # Skip remaining RPM-specific steps and jump to final instructions
        log_message "Skipping remaining RPM-specific steps (3, 4, 5) as Flatpak was chosen."
        
        # Jumps to the general instructions after Flatpak installation
        goto_final_instructions=true 
    else
        log_message "Flatpak installation declined. The script cannot proceed with RPM installation for Fedora ${FEDORA_VERSION} at this time due to the Copr repository issue."
        log_message "Please wait for Copr builds for Fedora ${FEDORA_VERSION} or consider manual installation."
        exit 1
    fi
else # Copr enabled successfully
    log_message "Copr repository enabled successfully for Fedora ${FEDORA_VERSION}."
    
    log_message "Step 3: Installing RustDesk."
    log_message "With the Copr repository enabled, we can now install the RustDesk package along with its necessary dependencies."
    execute_command "sudo dnf install -y rustdesk"

    log_message "Step 4: Starting and enabling the RustDesk systemd service."
    log_message "RustDesk runs as a systemd service. We need to start it now and configure it to automatically launch whenever your system boots up, ensuring it's always ready for connections."
    execute_command "sudo systemctl start rustdesk.service"
    execute_command "sudo systemctl enable rustdesk.service"
    log_message "Checking the status of the RustDesk service to confirm it's running correctly:"
    execute_command "sudo systemctl status rustdesk.service --no-pager" # --no-pager prevents 'less' from opening

    log_message "Step 5: Configuring Firewall (FirewallD on Fedora)."
    log_message "For optimal and reliable connections, especially if you are behind a restrictive network or router, it's recommended to open RustDesk's primary ports in your firewall."
    log_message "RustDesk typically uses TCP ports 21115-21119 and UDP port 21116."
    log_message "Checking current firewall-cmd status..."
    execute_command "sudo firewall-cmd --state"

    log_message "If 'firewall-cmd --state' shows 'running', you may want to open these ports. If your firewall is not running or managed by another tool, this step might not be strictly necessary, but it's good practice."
    log_message "Applying recommended firewall rules for RustDesk:"
    execute_command "sudo firewall-cmd --permanent --add-port=21115-21119/tcp"
    execute_command "sudo firewall-cmd --permanent --add-port=21116/udp"
    execute_command "sudo firewall-cmd --reload"
    log_message "Firewall configuration updated. You should see 'success' messages above for each rule added and for the reload."
    
    log_message "RustDesk RPM installation and setup on Fedora is complete!"
    log_message "You can now launch the RustDesk GUI from your applications menu (search for 'RustDesk') or by typing 'rustdesk' in the terminal."

    goto_final_instructions=true
fi


if [[ "$goto_final_instructions" = true ]]; then
    log_message "\nInstructions for Windows Clients to Connect to this Fedora Machine:"
    log_message "1.  **Download RustDesk for Windows:** Visit the official RustDesk website (https://rustdesk.com/) and download the client for Windows."
    log_message "2.  **Install and Run:** Install and launch the RustDesk application on your Windows machine."
    log_message "3.  **Identify on Fedora:** On your Fedora machine, open the RustDesk GUI. You will see 'Your ID' (a 9-digit number) and 'Password' (a randomly generated alphanumeric string)."
    log_message "4.  **Connect from Windows:** On the Windows client, enter the 'Your ID' from your Fedora machine into the 'Remote ID' field."
    log_message "5.  **Initiate Connection:** Click the 'Connect' button on the Windows client."
    log_message "6.  **Enter Password:** When prompted by the Windows client, enter the 'Password' displayed on your Fedora RustDesk GUI."
    log_message "7.  **Access Granted:** You should now establish a secure remote desktop connection from your Windows client to your Fedora desktop!"

    log_message "Advanced Configuration / Troubleshooting Tips:"
    log_message "-   **Self-Hosting Relay/Rendezvous Server:** For enhanced privacy or performance in specific network environments, you can self-host RustDesk's relay and rendezvous servers. Refer to the official RustDesk documentation on GitHub for detailed setup guides."
    log_message "-   **Connection Issues:** If you experience difficulty connecting, ensure both machines have active internet access and double-check the entered ID and password. Review firewall settings on both ends."
    log_message "-   **Network Configuration:** If your Fedora machine is behind a router, you might need to configure port forwarding on your router to direct the RustDesk ports (21115-21119 TCP, 21116 UDP) to your Fedora machine's local IP address, especially for direct P2P connections without relying solely on RustDesk's public relay servers."
    log_message "-   **Restart Service:** Sometimes, restarting the RustDesk service (\`sudo systemctl restart rustdesk.service\`) can resolve minor issues."

    log_message "Setup finished. Enjoy a secure and efficient remote desktop experience with RustDesk!"
fi

# --- END OF FINAL REVISED SCRIPT (v6) ---