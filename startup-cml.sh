#!/bin/bash
# ============================================================
# startup-cml.sh (With Lab Activation)
# Powers on the CML Azure VM, verifies the static IP, and 
# provides options to boot your simulation labs automatically.
# ============================================================
RESOURCE_GROUP="cml-rg"
VM_NAME="cml-controller"
STATIC_IP="20.115.126.150"  # Permanent Static IP

echo "============================================"
echo "        CML Graceful Startup Script         "
echo "============================================"

# --------------------------------------------------------
# STEP 1: Boot the Azure VM
# --------------------------------------------------------
echo "[1/5] Starting CML Azure VM (initiating compute charges)..."
az vm start --resource-group $RESOURCE_GROUP --name $VM_NAME

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to start Azure VM. Check your Azure CLI login status."
    exit 1
fi
echo "  Azure VM successfully instructed to start."

# --------------------------------------------------------
# STEP 2: Wait for Network Connectivity (Ping)
# --------------------------------------------------------
echo "[2/5] Waiting for static IP ($STATIC_IP) to respond to ping..."
MAX_ATTEMPTS=30
ATTEMPT=1

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    if ping -c 1 -W 2 $STATIC_IP >/dev/null 2>&1; then
        echo "  Network interface is up! Static IP responded successfully."
        break
    fi
    echo "  Attempt $ATTEMPT/$MAX_ATTEMPTS: Destination host unreachable. Waiting 5s..."
    sleep 5
    ATTEMPT=$((ATTEMPT + 1))
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo "ERROR: VM booted but static IP did not respond within time limit."
    exit 1
fi

# --------------------------------------------------------
# STEP 3: Wait for CML Web Services to Initialize
# --------------------------------------------------------
echo "[3/5] Waiting for CML UI / API to initialize..."
API_ATTEMPTS=20
API_COUNT=1
READY=0

while [ $API_COUNT -le $API_ATTEMPTS ]; do
    HTTP_STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" "https://$STATIC_IP/api/v0/authenticate")
    
    if [ "$HTTP_STATUS" -ne 000 ]; then
        echo "  CML REST API is responsive (HTTP Status: $HTTP_STATUS)."
        READY=1
        break
    fi
    echo "  Attempt $API_COUNT/$API_ATTEMPTS: Web service loading. Waiting 10s..."
    sleep 10
    API_COUNT=$((API_COUNT + 1))
done

if [ $READY -ne 1 ]; then
    echo "WARNING: Web UI did not load in time. Skipping lab automation."
    exit 1
fi

# --------------------------------------------------------
# STEP 4: Authenticate and Manage Labs via API
# --------------------------------------------------------
echo ""
echo "[4/5] Preparing lab orchestration automation..."
read -p "Enter CML UI Admin Username [admin]: " CML_USER
CML_USER=${CML_USER:-admin}

read -s -p "Enter CML UI Admin Password: " CML_PASS
echo ""

TOKEN=$(curl -s -k -X POST "https://$STATIC_IP/api/v0/authenticate" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"$CML_USER\", \"password\": \"$CML_PASS\"}" | tr -d '"')

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "  WARNING: API Authentication failed. Cannot automate lab startup."
else
    echo "  Authenticated successfully."
    echo ""
    read -p "Enter the exact name of the lab to start (or press Enter to list all labs): " TARGET_LAB
    
    # Fetch all labs from the API in JSON format
    LABS_JSON=$(curl -s -k -X GET "https://$STATIC_IP/api/v0/labs" -H "Authorization: Bearer $TOKEN")
    
    # If user left it blank, list out available labs and titles
    if [ -z "$TARGET_LAB" ]; then
        echo "------------------------------------------------"
        echo " Available Labs on Controller:                  "
        echo "------------------------------------------------"
        # Parse out Lab ID and Lab Title strings cleanly from the raw API payload
        echo "$LABS_JSON" | grep -o '"id":[^,]*,"title":[^,]*' | tr -d '"' | sed 's/id://g' | sed 's/title:/ -> /g'
        echo "------------------------------------------------"
        read -p "Enter the exact title of the lab you want to start: " TARGET_LAB
    fi

    # Find the matching Lab ID by processing the JSON matching the Title
    LAB_ID=$(echo "$LABS_JSON" | grep -o '{"id":"[^"]*","title":"'"$TARGET_LAB"'"' | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)

    if [ -z "$LAB_ID" ]; then
        echo "  ERROR: Could not find a lab matching the name: '$TARGET_LAB'"
    else
        echo "  Found Lab ID: $LAB_ID for '$TARGET_LAB'."
        echo "  Checking lab status..."
        STATE=$(curl -s -k -X GET "https://$STATIC_IP/api/v0/labs/$LAB_ID/state" -H "Authorization: Bearer $TOKEN" | tr -d '"')
        
        if [ "$STATE" == "STARTED" ]; then
            echo "  Lab '$TARGET_LAB' is already running!"
        else
            echo "  Booting lab '$TARGET_LAB' now..."
            curl -s -k -X PUT "https://$STATIC_IP/api/v0/labs/$LAB_ID/start" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json"
            echo "  Lab startup command sent successfully."
        fi
    fi
fi

# --------------------------------------------------------
# STEP 5: Execution Complete
# --------------------------------------------------------
echo ""
echo "============================================"
echo " CML Controller is Ready!"
echo "============================================"
echo " Static IP: https://$STATIC_IP"
echo " Compute Status: RUNNING (~\$0.38/hr)"
echo "============================================"
echo ""
