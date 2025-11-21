#!/bin/bash

source .env

# Logging configuration
LOGFILE="/var/log/oci-launcher.log"
PIDFILE="/var/run/oci-launcher.pid"

log() {
    echo "$(date +'%b %d %H:%M:%S') oci_create[$(cat "$PIDFILE")]: $1" | tee -a "$LOGFILE"
}

# Prevent double runs
if [[ -f "$PIDFILE" ]]; then
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        log "Script already running with PID $(cat "$PIDFILE")"
        exit 1
    fi
fi
echo $$ > "$PIDFILE"

cleanup() { rm -f "$PIDFILE"; }
trap cleanup EXIT

# TENACY_ID validation
if [[ -z "${TENANCY_ID}" ]]; then
    log "TENANCY_ID is unset or empty. Please change in .env file"
    exit 1
else
    log "TENANCY_ID is set correctly"
fi

# Authentication verification
echo "Checking Connection with this request: "
oci iam compartment list
if [ $? -ne 0 ]; then
    log "Connection to Oracle cloud is not working. Check your setup and config again!"
    exit 1
fi

# ----------------------CUSTOMIZE---------------------------------------------------------------------------------------

# Don't go too low or you run into 429 TooManyRequests
requestInterval=60 # seconds

# VM params
cpus=4 # max 4 cores
ram=24 # max 24gb memory
bootVolume=200 # disk size in gb
displayName="WG Relay Instance" # friendly name for instance
shape="VM.Standard.A1.Flex"

profile="DEFAULT"

# do API queries at requestInterval until success event
while true; do

    log "[REQUEST] Create ${shape} instance w/ ${cpus}OCPU ${ram}GB ram on ${AVAILABILITY_DOMAIN}"

    response=$(oci compute instance launch --no-retry  \
                --auth api_key \
                --profile "$profile" \
                --display-name "$displayName" \
                --compartment-id "$TENANCY_ID" \
                --image-id "$IMAGE_ID" \
                --subnet-id "$SUBNET_ID" \
                --availability-domain "$AVAILABILITY_DOMAIN" \
                --shape "$shape" \
                --shape-config "{'ocpus':$cpus,'memoryInGBs':$ram}" \
                --boot-volume-size-in-gbs "$bootVolume" \
                --ssh-authorized-keys-file "$PATH_TO_PUBLIC_SSH_KEY" \
                --raw-output 2>&1)

    # if no output, query 200 success
    if [[ $? == 0 ]]; then
        log "[RESPONSE] SUCCESS 200 Created ${shape} instance w/ ${cpus}OCPU ${ram}GB ram on ${AVAILABILITY_DOMAIN}"
        break
    else
        if [[ ${response} =~ ServiceError ]]; then
            message=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .message)
            status=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .status)
            code=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .code)
            log "[RESPONSE] ${code^^} ${status} ${message}"
        else
            # TODO: Handling other errors, etc
            log "[RESPONSE] Unexpected Error - ${response}"
        fi
    fi

    sleep $requestInterval
done