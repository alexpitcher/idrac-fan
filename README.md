# iDRAC-Fan
Dell iDRAC fan control automation. Works on versions up to 3.30.30.30. Run this on your local mechine, ideally macOS or linux. Use WSL on Windows ideally.

# Prerequisites
- You must have ipmitool installed

`sudo apt install ipmitool` or `brew install ipmitool`
- IPMI over LAN must be enabled (iDRAC -> iDRAC Settings -> Network)
- Your user must have permission to access IPMI, default `root` user has permission.
