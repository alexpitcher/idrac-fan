#!/bin/bash

# Default values
VERBOSE=false
CONFIG_FILE="servers.json"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
dGRAY='\033[1;30m'
NC='\033[0m' # No Color

# --- Logging ---
log_debug() {
  if [ "$VERBOSE" = true ]; then
    echo -e "${dGRAY}[DEBUG] $1${NC}"
  fi
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# --- Configuration Management ---
initialize_config_file() {
  if [ ! -f "$CONFIG_FILE" ]; then
    log_debug "Config file not found. Creating empty servers.json."
    echo "[]" > "$CONFIG_FILE"
  fi
}

# --- Server Management ---
# --- Server Management ---
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

test_connection() {
    local ip=$1
    local user=$2
    local pass=$3
    
    echo -e "${YELLOW}Testing connection to $ip...${NC}"
    if ipmitool -I lanplus -H "$ip" -U "$user" -P "$pass" raw 0x06 0x01 >/dev/null 2>&1; then
        log_success "Connection successful!"
        return 0
    else
        log_error "Connection failed. Please check IP and credentials."
        return 1
    fi
}

add_server() {
  echo -e "\n--- ${GREEN}Add New Server${NC} ---"
  
  read -p "Enter a friendly name for this server (e.g., 'Proxmox Host 1'): " server_name
  
  while true; do
      read -p "Enter iDRAC IP Address: " ip
      if validate_ip "$ip"; then
          break
      else
          log_error "Invalid IP address format."
      fi
  done

  read -p "Enter iDRAC Username [root]: " user
  user=${user:-root}
  
  read -s -p "Enter iDRAC Password: " pass
  echo ""
  
  # Test connection immediately
  test_connection "$ip" "$user" "$pass"
  
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
  
  log_success "Server '$server_name' added successfully."
  read -p "Press Enter to return to the menu."
}

edit_server() {
  local server_count=$(jq '. | length' "$CONFIG_FILE")

  if [ "$server_count" -eq 0 ]; then
    log_warning "No servers found to edit."
    read -p "Press Enter to return."
    return
  fi

  # Generate display list "Name (IP)"
  local options=$(jq -r '.[] | "\(.name) (\(.ip))"' "$CONFIG_FILE")
  
  echo -e "\n--- ${YELLOW}Edit Server${NC} ---"
  PS3="Select server to edit: "
  select option in $options "Cancel"; do
    if [[ "$REPLY" -eq $(($server_count + 1)) ]]; then
        break
    elif [ "$REPLY" -gt 0 ] && [ "$REPLY" -le "$server_count" ]; then
      local index=$(($REPLY - 1))
      # Use index to get details
      local server_details=$(jq -c ".[$index]" "$CONFIG_FILE")
      local server_name=$(echo "$server_details" | jq -r '.name')
      
      local cur_ip=$(echo "$server_details" | jq -r '.ip')
      local cur_user=$(echo "$server_details" | jq -r '.user' | base64 -d)
      ## Decode password? No, keep it hidden or leave blank to keep unchanged
      
      echo -e "\nEditing '${server_name}' (Press Enter to keep current value)"
      
      # Name
      read -p "Name [$server_name]: " new_name
      new_name=${new_name:-$server_name}
      
      # IP
      local new_ip
      while true; do
          read -p "IP Address [$cur_ip]: " input_ip
          if [ -z "$input_ip" ]; then
              new_ip=$cur_ip
              break
          elif validate_ip "$input_ip"; then
              new_ip=$input_ip
              break
          else
              log_error "Invalid IP address format."
          fi
      done
      
      # User
      read -p "Username [$cur_user]: " new_user
      new_user=${new_user:-$cur_user}
      
      # Password
      read -s -p "Password [Unchanged]: " new_pass
      echo ""
      
      local encoded_user=$(echo -n "$new_user" | base64)
      local encoded_pass
      if [ -n "$new_pass" ]; then
         encoded_pass=$(echo -n "$new_pass" | base64)
      else
         encoded_pass=$(echo "$server_details" | jq -r '.pass')
      fi
      
      local updated_servers=$(jq ".[$index].name = \"$new_name\" | .[$index].ip = \"$new_ip\" | .[$index].user = \"$encoded_user\" | .[$index].pass = \"$encoded_pass\"" "$CONFIG_FILE")
      echo "$updated_servers" > "$CONFIG_FILE"
      
      log_success "Server updated successfully."
            
      # Test connection
      read -p "Test connection now? (y/n): " test_choice
      if [[ "$test_choice" == "y" || "$test_choice" == "Y" ]]; then
          if [ -n "$new_pass" ]; then pass_to_test=$new_pass; else pass_to_test=$(echo "$server_details" | jq -r '.pass' | base64 -d); fi
          test_connection "$new_ip" "$new_user" "$pass_to_test"
      fi

      break
    else
      log_error "Invalid selection."
    fi
  done
  PS3="#? "
}

delete_server() {
  local server_count=$(jq '. | length' "$CONFIG_FILE")

  if [ "$server_count" -eq 0 ]; then
    log_warning "No servers found to delete."
    read -p "Press Enter to return."
    return
  fi

  # Generate display list "Name (IP)"
  local options=$(jq -r '.[] | "\(.name) (\(.ip))"' "$CONFIG_FILE")
  
  echo -e "\n--- ${RED}Delete Server${NC} ---"
  PS3="Select server to delete: "
  select option in $options "Cancel"; do
    if [[ "$REPLY" -eq $(($server_count + 1)) ]]; then
        break
    elif [ "$REPLY" -gt 0 ] && [ "$REPLY" -le "$server_count" ]; then
      local index=$(($REPLY - 1))
      local server_name=$(jq -r ".[$index].name" "$CONFIG_FILE")
      
      read -p "Are you sure you want to delete '$server_name'? (y/n): " confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
          local updated_servers=$(jq "del(.[$index])" "$CONFIG_FILE")
          echo "$updated_servers" > "$CONFIG_FILE"
          log_success "Server '$server_name' deleted."
      else
          echo "Deletion cancelled."
      fi
      break
    else
      log_error "Invalid selection."
    fi
  done
  PS3="#? " 
}

manage_servers() {
    while true; do
        echo -e "\n--- ${YELLOW}Manage Servers${NC} ---"
        echo "1. Add New Server"
        echo "2. Edit Server"
        echo "3. Delete Server"
        echo "4. Back to Main Menu"
        read -p "Choose an option: " choice
        
        case $choice in
            1) add_server ;;
            2) edit_server ;;
            3) delete_server ;;
            4) return ;;
            *) log_error "Invalid option." ;;
        esac
    done
}

select_server() {
  local server_count=$(jq '. | length' "$CONFIG_FILE")

  if [ "$server_count" -eq 0 ]; then
    log_warning "No servers found. Please add a server first."
    read -p "Press Enter to return to the main menu."
    return
  fi

  # Generate display list "Name (IP)"
  # jq -r outputs lines, select expects space separated unless IFS is set. 
  # We should use IFS=$'\n' to handle spaces in names properly, though simple names are fine.
  old_IFS=$IFS
  IFS=$'\n'
  local options=$(jq -r '.[] | "\(.name) (\(.ip))"' "$CONFIG_FILE")
  
  echo -e "\n--- ${GREEN}Select a Server${NC} ---"
  PS3="Please enter your choice: "
  select option in $options "Back to Main Menu"; do
    if [[ "$REPLY" -eq $(($server_count + 1)) ]]; then
        break
    elif [ "$REPLY" -gt 0 ] && [ "$REPLY" -le "$server_count" ]; then
      local index=$(($REPLY - 1))
      local server_details=$(jq -c ".[$index]" "$CONFIG_FILE")
      control_fan_speed "$server_details"
      break
    else
      log_error "Invalid selection. Please try again."
    fi
  done
  IFS=$old_IFS
  PS3="#? "
}


# --- Fan Control Logic ---
# --- Helper Functions ---
execute_ipmi_command() {
    local description=$1
    shift
    local cmd=("$@")
    
    echo -n "$description..."
    
    local temp_out=$(mktemp)
    
    # Run the command in the background, redirecting output
    "${cmd[@]}" > "$temp_out" 2>&1 &
    local pid=$!
    
    # Run the spinner
    spinner $pid
    
    # Wait for the command to finish and get exit code
    wait $pid
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}Done.${NC}"
        rm "$temp_out"
        return 0
    else
        echo -e "${RED}Failed.${NC}"
        log_error "Command failed with exit code $exit_code."
        echo "Output:"
        cat "$temp_out"
        
        # Analyze error output for common issues
        if grep -q "unauthorized name" "$temp_out"; then
            log_error "Authentication failed: Incorrect username."
        elif grep -q "RAKP 2 HMAC is invalid" "$temp_out"; then
            log_error "Authentication failed: Incorrect password."
        elif grep -q "Get Auth Capabilities error" "$temp_out"; then
            log_error "Connection failed: Incorrect IP address or IPMI not enabled."
        fi
        
        rm "$temp_out"
        return $exit_code
    fi
}

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

    echo -e "\n--- Controlling Fans for: ${GREEN}$(echo "$server_details" | jq -r '.name')${NC} ---"

    # Attempt to get current status (optional, don't fail if this fails details)
    echo -n "Getting current status..."
    local status_output=$(ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" sdr type fan 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Done.${NC}"
        echo -e "${dGRAY}$status_output${NC}"
    else
        echo -e "${YELLOW}Skipped (Could not retrieve status)${NC}"
    fi

    echo -e "Enter desired fan speed (0-100) or '${YELLOW}auto${NC}' to reset to automatic control."
    read -p "Fan Speed: " FAN_SPEED

    # Handle Auto Mode
    if [[ "$FAN_SPEED" == "auto" || "$FAN_SPEED" == "-1" ]]; then
        log_debug "Resetting to automatic fan control."
        if execute_ipmi_command "Resetting to Automatic Control" ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x01 0x01; then
            log_success "Fan control reset to automatic."
        else
            log_error "Failed to reset fan control."
        fi
        return
    fi

    # Validate Fan Speed
    if ! [[ $FAN_SPEED =~ ^[0-9]+$ ]] || [ $FAN_SPEED -lt 0 ] || [ $FAN_SPEED -gt 100 ]; then
      log_error "Invalid fan speed. Must be between 0 and 100."
      return
    fi

    # IPMI Commands
    local FAN_SPEED_HEX=$(printf '%x\n' $FAN_SPEED)
    log_debug "Setting fan speed to $FAN_SPEED% (0x$FAN_SPEED_HEX)"

    # Enable manual fan control
    if ! execute_ipmi_command "Enabling manual fan control" ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x01 0x00; then
        return
    fi

    # Set fan speed
    if execute_ipmi_command "Setting fan speed to $FAN_SPEED%" ipmitool -I lanplus -H "$IP" -U "$USER" -P "$PASS" raw 0x30 0x30 0x02 0xff 0x"$FAN_SPEED_HEX"; then
       log_success "Successfully set fan speed to $FAN_SPEED% on $IP."
    else
       log_error "Failed to set fan speed."
    fi
}

# --- Main Menu ---
# --- Main Menu ---
main_menu() {
  while true; do
    echo -e "\n--- ${GREEN}iDRAC Fan Control${NC} ---"
    echo "1. Select Server"
    echo "2. Manage Servers"
    echo "3. Exit"
    read -p "Choose an option: " choice
    
    case $choice in
      1) select_server ;;
      2) manage_servers ;;
      3) exit 0 ;;
      *) log_error "Invalid option. Please try again." ;;
    esac
  done
}
# --- startup checks ---
check_dependencies() {
    local dependencies=("ipmitool" "jq")
    local missing=false

    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Dependency missing: $cmd is not installed."
            missing=true
        fi
    done

    if [ "$missing" = true ]; then
        log_error "Please install missing dependencies and try again."
        exit 1
    fi
}

validate_config() {
    if [ -f "$CONFIG_FILE" ]; then
        if ! jq empty "$CONFIG_FILE" > /dev/null 2>&1; then
            log_error "Config file '$CONFIG_FILE' contains invalid JSON."
            read -p "Backup and reset config file? (y/n): " choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                mv "$CONFIG_FILE" "${CONFIG_FILE}.bak"
                log_warning "Backed up to ${CONFIG_FILE}.bak"
                echo "[]" > "$CONFIG_FILE"
                log_success "Created new empty config file."
            else
                log_error "Cannot proceed with invalid config."
                exit 1
            fi
        fi
    fi
}

# --- Script Entry Point ---
# Check dependencies first
check_dependencies

# Initialize config file if it doesn't exist
initialize_config_file

# Validate config format
validate_config

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
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
