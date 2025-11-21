#!/bin/bash

source .env

if [[ -z "${TENANCY_ID}" ]]; then
    echo "TENANCY_ID is unset or empty. Please change in .env file"
    exit 1
else
    echo "TENANCY_ID is set correctly"
fi

# To verify that the authentication with Oracle cloud works
echo "Checking Connection with this request: "
oci iam compartment list
if [ $? -ne 0 ]; then
    echo "Connection to Oracle cloud is not working. Check your setup and config again!"
    exit 1
fi

# Logging configuration
LOGFILE="/var/log/oci-arm-launch.log"
PIDFILE="/var/run/oci-arm-launch.pid"

log() {
    echo "$(date +'%b %d %H:%M:%S') | $1" | tee -a "$LOGFILE"
}

# Prevent double runs
if [[ -f "$PIDFILE" ]]; then
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Script already running with PID $(cat "$PIDFILE")"
        exit 1
    fi
fi
echo $$ > "$PIDFILE"

cleanup() { rm -f "$PIDFILE"; }
trap cleanup EXIT

# ----------------------CUSTOMIZE---------------------------------------------------------------------------------------

# Don't go too low or you run into 429 TooManyRequests
requestInterval=60 # seconds

# VM params
cpus=1 # max 4 cores
ram=2 # max 24gb memory
bootVolume=50 # disk size in gb
displayName="WG Relay Instance" # friendly name for instance

profile="DEFAULT"

# ----------------------ENDLESS LOOP TO REQUEST AN ARM INSTANCE---------------------------------------------------------

while true; do

    response=$(oci compute instance launch --no-retry  \
                --auth api_key \
                --profile "$profile" \
                --display-name "$displayName" \
                --compartment-id "$TENANCY_ID" \
                --image-id "$IMAGE_ID" \
                --subnet-id "$SUBNET_ID" \
                --availability-domain "$AVAILABILITY_DOMAIN" \
                --shape 'VM.Standard.A1.Flex' \
                --shape-config "{'ocpus':$cpus,'memoryInGBs':$ram}" \
                --boot-volume-size-in-gbs "$bootVolume" \
                --ssh-authorized-keys-file "$PATH_TO_PUBLIC_SSH_KEY" \
                --raw-output 2>&1)

    if [[ $? == 0 ]]; then
        # All went well!
        echo "File uploaded, etag: ${response}"
        break
    else
        # Handle error
        if [[ ${response} =~ ServiceError ]]; then
            # we have a Service Error, only keep the JSON part of the response and
            # use JQ to parse it:
            message=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .message)
            status=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .status)
            echo "Service Error: ${message}"
        else
            # Other error...
            echo "Unexpected error message: ${response}"
        fi
    fi

    sleep $requestInterval
done