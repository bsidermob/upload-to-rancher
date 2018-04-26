#!/bin/bash
#
# Mike Chistyakov
#
# This script is used to upload Docker images to registry and upgrade Rancher service
#
################################################################################

# Fail whole script on first error
set -e

################################################################################
# Constant Variables
################################################################################

SCRIPT=$(basename "$0")

NUMARGS=$#

NOW=$(date +"%m_%d_%Y")

CONTAINER_BASE_NAME="_specify_aws_ecr_url_here.dkr.ecr.ap-southeast-2.amazonaws.com/"

CONTAINER_TAG=":latest"

RANCHER_URL="_specify_rancher_url_here/v2-beta"

# This was previously used for AWS ECS
# TASK_ID=$(aws ecs list-tasks --cluster $CLUSTER_NAME --service $SERVICE_NAME --output text --query taskArns[0])

################################################################################
# Methods
################################################################################

# Log helper
log () {
  echo -e "${SCRIPT}_${NOW}: $@"
}

# Print help message to STDOUT
help_message() {
  log  \\n"Help documentation for ${SCRIPT}"\\n
  echo "The following switches are recognized."
  echo "-r  -- required, AWS ECS registry repository name"
  echo "-s  -- optional, Rancher service name. If missing, service upgrade isn't performed"
  echo -e "-h  -- Displays this help message."\\n
  echo -e "Example: ${SCRIPT} -r test-service-qa"\
          "-s Test-Service-QA"\\n
  echo -e "RANCHER_SECRET_KEY and RANCHER_SECRET_KEY environment variables are required to acccess Rancher using API. Make sure to fill them in."\\n
  exit 1
}

upload_docker_image() {
    # Login to AWS
    eval $(aws ecr get-login --no-include-email --region ap-southeast-2)

    # Build new docker image
    docker build -t ${CONTAINER_BASE_NAME}${REPO_NAME}${CONTAINER_TAG} -f docker/Dockerfile .

    # Delete the previous docker image
    aws ecr batch-delete-image --repository-name $REPO_NAME --image-ids imageTag=latest

    # Push the container
    docker push ${CONTAINER_BASE_NAME}${REPO_NAME}${CONTAINER_TAG}
}

fetch_task_url() {

    curl --fail --silent --show-error -K- <<< "-u  ${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" -X GET -H 'Accept: application/json' -H 'Content-Type: application/json' ${RANCHER_URL}/projects/1a5/services?name=${RANCHER_SERVICE_NAME} | jq --raw-output '.data[]|.links|.self'
}

upgrade_service() {

    # Obtain current service config
    inServiceStrategy=`curl --fail --silent --show-error  -X GET -H 'Accept: application/json' -H 'Content-Type: application/json' ${TASK_URL} -K- <<< "-u  ${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}"`

    curl --fail --silent --show-error -X POST -H 'Accept: application/json' -H 'Content-Type: application/json' -d "{\"inServiceStrategy\": ${inServiceStrategy}}}" ${TASK_URL}/?action=upgrade -K- <<< "-u  ${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" >/dev/null

}

finish_upgrade() {
    local environment=$1
  	local service=$2

    echo "waiting for service to upgrade "
  	while true; do
      local serviceState=`curl --fail --silent --show-error -K- <<< "-u  ${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" \
          -X GET \
          -H 'Accept: application/json' \
          -H 'Content-Type: application/json' \
          ${TASK_URL} | jq '.state'`

      case $serviceState in
          "\"upgraded\"" )
              echo "completing service upgrade"
              curl --fail --silent --show-error  -K- <<< "-u  ${RANCHER_ACCESS_KEY}:${RANCHER_SECRET_KEY}" \
                -X POST \
                -H 'Accept: application/json' \
                -H 'Content-Type: application/json' \
                -d '{}' \
                ${TASK_URL}/?action=finishupgrade &>/dev/null
              break ;;
          "\"upgrading\"" )
              echo -n "."
              sleep 3
              continue ;;
          "\"active\"" )
              echo "service is already active"
              break ;;
          *)
	            echo "unexpected upgrade state: $serviceState" ;;
      esac
  	done
}


################################################################################
# Command line arguments
################################################################################

# Check the number of arguments. If none are passed, print help and exit.
if [[ "${NUMARGS}" -eq 0 ]]; then
  help_message
fi


# Parse command line flags
while getopts r:s:h:u flag; do
  case $flag in
    # Set ECS registry name
    r) REPO_NAME="${OPTARG}" ;;
    # Set Rancher Service Name
    s) RANCHER_SERVICE_NAME="${OPTARG}" ;;
    # Set Upload to ECS flag
    u) UPLOAD_TO_REGISTRY="${OPTARG}" ;;
    # show help message
    h) help_message ;;
    # Unrecognized option - show help message
    \?)
      log -e \\n"Option -${OPTARG} not allowed." \\n\\n
      help_message
      ;;
  esac
done

shift $((OPTIND-1))

if [[ -z "${REPO_NAME}" ]]
then
  log "ECS Registry repo name required!"
  help_message
fi

if [[ -z "${RANCHER_ACCESS_KEY}" ]] && [[ -n "${RANCHER_SERVICE_NAME}" ]]
then
  log "RANCHER_ACCESS_KEY environment variable is empty. Fill it in!"
  exit
fi

if [[ -z "${RANCHER_SECRET_KEY}" ]] && [[ -n "${RANCHER_SERVICE_NAME}" ]]
then
  log "RANCHER_SECRET_KEY environment variable is empty. Fill it in!"
  exit
fi

################################################################################
# Start of scripts
################################################################################

# Build new Docker image and upload it to Registry
upload_docker_image

if [[ -z "${RANCHER_SERVICE_NAME}" ]]
then
  log "Rancher service name not specified. Not upgrading Rancher service."
  exit
fi

# Fetch task URL and save it into variable for use by latter functions
TASK_URL=$(fetch_task_url)

# Upgrade Rancher service
upgrade_service

# Finish upgrade in Rancher. Wait until it's done.
finish_upgrade
