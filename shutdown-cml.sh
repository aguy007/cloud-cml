#!/bin/bash
# ============================================================
# shutdown-cml.sh (Optimized with Dynamic Prompting)
# Gracefully shuts down CML and deallocates the Azure VM
# Stops compute charges while preserving settings and license.
# ============================================================
RESOURCE_GROUP="cml-rg"
VM_NAME="cml-controller"
SSH_KEY="$HOME/.ssh/cml-key"
SSH_PORT="1122"
STATIC_IP="20.115.126.150"  # Permanent Static IP 

echo "============================================"
echo "        CML Graceful Shutdown Script        "
echo "============================================"

# Prompt for CML Credentials dynamically to keep the file secure
read -p "Enter CML UI Admin Username [admin]: " CML_USER
CML_USER=${CML_USER:-admin}  # Defaults to admin if you just press enter

read -s -p "Enter CML UI Admin Password: " CML_PASS
echo "" # Moves to a new line after hidden password entry

# --------------------------------------------------------
# STEP 1: Authenticate and Stop Labs via CML REST API
# --------------------------------------------------------
echo ""
echo "[1/4] Authenticating with CML REST API..."
TOKEN=$(curl -s -k -X POST "https://$STATIC_IP/api/v0/authenticate" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"$CML_USER\", \"password\": \"$CML_PASS\"}" | tr -d '"')

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "  WARNING: API Authentication failed. Cannot stop labs gracefully via API."
    echo "  Proceeding directly to emergency OS shutdown..."
else
    echo "  Authenticated successfully."
    echo "[2/4] Instructing CML to stop all running labs..."
    
    # Get all lab IDs
    LAB_IDS=$(curl -s -k -X GET "https://$STATIC_IP/api/v0/labs" -H "Authorization: Bearer $TOKEN" | grep -o '"[^"]*"' | tr -d '"')
    
    # Loop and stop each active lab
    for LAB in $LAB_IDS; do
        STATE=$(curl -s -k -X GET "https://$STATIC_IP/api/v0/labs/$LAB/state" -H "Authorization: Bearer $TOKEN" | tr -d '"')
        if [ "$STATE" == "STARTED" ]; then
            echo "  Stopping lab ID: $LAB..."
            curl -s -k -X PUT "https://$STATIC_IP/api/v0/labs/$LAB/stop" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json"
        fi
    done
    
    echo "  Waiting 20 seconds for lab hypervisors to spin down cleanly..."
    sleep 20
fi

# --------------------------------------------------------
# STEP 2: Gracefully Shut Down the Linux OS Host
# --------------------------------------------------------
echo "[3/4] Sending OS shutdown command via SSH..."
ssh -p$SSH_PORT -i $SSH_KEY \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=10 \
  sysadmin@$STATIC_IP \
  "sudo shutdown -h now" 2>/dev/null

echo "  Waiting 15 seconds for OS disk flushing and power-off..."
sleep 15

# --------------------------------------------------------
# STEP 3: Deallocate the VM in Azure
# --------------------------------------------------------
echo "[4/4] Deallocating Azure VM (stopping compute charges)..."
az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_NAME

if [ $? -eq 0 ]; then
    echo ""
    echo "============================================"
    echo " CML VM deallocated successfully"
    echo "============================================"
    echo " Compute charges: STOPPED"
    echo " Storage charges: ~\$0.10-0.15/day"
    echo " Static IP: $STATIC_IP (Preserved)"
    echo "============================================"
else
    echo "ERROR: Azure VM deallocation failed. Please check the Azure Portal."
    exit 1
fi

