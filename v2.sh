#!/bin/bash

# Set the path to the .env file
ENV_FILE=".env"

VERBOSE=false
if [ "$1" == "--verbose" ]; then
  VERBOSE=true
  shift
fi

log_debug() {
  if [ "$VERBOSE" = true ]; then
    echo "[DEBUG] $1"
  fi
}

log_debug "Starting script execution..."

# Check if the .env file exists
if [ ! -f "$ENV_FILE" ]; then
  log_debug ".env file not found. Prompting user for credentials..."
  # If the file does not exist, prompt the user for the username and password
  read -p "Enter the username: " USER
  read -s -p "Enter the password: " PASS
  echo ""

  # Encode the username and password using base64
  ENCODED_USER=$(echo -n "$USER" | base64)
  ENCODED_PASS=$(echo -n "$PASS" | base64)

  log_debug "Credentials encoded and writing to .env file..."
  # Create the .env file and write the encoded username and password to it
  echo "ENCODED_USER=$ENCODED_USER" > "$ENV_FILE"
  echo "ENCODED_PASS=$ENCODED_PASS" >> "$ENV_FILE"
  echo "LAST_IP=" >> "$ENV_FILE"
else
  log_debug ".env file found. Reading credentials..."
  # If the file exists, read the values from it
  source "$ENV_FILE"
  # Decode the username and password
  USER=$(echo -n "$ENCODED_USER" | base64 -d)
  PASS=$(echo -n "$ENCODED_PASS" | base64 -d)
fi

# Function to interact with the LibreNMS API and fetch core temperatures
fetch_core_temperatures() {
  local device_id=$1
  local api_url=$LIBRENMS_API_URL
  local api_token=$LIBRENMS_API_TOKEN

  response=$(curl -s -H "X-Auth-Token: $api_token" "$api_url/devices/$device_id/health/temperature")
  echo "$response" | jq '.health | map(.current) | .[]'
}

# Check if the device ID was passed as an argument
if [ $# -eq 1 ]; then
  log_debug "Device ID provided as an argument."
  DEVICE_ID=$1
else
  log_debug "Device ID not provided. Prompting for device ID..."
  read -p "Enter the device ID of the Proxmox server: " DEVICE_ID
fi

log_debug "Fetching core temperatures from LibreNMS API..."
core_temperatures=$(fetch_core_temperatures "$DEVICE_ID")

log_debug "Core temperatures: $core_temperatures"

# Check if any core temperature exceeds 60 degrees Celsius
suggest_increase_fan_speed=false
for temp in $core_temperatures; do
  if (( $(echo "$temp > 60" | bc -l) )); then
    suggest_increase_fan_speed=true
    break
  fi
done

if [ "$suggest_increase_fan_speed" = true ]; then
  echo "Warning: Some cores have temperatures exceeding 60 degrees Celsius. Consider increasing the fan speed."
fi

IP=999.999.999.999

# Check if the IP address and fan speed were passed as arguments
if [ $# -eq 3 ]; then
  log_debug "IP and fan speed provided as arguments."
  IP=$2
  FAN_SPEED=$3
else
  log_debug "IP and fan speed not provided. Checking for cached IP..."
  # Check if the last used IP is set
  if [ -n "$LAST_IP" ]; then
    log_debug "Last used IP found: $LAST_IP"
    # Ask the user if they would like to interact with the same host again
    read -p "Would you like to interact with $LAST_IP again? (y/n): " RESPONSE
    if [ "$RESPONSE" = "y" ]; then
      IP=$LAST_IP
    else
      # Prompt the user for new credentials and IP address
      log_debug "Prompting for new IP and credentials..."
      read -p "Enter the IP address: " IP
      read -p "Enter the username: " USER
      read -s -p "Enter the password: " PASS
      echo ""

      # Encode the new username and password using base64
      ENCODED_USER=$(echo -n "$USER" | base64)
      ENCODED_PASS=$(echo -n "$PASS" | base64)

      log_debug "Updating .env file with new credentials and IP..."
      echo "ENCODED_USER=$ENCODED_USER" > "$ENV_FILE"
      echo "ENCODED_PASS=$ENCODED_PASS" >> "$ENV_FILE"
      echo "LAST_IP=$IP" >> "$ENV_FILE"
    fi
  else
    log_debug "No cached IP found. Prompting for new IP..."
    # Prompt the user for the IP address
    read -p "Enter the IP address: " IP
  fi

  # Validate the IP address
  while ! [[ $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
    log_debug "Invalid IP address entered: $IP"
    read -p "Invalid IP address. Please enter a valid IP address: " IP
  done

  log_debug "Caching last used IP: $IP"
  # Cache the last used IP
  echo "LAST_IP=$IP" > temp.env
  grep -v "^LAST_IP=" "$ENV_FILE" >> temp.env
  mv temp.env "$ENV_FILE"

  # Prompt the user for the desired fan speed in percentage (0-100)
  read -p "Enter the desired fan speed in percentage (0-100): " FAN_SPEED
fi

log_debug "Validating fan speed: $FAN_SPEED"
# Validate the input fan speed
while ! [[ $FAN_SPEED =~ ^[0-9]+$ ]] || [ $FAN_SPEED -lt 0 ] || [ $FAN_SPEED -gt 100 ]; do
  log_debug "Invalid fan speed entered: $FAN_SPEED"
  read -p "Invalid input. Please enter a valid fan speed in percentage (0-100): " FAN_SPEED
done

FAN_SPEED_HEX=$(printf '%x\n' $FAN_SPEED)
log_debug "Fan speed in hexadecimal: $FAN_SPEED_HEX"

# Use the decoded credentials and user input IP in the ipmitool command
log_debug "Sending IPMI command to initialize fan control with verbose output..."
ipmitool -v -I lanplus -U $USER -P $PASS -H $IP raw 0x30 0x30 0x01 0x00
if [ $? -eq 0 ]; then
  log_debug "Successfully initialized fan control."
else
  echo "[ERROR] Failed to initialize fan control."
fi
log_debug "Sending IPMI command to set fan speed with verbose output..."
output=$(ipmitool -v -I lanplus -H $IP -U $USER -P $PASS raw 0x30 0x30 0x02 0xff 0x$FAN_SPEED_HEX 2>&1)

if [ $? -eq 0 ]; then
  log_debug "Fan speed successfully set to $FAN_SPEED%."
else
  # Check for specific error messages
  if echo "$output" | grep -q "RAKP 2 message indicates an error : unauthorized name"; then
    echo "[ERROR] Authentication failed: Incorrect username."
  elif echo "$output" | grep -q "RAKP 2 HMAC is invalid"; then
    echo "[ERROR] Authentication failed: Incorrect password."
  elif echo "$output" | grep -q "Get Auth Capabilities error"; then
    echo "[ERROR] Unable to connect to IPMI: Incorrect IP address or unreachable host."
  else
    echo "[ERROR] Failed to set fan speed. Error details: $output"
  fi
fi

log_debug "Script execution completed."
