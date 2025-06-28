#!/bin/bash
sudo apt install nmap socat iptables -y
# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

LISTEN_PORTS_FILE="/tmp/port_listeners.txt"
SCRIPT_DIR="$(dirname "$0")"

function print_menu {
    echo -e "${BLUE}1) Server"
    echo -e "2) Client"
    echo -e "3) Stop Server"
    echo -e "4) Exit${NC}"
    echo
    read -p "Select an option: " choice
}

select_port_file() {
    mapfile -t PORT_FILES < <(find . -maxdepth 1 -type f -name "*.port" | sort)
    if [[ ${#PORT_FILES[@]} -eq 0 ]]; then
        echo "No .port files found in current directory."
        return 1
    fi

    echo -e "\nAvailable .port files:"
    for i in "${!PORT_FILES[@]}"; do
        printf "%3d) %s\n" $((i + 1)) "${PORT_FILES[$i]#./}"
    done

    while true; do
        read -rp "Select a file by number (1-${#PORT_FILES[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#PORT_FILES[@]} )); then
            PORT_FILE="${PORT_FILES[$((choice - 1))]}"
            echo -e "\nUsing port file: ${PORT_FILE#./}"
            return 0
        else
            echo "Invalid selection. Try again."
        fi
    done
}


function server_mode {
    echo -e "${YELLOW}[+] Server Mode Selected${NC}"
    read -p "Apply iptables rules to restrict access? (y/n): " use_fw
    WHITELIST=""
    if [[ "$use_fw" == "y" ]]; then
        read -p "Enter whitelist IPs (comma separated, max 3): " WHITELIST
        IFS=',' read -ra IP_ARR <<< "$WHITELIST"
        echo -e "${GREEN}[+] Applying iptables rules...${NC}"

        # Allow SSH from anywhere
        sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT

        # Allow other ports from whitelist only
        for ip in "${IP_ARR[@]}"; do
            sudo iptables -A INPUT -s "$ip" -p tcp -j ACCEPT
            sudo iptables -A INPUT -s "$ip" -p udp -j ACCEPT
        done

        # Drop other TCP/UDP traffic
        sudo iptables -A INPUT -p tcp -j DROP
        sudo iptables -A INPUT -p udp -j DROP

        echo -e "${GREEN}[+] Firewall rules set. SSH (port 22) remains open to all.${NC}"

    fi

    read -p "Enter port range to listen (e.g., 1000-1200) Every 1000 port take ~ 1.5GB of ram: " PORT_RANGE
    START_PORT=$(echo $PORT_RANGE | cut -d'-' -f1)
    END_PORT=$(echo $PORT_RANGE | cut -d'-' -f2)

    echo -e "${BLUE}[+] Starting listeners from $START_PORT to $END_PORT...${NC}"
    > "$LISTEN_PORTS_FILE"
    for ((port=START_PORT; port<=END_PORT; port++)); do
        if ! ss -lntu | grep -q ":$port\b"; then
            socat TCP-LISTEN:$port,fork,reuseaddr EXEC:/bin/cat &>/dev/null &
            echo $! >> "$LISTEN_PORTS_FILE"
            socat -T1 UDP-RECVFROM:$port,fork EXEC:/bin/cat &>/dev/null &
            echo $! >> "$LISTEN_PORTS_FILE"
            echo -e "${GREEN}Listening on port $port (TCP/UDP)${NC}"
        else
            echo -e "${RED}Port $port is already in use, skipping...${NC}"
        fi
    done
    echo -e "${YELLOW}[+] Listening setup complete.${NC}"
}

function client_mode {
    echo -e "${YELLOW}[+] Client Mode Selected${NC}"
    read -p "Scan TCP or UDP? (tcp/udp): " PROTO
    read -p "Use port range or .port file? (range/file): " MODE

    if [[ "$MODE" == "range" ]]; then
        read -p "Enter port range (e.g., 23-65535): " PORT_RANGE
    else
        if ! select_port_file; then
                echo "Exiting due to missing .port file."
                exit 1
        fi
    fi

    read -p "Enter Server IP: " SERVER_IP

    if [[ "$MODE" == "range" ]]; then
        IFS='-' read -r START_PORT END_PORT <<< "$PORT_RANGE"
        PORT_LIST=$(seq "$START_PORT" "$END_PORT")
    else
        if [[ ! -s "$PORT_FILE" ]]; then
            echo -e "${RED}[-] Port file is empty or missing${NC}"
            return
        fi
        PORT_LIST=$(grep -E '^[0-9]+$' "$PORT_FILE")
    fi

    # Compose base name
    if [[ "$MODE" == "range" ]]; then
        CLEAN_RANGE="${PORT_RANGE//[^0-9\-]/}"  # Strip any unwanted characters
        OUTPUT_FILE="${SERVER_IP}_${PROTO}_${CLEAN_RANGE}.port"
    else
        OUTPUT_FILE="${SERVER_IP}_${PROTO}.port"
    fi

    # Handle duplicates by appending _2, _3, etc.
    n=1
    BASE_NAME="${OUTPUT_FILE%.port}"
    while [[ -e "$OUTPUT_FILE" ]]; do
        OUTPUT_FILE="${BASE_NAME}_$((++n)).port"
    done

    echo -e "${CYAN}[i] Output will be saved to: $OUTPUT_FILE${NC}"
    

    MAX_PARALLEL=100
    
    run_limited() {
        while (( $(jobs -r | wc -l) >= MAX_PARALLEL )); do
            sleep 0.1
        done
        "$@" &
    }

    scan_port() {
        local port=$1
        local response

        if [[ "$PROTO" == "tcp" ]]; then
            response=$(echo -n "knock knock" | nc -w1 "$SERVER_IP" "$port")
        else
            response=$(echo -n "knock knock" | timeout 2 nc -u -w1 "$SERVER_IP" "$port")
        fi

        if [[ "$response" == "knock knock" ]]; then
            echo "$port" >> "$OUTPUT_FILE"
            echo -e "${GREEN}[+] $PROTO $port open${NC}"
        else
            echo -e "${RED}[-] $PROTO $port no response${NC}"
        fi
    }

    for port in $PORT_LIST; do
        run_limited scan_port "$port"
    done

    wait    

    echo -e "${GREEN}[+] Scan complete. Results saved to $OUTPUT_FILE${NC}"
}

function stop_server {
    echo -e "${YELLOW}[+] Stopping all port listeners started by this script...${NC}"
    if [[ -f "$LISTEN_PORTS_FILE" ]]; then
        while read pid; do
            kill "$pid" &>/dev/null
        done < "$LISTEN_PORTS_FILE"
        rm -f "$LISTEN_PORTS_FILE"
        echo -e "${GREEN}[+] Listeners stopped.${NC}"
    else
        echo -e "${RED}No listener state file found.${NC}"
    fi

    echo -e "${YELLOW}[+] Flushing iptables rules set by script...${NC}"
    sudo iptables -F
}

# Main loop
while true; do
    echo -e "\n${BLUE}========== Port Connectivity Tool ==========${NC}"
    print_menu
    case $choice in
        1) server_mode ;;
        2) client_mode ;;
        3) stop_server ;;
        4) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
done
