#!/bin/bash

# SSH Port Changer - Menu based (supports ssh.socket)
# Must be run as root

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/root/ssh_port_backup"
FIXED_PORT=2222

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root.${NC}"
    exit 1
fi

# Get current SSH port from config
get_config_port() {
    local port
    port=$(grep -E "^Port\s+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -n1)
    if [[ -z "$port" ]]; then
        port=22
    fi
    echo "$port"
}

# Get actual listening port
get_listening_port() {
    local port
    port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | grep -oP ':\K[0-9]+' | head -n1)
    if [[ -z "$port" ]]; then
        port=$(get_config_port)
    fi
    echo "$port"
}

# Generate random high port (10000-60000)
generate_random_port() {
    echo $(( (RANDOM % 50000) + 10000 ))
}

# Detect and handle firewall
handle_firewall() {
    local new_port=$1
    local old_port=$2

    echo -e "${CYAN}Checking firewall...${NC}"

    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            echo -e "${YELLOW}UFW is active. Adding port $new_port...${NC}"
            ufw allow "$new_port/tcp" >/dev/null
            if [[ "$old_port" != "22" && "$old_port" != "$new_port" ]]; then
                ufw delete allow "$old_port/tcp" >/dev/null 2>&1 || true
            fi
            echo -e "${GREEN}UFW updated successfully.${NC}"
        else
            echo -e "${YELLOW}UFW is installed but not active. Skipping.${NC}"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
            echo -e "${YELLOW}firewalld is active. Adding port $new_port...${NC}"
            firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null
            if [[ "$old_port" != "22" && "$old_port" != "$new_port" ]]; then
                firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1 || true
            fi
            firewall-cmd --reload >/dev/null
            echo -e "${GREEN}firewalld updated successfully.${NC}"
        else
            echo -e "${YELLOW}firewalld is installed but not active. Skipping.${NC}"
        fi
    else
        echo -e "${YELLOW}No supported firewall (ufw/firewalld) detected. Please open the port manually if needed.${NC}"
    fi
}

# Restart SSH properly (supports socket activation)
restart_ssh() {
    echo -e "${CYAN}Reloading systemd and restarting SSH...${NC}"

    systemctl daemon-reload

    if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        echo -e "${YELLOW}Detected ssh.socket (socket activation). Restarting socket...${NC}"
        systemctl restart ssh.socket
    elif systemctl list-unit-files | grep -q '^sshd.service'; then
        systemctl restart sshd
    else
        systemctl restart ssh
    fi
}

# Change SSH port
change_port() {
    local new_port=$1
    local current_port
    current_port=$(get_listening_port)

    # Validate port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 || "$new_port" -gt 65535 ]]; then
        echo -e "${RED}Invalid port number. Must be between 1 and 65535.${NC}"
        return 1
    fi

    if [[ "$new_port" -eq "$current_port" ]]; then
        echo -e "${YELLOW}Port is already set to $new_port. Nothing to do.${NC}"
        return 0
    fi

    # Backup
    mkdir -p "$BACKUP_DIR"
    local backup_file="${BACKUP_DIR}/sshd_config_$(date +%Y%m%d_%H%M%S).bak"
    cp "$SSHD_CONFIG" "$backup_file"
    echo -e "${GREEN}Backup created: $backup_file${NC}"

    # Update config
    if grep -qE "^Port\s+" "$SSHD_CONFIG"; then
        sed -i "s/^Port\s\+.*/Port $new_port/" "$SSHD_CONFIG"
    elif grep -qE "^#Port\s+" "$SSHD_CONFIG"; then
        sed -i "s/^#Port\s\+.*/Port $new_port/" "$SSHD_CONFIG"
    else
        # Insert after the first few lines or at the end
        echo "Port $new_port" >> "$SSHD_CONFIG"
    fi

    # Test config
    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}sshd configuration test failed! Restoring backup...${NC}"
        cp "$backup_file" "$SSHD_CONFIG"
        return 1
    fi

    # Handle firewall
    handle_firewall "$new_port" "$current_port"

    # Restart
    restart_ssh

    # Verify
    sleep 1
    local actual
    actual=$(get_listening_port)

    if [[ "$actual" == "$new_port" ]]; then
        echo -e "${GREEN}SSH port successfully changed from $current_port to $new_port${NC}"
    else
        echo -e "${YELLOW}Warning: Config updated but listening port is still $actual${NC}"
        echo -e "${YELLOW}Trying socket override method...${NC}"

        # Fallback: create socket override
        mkdir -p /etc/systemd/system/ssh.socket.d
        cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$new_port
ListenStream=[::]:$new_port
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket
        sleep 1
        actual=$(get_listening_port)
        if [[ "$actual" == "$new_port" ]]; then
            echo -e "${GREEN}SSH port successfully changed to $new_port (using socket override)${NC}"
        else
            echo -e "${RED}Failed to change listening port. Please check manually.${NC}"
            return 1
        fi
    fi

    echo -e "${YELLOW}IMPORTANT: Test the new connection in another terminal before closing this one!${NC}"
    echo -e "${YELLOW}Command example: ssh -p $new_port user@your-server${NC}"
}

# Main menu
show_menu() {
    clear
    local current
    current=$(get_listening_port)
    local config_port
    config_port=$(get_config_port)

    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}       SSH Port Changer Script         ${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo
    echo -e "Listening port : ${GREEN}$current${NC}"
    echo -e "Config Port    : ${GREEN}$config_port${NC}"
    echo
    echo "1) Change to a custom port"
    echo "2) Change to a random suggested port"
    echo "3) Change to fixed alternative port ($FIXED_PORT)"
    echo "4) Exit"
    echo
    read -rp "Select an option [1-4]: " choice

    case $choice in
        1)
            read -rp "Enter the new port number: " custom_port
            change_port "$custom_port"
            ;;
        2)
            random_port=$(generate_random_port)
            echo -e "Suggested random port: ${GREEN}$random_port${NC}"
            read -rp "Do you want to use this port? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                change_port "$random_port"
            else
                echo "Cancelled."
            fi
            ;;
        3)
            echo -e "Changing to fixed port: ${GREEN}$FIXED_PORT${NC}"
            change_port "$FIXED_PORT"
            ;;
        4)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option.${NC}"
            ;;
    esac
}

# Run
show_menu
