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

    # Temperature check
    fetch_core_temperatures "$LIBRENMS_API_URL" "$LIBRENMS_API_TOKEN" "$DEVICE_ID"

    read -p "Enter desired fan speed (0-100): " FAN_SPEED

    # Validate Fan Speed
    if ! [[ $FAN_SPEED =~ ^[0-9]+$ ]] || [ $FAN_SPEED -lt 0 ] || [ $FAN_SPEED -gt 100 ]; then
      echo "[ERROR] Invalid fan speed. Must be between 0 and 100."
      return
    fi

    # IPMI Commands
    local FAN_SPEED_HEX=$(printf '%x\n' $FAN_SPEED)
    log_debug "Setting fan speed to $FAN_SPEED% (0x$FAN_SPEED_HEX)"

    log_debug "Sending command to enable manual fan control..."
    local output_enable=$(ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x01 0x00 2>&1)
    if [ $? -ne 0 ]; then
      echo "[ERROR] Failed to enable manual fan control. IPMItool output:"
      echo "$output_enable"
      return
    fi
    log_debug "Manual fan control enabled."

    log_debug "Sending command to set fan speed..."
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


fetch_core_temperatures() {
  local api_url=$1
  local api_token=$2
  local device_id=$3

  if [ -z "$api_url" ] || [ -z "$api_token" ] || [ -z "$device_id" ] || [ "$api_url" == "null" ] || [ "$api_token" == "null" ] || [ "$device_id" == "null" ]; then
    log_debug "LibreNMS not fully configured for this server. Skipping temperature check."
    return
  fi
  
  log_debug "Fetching list of temperature sensors from LibreNMS API..."
  local sensors_response=$(curl -s -H "X-Auth-Token: $api_token" "$api_url/devices/$device_id/health/temperature")
  
  if [ $? -ne 0 ]; then
      echo "[WARNING] Failed to fetch temperature sensor list from LibreNMS for device ID $device_id. Curl error."
      return
  fi

  if ! echo "$sensors_response" | jq -e . >/dev/null 2>&1; then
      echo "[WARNING] Received invalid JSON response when fetching sensor list for device ID $device_id. Response: $sensors_response"
      return
  fi

  local sensor_ids=$(echo "$sensors_response" | jq -r '.graphs[].sensor_id')
  
  if [ -z "$sensor_ids" ]; then
      echo "[WARNING] No temperature sensors found for device ID $device_id."
      return
  fi

  log_debug "Found sensor IDs: $sensor_ids"
  
  local core_temperatures=""
  for sensor_id in $sensor_ids; do
    log_debug "Fetching temperature for sensor ID $sensor_id..."
    local temp_response=$(curl -s -H "X-Auth-Token: $api_token" "$api_url/devices/$device_id/health/device_temperature/$sensor_id")
    local temp=$(echo "$temp_response" | jq -r '.graphs[0].sensor_current')
    
    if [ -n "$temp" ] && [ "$temp" != "null" ]; then
      core_temperatures="$core_temperatures $temp"
    fi
  done

  log_debug "Core temperatures: $core_temperatures"

  for temp in $core_temperatures; do
    if [ "$(echo "$temp > 60" | bc -l)" -eq 1 ]; then
      echo "[WARNING] High Temperature Alert! A core temperature on device ID $device_id is above 60°C ($temp°C). Consider a higher fan speed."
      break
    fi
  done
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
