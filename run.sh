#!/bin/bash

source .env

# Logging configuration
LOGFILE="/var/log/oci-launcher.log"
PIDFILE="/var/run/oci-launcher.pid"

log() {
    echo "$(date +'%b %d %H:%M:%S') oci_create[$(cat "$PIDFILE")]: $1" | tee -a "$LOGFILE"
}

# Prevent duplicate execution
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

# Send requests too quickly results in 429 TooManyRequests or worse
interval=60


profile="DEFAULT"
config="config/ampere.default.json"
try=0
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
        printf "* Error: Invalid argument.*\n"
        exit 1
  esac
  shift
done

query+=( --profile "$profile" )
query+=( --from-json "file://${config}")

# do API queries at requestInterval until success event
while true; do

    log "[REQUEST] Create ${shape} instance w/ ${cpus}OCPU ${ram}GB ram on ${AVAILABILITY_DOMAIN}"

    response=$(oci compute instance launch --no-retry  \
                --auth api_key \
                --compartment-id "$TENANCY_ID" \
                --image-id "$IMAGE_ID" \
                --subnet-id "$SUBNET_ID" \
                --availability-domain "$AVAILABILITY_DOMAIN" \
                "${query[@]}" \
                --ssh-authorized-keys-file "$PATH_TO_PUBLIC_SSH_KEY" \
                --raw-output 2>&1)

    exit_code=$?

    # if no output, query 200 success
    if [[ exit_code == 0 ]]; then
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

    if (( try > 0 )); then
        ((try--))
        if (( try <= 0 )); then
            break
        fi
    fi

    sleep $requestInterval
done