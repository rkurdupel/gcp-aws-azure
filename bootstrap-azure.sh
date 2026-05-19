#!/usr/bin/env bash
set -euo pipefail

# ARM - Azure Resource Manager, controls resources in azure and authorization (rbac roles)
# equivalent to account id  in aws, a place where resources are created and billed to, can have multiple subscriptions in one azure account
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID before running.sh}"
ENV_FILE="${ENV_FILE:-.env}"

echo "Setting active subscription..."
az account set --subscription "${SUBSCRIPTION_ID}"

echo "Registering reequired resource providers..."
az provider register --namespace "Microsoft.Storage"

# loop every 10 sec until each provider is registered
echo "Waiting for providers to register..."
while [ "$(az provider show --namespace "Microsoft.Storage" --query "registrationState" -o tsv)" != "Registered" ]; do
    echo "Microsoft.Storage registering, waiting 10s..."
    sleep 10
done
echo "Microsoft.Storage registered"


RESOURCE_GROUP="${RESOURCE_GROUP:-coinops-dev-rg}"
LOCATION="${LOCATION:-polandcentral}"
STATE_RESOURCE_GROUP="${STATE_RESOURCE_GROUP:-coinops-state-rg}"
SP_NAME="${SP_NAME:-coinops-dev-sp}"

# azure bucket
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-coinopsdevtfstate}"
# a folder inside storage account where tfstate files are stored (coinopsdevtfstate/tfstate)
CONTAINER_NAME="${CONTAINER_NAME:-tfstate}"


KEY_FILE="${KEY_FILE:-$HOME/.secrets/azure/sp-key.json}"

echo "Checking if Resource Group exists..."
if ! az group show --name "${RESOURCE_GROUP}"  &>/dev/null; then
    echo "Creating Resource Group: ${RESOURCE_GROUP}"
    az group create \
        --name "${RESOURCE_GROUP}" \
        --location "${LOCATION}"
    echo "Resource Group created"
else
    echo "Resource Group already exists, skipping"
fi


echo "Checking if State Resource Group exists..."
if ! az group show --name "${STATE_RESOURCE_GROUP}" &>/dev/null; then
    echo "Creating State Resource Group: ${STATE_RESOURCE_GROUP}"
    az group create \
        --name "${STATE_RESOURCE_GROUP}" \
        --location "${LOCATION}"
    echo "State Resource Group created"
else
    echo "State Resource Group already exists, skipping"
fi




# create-for-rbac - create with a role assignment instead of assigning a role with a separate block
# rbac - role based access control
# query "[0].id" - get the id of first sp found from json output, returns empty string if not found
# -o tsv - tab separated values, converts json to plain text
# grep -q . - check if output is not empty, returns 0 if found, 1 if not found
echo "Checking if Service Principal exists..."
if ! az ad sp list --display-name "${SP_NAME}" --query "[0].id" -o tsv | grep -q .; then
    echo "Creating Service Principal: ${SP_NAME}"
    # scope - scope of role assignment (assign role for subscription, or for storage account or for resource group)
    # years - number of years the credentials will be valid, default is 1 year
    SP_CREDENTIALS=$(az ad sp create-for-rbac \
        --name "${SP_NAME}" \
        --role Contributor \
        --scopes "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}" \
        --years 2)
    echo "Service Principal created"
else
    echo "Service Principal already exists, skipping"
fi



echo "Writing key file ..."
# check if key file exists
if [ ! -f "${KEY_FILE}" ]; then
    # create ~/.secrets/azure directory if it doesn't exist
    mkdir -p "$(dirname "${KEY_FILE}")"

    # check if SP_CREDENTIALS is set, if not, reset credentials to get new secret
    # -z - check if variable is empty, -n - check if variable is not empty
    # SP_CREDENTIALS is empty (:- default empty var) - SP already existed, reset credentials to get new secret
    # SP_CREDENTIALS does only have value if SP is not created and is being created
    if [ -z "${SP_CREDENTIALS:-}" ]; then
        echo "SP already existed, resetting credentials to get new secret..."
        SP_APP_ID=$(az ad sp list --display-name "${SP_NAME}" --query "[0].appId" -o tsv)   # get appId of existing SP
        TENANT_ID=$(az account show --query "tenantId" -o tsv)  # get tenant id (organization id of whole azure account that contains subscriptions, applications)
        NEW_SECRET=$(az ad app credential reset --id "${SP_APP_ID}" --years 99 --query "password" -o tsv)   # reset credentials and get new secret
        # build credentials
        SP_CREDENTIALS=$(jq -n \
            --arg clientId "${SP_APP_ID}" \
            --arg clientSecret "${NEW_SECRET}" \
            --arg tenantId "${TENANT_ID}" \
            '{"clientId": $clientId, "clientSecret": $clientSecret, "tenantId": $tenantId}')
    fi

    # jq - process json
    #  .clientId - jq reads clientId from SP_CREDENTIALS (created in create-for-rbac)
    echo "${SP_CREDENTIALS}" | jq \
    --arg sub "${SUBSCRIPTION_ID}" '{
        clientId: .clientId,
        clientSecret: .clientSecret,
        tenantId: .tenantId,
        subscriptionId: $sub
    }' > "${KEY_FILE}"
    echo "Key file saved to ${KEY_FILE}"
else 
    echo "Key file already exists, skipping"
fi


echo "Checking if Storage Account exists..."
if ! az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${STATE_RESOURCE_GROUP}" &>/dev/null; then
    echo "Creating Storage Account: ${STORAGE_ACCOUNT}"
    # --sku - stock keeping unit, LRS - locally redundant storage, 3 copies of data in same region, same data center
    # it defines how many copies of you data Azure keeps and where
    az storage account create \
        --name "${STORAGE_ACCOUNT}" \
        --resource-group "${STATE_RESOURCE_GROUP}" \
        --location "${LOCATION}" \
        --sku Standard_LRS
    echo "Storage Account created"
else
    echo "Storage Account already exists, skipping"
fi

# credentials for sp use instead of owner profile
SP_APP_ID=$(cat "${KEY_FILE}" | jq -r '.clientId')
TENANT_ID=$(cat "${KEY_FILE}" | jq -r '.tenantId')
ARM_SECRET=$(cat "${KEY_FILE}" | jq -r '.clientSecret')

# Contributor covers storageAccounts/read and blob read/write
echo "Assigning Storage Blob Data Contributor role to SP on state storage account..."
az role assignment create \
    --assignee "${SP_APP_ID}" \
    --role "Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${STATE_RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}"

echo "Role assigned"


echo "Checking if Blob Container exists..."
if ! az storage container show \
    --name "${CONTAINER_NAME}" \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login &>/dev/null; then
    echo "Creating Container: ${CONTAINER_NAME}"
    # --acount-name - storage account name (bucket)
    # --auth-mode login  - use az login credentials for authentication
    az storage container create \
        --name "${CONTAINER_NAME}" \
        --account-name "${STORAGE_ACCOUNT}" \
        --auth-mode login
    echo "Container created"
else
    echo "Container already exists, skipping"
fi


# write to env
if grep -q "ARM_CLIENT_ID" "${ENV_FILE}" 2>/dev/null; then
     # sed - edit file in place -i - replace line that starts with export AZURE_AUTH_LOCATION= with new value, | is used as delimiter instead of / to avoid escaping
    sed -i '' "s|export ARM_CLIENT_ID=.*|export ARM_CLIENT_ID=${SP_APP_ID}|" "${ENV_FILE}"
else
    echo "export ARM_CLIENT_ID=${SP_APP_ID}" >> "${ENV_FILE}"
fi

if grep -q "ARM_CLIENT_SECRET" "${ENV_FILE}" 2>/dev/null; then
    sed -i '' "s|export ARM_CLIENT_SECRET=.*|export ARM_CLIENT_SECRET=${ARM_SECRET}|" "${ENV_FILE}"
else
    echo "export ARM_CLIENT_SECRET=${ARM_SECRET}" >> "${ENV_FILE}"
fi

if grep -q "ARM_TENANT_ID" "${ENV_FILE}" 2>/dev/null; then
    sed -i '' "s|export ARM_TENANT_ID=.*|export ARM_TENANT_ID=${TENANT_ID}|" "${ENV_FILE}"
else
    echo "export ARM_TENANT_ID=${TENANT_ID}" >> "${ENV_FILE}"
fi

if grep -q "ARM_SUBSCRIPTION_ID" "${ENV_FILE}" 2>/dev/null; then
    sed -i '' "s|export ARM_SUBSCRIPTION_ID=.*|export ARM_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}|" "${ENV_FILE}"
else
    echo "export ARM_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}" >> "${ENV_FILE}"
fi

echo "Done"

