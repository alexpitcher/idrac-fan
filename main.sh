#!/bin/bash
# Set the path to the .env file
ENV_FILE=".env"

# Function to check if .env file contains required lines
check_env_file() {
  if ! grep -q "ENCODED_USER=" "$ENV_FILE" || \
     ! grep -q "ENCODED_PASS=" "$ENV_FILE" || \
     ! grep -q "LAST_IP=" "$ENV_FILE"; then
    return 1  # Return 1 if any of the lines are missing
  fi
  return 0  # Return 0 if all required lines are present
}

# Check if the .env file exists
if [ -f "$ENV_FILE" ]; then
  # Validate if .env contains all required lines
  if ! check_env_file; then
    echo "The .env file is incomplete or missing necessary information."
    echo "Please enter your credentials and IP information again."
    # Clear the .env file and reset it
    > "$ENV_FILE"
  else
    # If the .env file exists and contains all required lines, load it
    source "$ENV_FILE"
    USER=$(echo -n "$ENCODED_USER" | base64 -d)
    PASS=$(echo -n "$ENCODED_PASS" | base64 -d)
  fi
else
  # If the .env file does not exist, prompt the user for credentials
  echo ".env file not found. Please provide your credentials."
  read -p "Enter the username: " USER
  read -s -p "Enter the password: " PASS
  echo ""

  # Encode the username and password using base64
  ENCODED_USER=$(echo -n "$USER" | base64)
  ENCODED_PASS=$(echo -n "$PASS" | base64)

  # Create the .env file and write the encoded username and password to it
  echo "ENCODED_USER=$ENCODED_USER" > "$ENV_FILE"
  echo "ENCODED_PASS=$ENCODED_PASS" >> "$ENV_FILE"
  echo "LAST_IP=" >> "$ENV_FILE"
fi

# Default IP address
IP=999.999.999.999

# Check if the IP address and fan speed were passed as arguments
if [ $# -eq 2 ]; then
  IP=$1
  FAN_SPEED=$2
else
  # If the .env was ignored, prompt for all details (IP, username, password)
  if ! check_env_file || [ ! -f "$ENV_FILE" ]; then
    echo "Since the .env file is invalid or missing, please enter the IP, username, and password again."
    # Prompt the user for the IP address
    read -p "Enter the IP address: " IP

    # Validate the IP address
    while ! [[ $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
      read -p "Invalid IP address. Please enter a valid IP address: " IP
    done

    # Prompt the user for the username and password again
    read -p "Enter the username: " USER
    read -s -p "Enter the password: " PASS
    echo ""

    # Encode the username and password using base64
    ENCODED_USER=$(echo -n "$USER" | base64)
    ENCODED_PASS=$(echo -n "$PASS" | base64)

    # Write the new credentials and IP address to .env
    echo "ENCODED_USER=$ENCODED_USER" > "$ENV_FILE"
    echo "ENCODED_PASS=$ENCODED_PASS" >> "$ENV_FILE"
    echo "LAST_IP=" >> "$ENV_FILE"
  else
    # If the .env file is valid, load the last used IP from it
    IP=$LAST_IP
  fi

  # Cache the last used IP
  echo "LAST_IP=$IP" > temp.env
  grep -v "^LAST_IP=" "$ENV_FILE" >> temp.env
  mv temp.env "$ENV_FILE"

  # Prompt the user for the desired fan speed in percentage (0-100)
  read -p "Enter the desired fan speed in percentage (0-100): " FAN_SPEED
fi

# Validate the input fan speed
while ! [[ $FAN_SPEED =~ ^[0-9]+$ ]] || [ $FAN_SPEED -lt 0 ] || [ $FAN_SPEED -gt 100 ]; do
  read -p "Invalid input. Please enter a valid fan speed in percentage (0-100): " FAN_SPEED
done

FAN_SPEED_HEX=$(printf '%x\n' $FAN_SPEED)

# Use the decoded credentials and user input IP in the ipmitool command
# Attempt to communicate with the IPMI interface
echo "Sending fan speed command to IP: $IP"

# Run the actual fan speed change command
output=$(ipmitool -v -I lanplus -H $IP -U $USER -P $PASS raw 0x30 0x30 0x02 0xff 0x$FAN_SPEED_HEX 2>&1)

# Print the output for debugging purposes
echo "$output"

# Check if the fan speed command was successful
if [[ "$output" =~ "Invalid completion code received" ]]; then
  echo "Error: Failed to set fan speed. Please check the output above for details."
  exit 1
fi

# Check if the command returned any other error indicating failure
if [[ "$output" =~ "Unable to establish IPMI v2 / RMCP+ session" || "$output" =~ "unauthorized name" ]]; then
  echo "Error: There was an issue with the IPMI connection or credentials."
  exit 1
fi

echo "Fan speed set successfully to $FAN_SPEED%."
