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
      read -p "Would you like to monitor the temperatures in the terminal? (y/n): " monitor_choice
      if [[ "$monitor_choice" == "y" || "$monitor_choice" == "Y" ]]; then
        monitor_temperatures "$LIBRENMS_API_URL" "$LIBRENMS_API_TOKEN" "$DEVICE_ID"
      fi
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
  local silent_mode=$4

  if [ -z "$api_url" ] || [ -z "$api_token" ] || [ -z "$device_id" ] || [ "$api_url" == "null" ] || [ "$api_token" == "null" ] || [ "$device_id" == "null" ]; then
    log_debug "LibreNMS not fully configured for this server. Skipping temperature check."
    return
  fi
  
  if [ "$silent_mode" != "silent" ]; then
    printf "Fetching temperatures from LibreNMS..."
  fi
  
  local sensors_response=$(curl -s -H "X-Auth-Token: $api_token" "$api_url/devices/$device_id/health/temperature")
  local sensor_ids=$(echo "$sensors_response" | jq -r '.graphs[].sensor_id')
  
  local temps=()
  local descriptions=()
  for sensor_id in $sensor_ids; do
    local temp_response=$(curl -s -H "X-Auth-Token: $api_token" "$api_url/devices/$device_id/health/device_temperature/$sensor_id")
    local temp=$(echo "$temp_response" | jq -r '.graphs[0].sensor_current')
    local desc=$(echo "$temp_response" | jq -r '.graphs[0].sensor_descr')
    
    if [ -n "$temp" ] && [ "$temp" != "null" ]; then
      temps+=($temp)
      descriptions+=($desc)
    fi
  done
  
  if [ ${#temps[@]} -eq 0 ]; then
    if [ "$silent_mode" != "silent" ]; then
      printf "\nNo temperature data found."
    fi
    return
  fi

  local sum=0
  local min=${temps[0]}
  local max=${temps[0]}
  local min_desc=${descriptions[0]}
  local max_desc=${descriptions[0]}
  local i=0
  for temp in "${temps[@]}"; do
    sum=$(($sum + $temp))
    if (( $(echo "$temp < $min" | bc -l) )); then
      min=$temp
      min_desc=${descriptions[$i]}
    fi
    if (( $(echo "$temp > $max" | bc -l) )); then
      max=$temp
      max_desc=${descriptions[$i]}
    fi
    i=$(($i + 1))
  done
  
  local avg=$(($sum / ${#temps[@]}))
  
  local summary="\nCore Temperatures: Avg: ${avg}°C | Max: ${max}°C (${max_desc}) | Min: ${min}°C (${min_desc})"
  
  for i in "${!temps[@]}"; do
    local temp=${temps[$i]}
    local desc=${descriptions[$i]}
    if [ "$(echo "$temp > $avg + 5" | bc -l)" -eq 1 ]; then
      summary+="\n[INFO] Outlier detected: $desc is at ${temp}°C (more than 5°C above average)."
    fi
    if [ "$(echo "$temp > 60" | bc -l)" -eq 1 ]; then
      summary+="\n[WARNING] High Temperature Alert! $desc is at ${temp}°C."
    fi
  done
  
  printf "%b" "$summary"
}

monitor_temperatures() {
    local api_url=$1
    local api_token=$2
    local device_id=$3
    local temp_history=()

    echo "Starting temperature monitoring... Press any key to stop."
    # Hide cursor
    tput civis
    # Clear the screen
    clear
    while true; do
        # Move cursor to top left
        tput cup 0 0
        
        local temp_info=$(fetch_core_temperatures "$api_url" "$api_token" "$device_id" "silent")
        echo "--- Temperature Monitoring ---"
        echo -e "$temp_info"
        
        local avg_temp=$(echo "$temp_info" | grep "Avg:" | awk '{print $4}' | cut -d'°' -f1)
        if [ -n "$avg_temp" ]; then
            temp_history+=($avg_temp)
        fi
        
        draw_graph "${temp_history[@]}"
        
        echo -e "\nPress any key to stop monitoring."
        
        # Wait for 5 seconds, but exit if a key is pressed
        for i in {1..5}; do
            if read -t 1 -n 1; then
                # Show cursor
                tput cnorm
                echo -e "\nMonitoring stopped."
                return
            fi
        done
    done
}

draw_graph() {
    local history=("$@")
    local max_width=50
    
    echo -e "\n--- Temperature Trend ---"
    for temp in "${history[@]}"; do
        local width=$(( ($temp * $max_width) / 100 ))
        printf "[ %3d°C ] " "$temp"
        for i in $(seq 1 $width); do
            printf "#"
        done
        echo ""
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
