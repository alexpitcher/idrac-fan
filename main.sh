#!/bin/bash

# Default values
VERBOSE=false
CONFIG_FILE="servers.json"

# --- Logging ---
log_debug() {
  if [ "$VERBOSE" = true ]; then
    echo "[DEBUG] $1"
  fi
}

# --- Configuration Management ---
initialize_config_file() {
  if [ ! -f "$CONFIG_FILE" ]; then
    log_debug "Config file not found. Creating empty servers.json."
    echo "[]" > "$CONFIG_FILE"
  fi
}

# --- Server Management ---
add_server() {
  echo "--- Add New Server ---"
  
  read -p "Enter a friendly name for this server (e.g., 'Proxmox Host 1'): " server_name
  read -p "Enter iDRAC IP Address: " ip
  read -p "Enter iDRAC Username: " user
  read -s -p "Enter iDRAC Password: " pass
  echo ""
  
  read -p "Do you want to configure optional LibreNMS integration? (y/n): " lnms_choice
  local lnms_url=""
  local lnms_token=""
  local device_id=""
  if [[ "$lnms_choice" == "y" || "$lnms_choice" == "Y" ]]; then
    read -p "Enter LibreNMS API URL: " lnms_url
    read -p "Enter LibreNMS API Token: " lnms_token
    read -p "Enter LibreNMS Device ID for this server: " device_id
  fi
  
  local encoded_user=$(echo -n "$user" | base64)
  local encoded_pass=$(echo -n "$pass" | base64)
  
  # Create a new server object
  local new_server=$(jq -n \
    --arg name "$server_name" \
    --arg ip "$ip" \
    --arg user "$encoded_user" \
    --arg pass "$encoded_pass" \
    --arg lnms_url "$lnms_url" \
    --arg lnms_token "$lnms_token" \
    --arg device_id "$device_id" \
    '{name: $name, ip: $ip, user: $user, pass: $pass, lnms_url: $lnms_url, lnms_token: $lnms_token, device_id: $device_id}')
    
  # Add the new server to the config file
  local updated_servers=$(jq ". += [$new_server]" "$CONFIG_FILE")
  echo "$updated_servers" > "$CONFIG_FILE"
  
  echo "Server '$server_name' added successfully."
  read -p "Press Enter to return to the main menu."
}

select_server() {
  local server_count=$(jq '. | length' "$CONFIG_FILE")

  if [ "$server_count" -eq 0 ]; then
    echo "No servers found. Please add a server first."
    read -p "Press Enter to return to the main menu."
    return
  fi

  local servers=$(jq -r '.[].name' "$CONFIG_FILE")
  
  echo "--- Select a Server ---"
  PS3="Please enter your choice: "
  select server_name in $servers "Back to Main Menu"; do
    if [[ "$REPLY" -eq $(($server_count + 1)) ]]; then
        break
    elif [ -n "$server_name" ]; then
      local server_details=$(jq -c ".[] | select(.name==\"$server_name\")" "$CONFIG_FILE")
      control_fan_speed "$server_details"
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done
  PS3="#? "
}


# --- Fan Control Logic ---
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

control_fan_speed() {
    local server_details=$1

    # Extract details from JSON
    local IP=$(echo "$server_details" | jq -r '.ip')
    local USER=$(echo "$server_details" | jq -r '.user' | base64 -d)
    local PASS=$(echo "$server_details" | jq -r '.pass' | base64 -d)
    local LIBRENMS_API_URL=$(echo "$server_details" | jq -r '.lnms_url')
    local LIBRENMS_API_TOKEN=$(echo "$server_details" | jq -r '.lnms_token')
    local DEVICE_ID=$(echo "$server_details" | jq -r '.device_id')

    echo "--- Controlling Fans for: $(echo "$server_details" | jq -r '.name') ---"

    read -p "Enter desired fan speed (0-100): " FAN_SPEED

    # Validate Fan Speed
    if ! [[ $FAN_SPEED =~ ^[0-9]+$ ]] || [ $FAN_SPEED -lt 0 ] || [ $FAN_SPEED -gt 100 ]; then
      echo "[ERROR] Invalid fan speed. Must be between 0 and 100."
      return
    fi

    # IPMI Commands
    local FAN_SPEED_HEX=$(printf '%x\n' $FAN_SPEED)
    log_debug "Setting fan speed to $FAN_SPEED% (0x$FAN_SPEED_HEX)"

    echo -n "Enabling manual fan control..."
    (ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1) &
    spinner $!
    echo "Done."

    echo -n "Setting fan speed to $FAN_SPEED%..."
    (ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x02 0xff 0x"$FAN_SPEED_HEX" >/dev/null 2>&1) &
    spinner $!
    echo "Done."
    
    local output_set=$(ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x02 0xff 0x"$FAN_SPEED_HEX" 2>&1)
    if [ $? -eq 0 ]; then
      echo "Successfully set fan speed to $FAN_SPEED% on $IP."
    else
      echo "[ERROR] Failed to set fan speed. Analyzing error..."
      if echo "$output_set" | grep -q "unauthorized name"; then
        echo "[ERROR] Authentication failed: Incorrect username."
      elif echo "$output_set" | grep -q "RAKP 2 HMAC is invalid"; then
        echo "[ERROR] Authentication failed: Incorrect password."
      elif echo "$output_set" | grep -q "Get Auth Capabilities error"; then
        echo "[ERROR] Connection failed: Incorrect IP address or IPMI not enabled."
      else
        echo "[ERROR] An unknown error occurred. IPMItool output:"
        echo "$output_set"
      fi
    fi
}

# --- Main Menu ---
main_menu() {
  while true; do
    echo "--- iDRAC Fan Control ---"
    echo "1. Select Server"
    echo "2. Add New Server"
    echo "3. Exit"
    read -p "Choose an option: " choice
    
    case $choice in
      1) select_server ;;
      2) add_server ;;
      3) exit 0 ;;
      *) echo "Invalid option. Please try again." ;;
    esac
  done
}
# --- Script Entry Point ---
# Initialize config file if it doesn't exist
initialize_config_file

# Parse command-line arguments for verbosity
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --verbose)
      VERBOSE=true
      shift
      ;; 
    *)
      shift
      ;; 
  esac
done

# Start the main menu
main_menu
