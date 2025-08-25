#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration --- #
# Attempt to read project ID from terraform.tfvars
if [ -f "terraform/terraform.tfvars" ]; then
    # Extract the value, remove quotes and comments
    GCP_PROJECT_ID_FROM_TFVARS=$(grep -E '^[[:space:]]*gcp_project_id[[:space:]]*=' terraform/terraform.tfvars | awk -F'=' '{print $2}' | awk '{$1=$1};1' | tr -d '"' | awk -F'#' '{print $1}' | awk '{$1=$1};1')
    GCP_REGION_FROM_TFVARS=$(grep -E '^[[:space:]]*gcp_region[[:space:]]*=' terraform/terraform.tfvars | awk -F'=' '{print $2}' | awk '{$1=$1};1' | tr -d '"' | awk -F'#' '{print $1}' | awk '{$1=$1};1')
fi

# Use value from TFVARS, or environment variable, or prompt user
if [ -n "$GCP_PROJECT_ID_FROM_TFVARS" ]; then
    export GCP_PROJECT_ID="$GCP_PROJECT_ID_FROM_TFVARS"
elif [ -n "$TF_VAR_gcp_project_id" ]; then
    export GCP_PROJECT_ID="$TF_VAR_gcp_project_id"
else
    echo "Error: gcp_project_id not found in terraform/terraform.tfvars or TF_VAR_gcp_project_id env var."
    read -p "Please enter the GCP Project ID: " GCP_PROJECT_ID_INPUT
    if [ -z "$GCP_PROJECT_ID_INPUT" ]; then
        echo "Project ID cannot be empty. Aborting."
        exit 1
    fi
    export GCP_PROJECT_ID="$GCP_PROJECT_ID_INPUT"
fi

export GCP_REGION="${GCP_REGION_FROM_TFVARS:-us-west2}"

# TODO: add tfvar auto-read support
export AR_REPO_NAME="${TF_VAR_artifact_repo_name:-n8n-repo}"
export SERVICE_NAME="${TF_VAR_cloud_run_service_name:-n8n}"

export IMAGE_TAG_LATEST="docker.n8n.io/n8nio/n8n:latest"
export IMAGE_TAG="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO_NAME}/${SERVICE_NAME}:latest"

# --- Check Prerequisites --- #
command -v gcloud >/dev/null 2>&1 || { echo >&2 "gcloud is required but it's not installed. Aborting."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo >&2 "docker is required but it's not installed. Aborting."; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo >&2 "terraform is required but it's not installed. Aborting."; exit 1; }

if [ ! -f "terraform/terraform.tfvars" ]; then
    echo >&2 "terraform/terraform.tfvars file not found."
    echo >&2 "Please create it based on terraform/terraform.tfvars.example and add your secrets."
    exit 1
fi

echo "--- Configuration --- "
echo "Project ID:   ${GCP_PROJECT_ID}"
echo "Region:       ${GCP_REGION}"
echo "Image Tag:    ${IMAGE_TAG}"
echo "Repo Name:    ${AR_REPO_NAME}"
echo "---------------------"

# --- Step 1: Configure Docker --- #
echo "\n---> Configuring Docker authentication..."
gcloud auth configure-docker ${GCP_REGION}-docker.pkg.dev --quiet

# --- Step 2: Pull latest Image --- #
echo "\n---> Pulling latest Docker image: ${IMAGE_TAG_LATEST}..."
docker pull "${IMAGE_TAG_LATEST}"

# --- Step 3: Build Docker Image --- #
echo "\n---> Building Docker image: ${IMAGE_TAG}..."
docker build --platform linux/amd64 -t "${IMAGE_TAG}" .

# --- Step 4: Push Docker Image --- #
echo "\n---> Pushing Docker image to Artifact Registry..."
docker push "${IMAGE_TAG}"

# --- Step 5: Redeploy Cloud Run service --- #
echo "\n---> Redeploying Cloud Run service..."
gcloud run services update n8n \
    --image=$IMAGE_TAG \
    --region=$GCP_REGION