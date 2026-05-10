#!/usr/bin/env bash

# make the script save -e - exit on error, -u - error on undefined variable (bash stops), -o - catch error inside pipes |
set -euo pipefail

# :- if value before is empty use the one after :-
# :? - variable is required ; if it is missing or empty stop with error
PROJECT_ID="${PROJECT_ID:-coinops-dev}"
PROJECT_NAME="${PROJECT_NAME:-CoinOps Dev}"
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:?Set BILLING_ACCOUNT_ID before running bootstrap.sh}"   # 01D2D8-8B8744-9886E7
SA_NAME="${SA_NAME:-coinops-backend-dev-sa}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BUCKET_NAME="${BUCKET_NAME:-${PROJECT_ID}-tf-state}"
LOCATION="${LOCATION:-EU}"
REGION="${REGION:-europe-central2}"
KEY_FILE="${KEY_FILE:-$HOME/.secrets/gcp/sa-key.json}"
ENV_FILE="${ENV_FILE:-.env}"

echo "Checking if GCP project exists..."
# gcloud projects describe "${PROJECT_ID}" - Tries to fetch info about your project. 
# Succeeds if it exists, fails if it doesn't.
#  &>/dev/null - Throws away all output. only mentions success or failure
if ! gcloud projects describe "${PROJECT_ID}" &>/dev/null; then
    echo "Creating project: ${PROJECT_ID}"
    # name is optional - if not provided gcp uses name as project_id
    gcloud projects create "${PROJECT_ID}" \
        --name="${PROJECT_NAME}"
    echo "Project created"

else
    echo "Project already exists, skipping"
fi

echo "Linking billing account..."
gcloud billing projects link "${PROJECT_ID}" \
    --billing-account="${BILLING_ACCOUNT_ID}"

echo "Setting active project..."
gcloud config set project "${PROJECT_ID}"

echo "Enabling required APIs..."
gcloud services enable \
    compute.googleapis.com \
    iam.googleapis.com \
    storage.googleapis.com \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com
    

echo "Creating Service Account..."
# check is sa exists by lookign it up via its email
# coinops-backend-dev-sa@coinops-dev.iam.gserviceaccount.com
if ! gcloud iam service-accounts describe "${SA_EMAIL}" &>/dev/null; then
    gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="CoinOps Backend Service Account"
    echo "Service Account Created"

else
    echo "Service Account already exists, skipping"
fi

echo "Granting SA Compute Network Admin role..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.networkAdmin" \
    --quiet # omit printing json info

echo "Creating SA key..."
# -f does such file exist?
# [] = test command [ - open test ] - close test
if [ ! -f "${KEY_FILE}" ]; then
    gcloud iam service-accounts keys create "${KEY_FILE}" \
        --iam-account="${SA_EMAIL}"
    echo "SA key saved to ${KEY_FILE}"
else
    echo "Key file already exists, skipping"
fi

echo "Writing env file..."
# > .env - write into env if file exists it gets overwritten
# << EOF - end of file (marker) (take everything you see above eof and put into file)
# $(pwd) - current folder path
cat > "${ENV_FILE}" << EOF
export GOOGLE_APPLICATION_CREDENTIALS="${KEY_FILE}"
export TF_VAR_project_id="${PROJECT_ID}"
export TF_VAR_region="${REGION}"
EOF
# when terraform uses google provider, it automatically looks for credentials in this order:
# 1) env, 2) gcloud, 3) metadata


echo "Creating terraform state bucket..."
# gs:// - storage URLs
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" &>/dev/null; then
    gcloud storage buckets create "gs://${BUCKET_NAME}" \
        --location="${LOCATION}" \
        --uniform-bucket-level-access \
        --public-access-prevention

         #  --uniform-bucket-level-access
         # disable object-level permissions (ACLs)
         # force IAM access control
    
    gcloud storage buckets update "gs://${BUCKET_NAME}" --versioning
    echo "Bucket created with versioning enabled"  
     # when terraform apply gcp keeps every previous version of state file (adding versions)
     # every time there is update in tf files and tf apply command - save new version
else 
    echo "Bucket already created, skipping"
fi

echo "Granting SA access to Terraform state bucket..."
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectAdmin" \
    --quiet # omit any prompts (Do you want to continue (Y/n)?)

# - members:
#  - serviceAccount:coinops-backend-dev-sa@coinops-dev.iam.gserviceaccount.com
#  role: roles/storage.objectAdmin

# to be able to create instance
echo "Granting SA Compute Instance Admin role..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.instanceAdmin.v1" \
    --quiet

# for firewall settings
echo "Granting SA Compute Security  Admin role..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
     --member="serviceAccount:${SA_EMAIL}" \
     --role="roles/compute.securityAdmin" \
     --quiet
