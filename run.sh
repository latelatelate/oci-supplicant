#!/bin/bash

source .env

# Logging configuration
LOGFILE="/var/log/oci-launcher.log"
PIDFILE="/var/run/oci-launcher.pid"

START=$(date +%s)
COUNT=0

cleanup() { 
    rm -f "$PIDFILE";
    log "Total Requests: $COUNT | Total Runtime: $(get_runtime "$START")"
}

handle_sigint() {
    log "Received SIGINT (Ctrl+C). Terminating"
    exit 130
}

handle_sigterm() {
    log "Received SIGTERM (kill). Terminating"
    exit 143
}

trap handle_sigint INT
trap handle_sigterm TERM
trap cleanup EXIT

format_runtime() {
    local total_seconds=$1
    local days=$(( total_seconds / 86400 ))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))

    local result=""
    (( days > 0 )) && result+="${days}d "
    (( hours > 0 )) && result+="${hours}h "
    (( minutes > 0 )) && result+="${minutes}m "
    (( seconds > 0 || result=="" )) && result+="${seconds}s"

    echo "$result"
}

get_runtime() {
    format_runtime $(( $(date +%s) - $1 ))
}

log() {
    echo "$(date +'%b %d %H:%M:%S') run.sh[$pid]: $1" | tee -a "$LOGFILE"

    if (( $COUNT > 1000 )); then
        sed -i -e :a -e '$q;N;1001,$D;ba' "$LOGFILE"
    fi
}

pid=$$

# Prevent duplicate execution
if [[ -f "$PIDFILE" ]]; then
    read existing_pid < "$PIDFILE"

    if kill -0 "$existing_pid" 2>/dev/null; then
        # script is running — log it using our own PID prefix
        log "Another instance is already running with PID $existing_pid"
        exit 1
    else
        # stale PID file
        log "Stale PID file detected for PID $existing_pid. Removing"
        rm -f "$PIDFILE"
    fi
fi

# Write new PID to file
echo $pid > "$PIDFILE"
log "Script initialized with PID $pid"

# TENACY_ID validation
if [[ -z "${TENANCY_ID}" ]]; then
    log "TENANCY_ID is missing. Please configure .env file"
    exit 1
fi

# Authentication verification
oci iam compartment list
if [ $? -ne 0 ]; then
    log "Unable to fetch compartment list. Please configure .env file"
    exit 1
fi

# Send requests too quickly results in 429 TooManyRequests or worse
interval=60
try=0
profile="DEFAULT"
config="config/ampere.default.json"
query=()

# Runtime args parsing
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config=*)
        config="${1#*=}"
        ;;
    -i|--interval=*)
        interval="${1#*=}"
        ;;
    -n|--name=*)
        query+=( --display-name "${1#*=}" )
        ;;
    -p|--profile=*)
        profile="${1#*=}"
        ;;
    -t|--try=*)
        try="${1#*=}"
        ;;
    *)
        log "[RuntimeError] Invalid argument supplied"
        exit 1
  esac
  shift
done

query+=( --profile "$profile" )
query+=( --from-json "file://${config}")

shape=$(jq -r '.shape' "$config")
cpus=$(jq -r '.shapeConfig.ocpus' "$config")
ram=$(jq -r '.shapeConfig.memoryInGBs' "$config")
image=$(jq -r '.sourceDetails.imageId' "$config")
bvs=$(jq -r '.sourceDetails.bootVolumeSizeInGBs' "$config")

# Check if the variable starts with '[' → treat as JSON array
if [[ $AVAILABILITY_DOMAIN == \[* ]]; then
    # Parse JSON array to bash
    mapfile -t availability_domains < <(jq -r '.[]' <<< "$AVAILABILITY_DOMAIN")
else
    availability_domains=("$AVAILABILITY_DOMAIN")
fi

domain_index=0
num_domains=${#availability_domains[@]}

# do API queries indefintely at $interval until success or $try count is met
while true; do

    current_domain="${availability_domains[$domain_index]}"
    log "[REQUEST] Create ${shape} on ${current_domain}"

    response=$(oci compute instance launch --no-retry  \
                --auth api_key \
                --compartment-id "$TENANCY_ID" \
                --subnet-id "$SUBNET_ID" \
                --availability-domain "$current_domain" \
                "${query[@]}" \
                --ssh-authorized-keys-file "$PATH_TO_PUBLIC_SSH_KEY" \
                --raw-output 2>&1)

    exit_code=$?
    (( $COUNT++ ))

    # if no output, query 200 success
    if (( exit_code == 0 )); then
        log "[RESPONSE] [200] SUCCESS Created ${shape} instance w/ ${cpus} ocpu ${ram}gb ram on ${current_domain}"
        break
    else
        if [[ ${response} =~ ServiceError ]]; then
            message=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .message)
            status=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .status)
            code=$(grep -Pzo "(?s){.*}" <<<${response} | jq -r .code)
            log "[RESPONSE] [${status}] ${code} ${message}"
        else
            # TODO: Handling other errors, etc
            log "[RESPONSE] Unexpected Error - ${response}"
        fi
    fi

    if (( try > 0 )); then
        (( try-- ))
        if (( try <= 0 )); then
            break
        fi
    fi

    # Rotate to next domain if multiple
    (( domain_index++ ))
    if (( domain_index >= num_domains )); then
        domain_index=0
    fi

    sleep $interval
done

log "Script finished. Terminating"