#!/usr/bin/env bash

# documentation AWS  [] - optional, no brackets - required

set -euo pipefail

IAM_USER="${IAM_USER:-coinops-dev-terraform}"
BUCKET_NAME="${BUCKET_NAME:-coinops-dev-tf-state}"
REGION="${REGION:-eu-central-1}"
LOCK_TABLE="${LOCK_TABLE:-coinops-dev-tf-locks}"
ENV_FILE="${ENV_FILE:-.aws-bootstrap.env}"


echo "Checking IAM user..."
if ! aws iam get-user --user-name "${IAM_USER}"  2>/dev/null; then
    echo "Creating IAM user: ${IAM_USER}"
    aws iam create-user --user-name "${IAM_USER}"

    echo "IAM user created"
else
    echo "IAM user already exists, skipping"
fi

# allow IAM user access to bucket, everything EC2 related (instances, network, subnetwork)
aws iam put-user-policy \
    --user-name "${IAM_USER}" \
    --policy-name "TerraformStateAccess" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                    "s3:PutObject",
                    "s3:DeleteObject",
                    "s3:ListBucket",
                    "s3:GetBucketVersioning"
                ],
                "Resource": [
                    "arn:aws:s3:::'"${BUCKET_NAME}"'",
                    "arn:aws:s3:::'"${BUCKET_NAME}"'/*"
                ]
            },
            {
                "Effect": "Allow",
                "Action": [
                    "dynamodb:GetItem",
                    "dynamodb:PutItem",
                    "dynamodb:DeleteItem",
                    "dynamodb:DescribeTable"
                ],
                "Resource": "arn:aws:dynamodb:'"${REGION}"':*:table/'"${LOCK_TABLE}"'"
            },
            {
                "Effect": "Allow",
                "Action": ["ec2:*"],
                "Resource": "*"
            }
        ]
}'

# aws allows only two (2) access keys per user
echo "Checking existing access keys..."
KEYS=$(aws iam list-access-keys --user-name "${IAM_USER}")
KEY_COUNT=$(echo "${KEYS}" | jq '.AccessKeyMetadata | length')

if [ "${KEY_COUNT}" -ge 2 ]; then
    echo "User has ${KEY_COUNT} keys (max 2). Deleting oldest key..."
    
    OLDEST_KEY=$(echo "${KEYS}" | jq -r '
        .AccessKeyMetadata 
        | sort_by(.CreateDate) 
        | first 
        | .AccessKeyId
    ')
    
    aws iam delete-access-key \
        --user-name "${IAM_USER}" \
        --access-key-id "${OLDEST_KEY}"
    
    echo "Deleted old key: ${OLDEST_KEY}"
fi

echo "Creating new access key..."
CREDENTIALS=$(aws iam create-access-key --user-name "${IAM_USER}")


echo "Writing AWS env file..."
cat > "${ENV_FILE}" << EOF
export AWS_ACCESS_KEY_ID=$(echo "${CREDENTIALS}" | jq -r '.AccessKey.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "${CREDENTIALS}" | jq -r '.AccessKey.SecretAccessKey')
export AWS_DEFAULT_REGION="${REGION}"
EOF

echo "Checking Terraform state bucket..."
# head-bucket check if exists
if ! aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    echo "Creating bucket: ${BUCKET_NAME}"

    aws s3api create-bucket \
        --bucket "${BUCKET_NAME}" \
        --region "${REGION}" \
        --create-bucket-configuration  "LocationConstraint=${REGION}"
        # specifies where the bucket will be created
        # if region is not specified the region will be retrieved from the profile one (us-1)
    echo "Bucket created"
else
    echo "Bucket already exists, skipping"
fi

echo "Enabling bucket versioning..."
aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled 

# Every new object uploaded to this bucket should be automatically encrypted using S3-managed AES256 encryption
echo "Enabling bucket encryption..."
aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm": "AES256"}}]}'



# Creates a DynamoDB table that Terraform uses as a lock to prevent simultaneous state changes.
# Dev A: terraform apply - acquires lock
# Dev B: terraform apply - identifies lock, waits
echo "Checking DynamoDB lock table..."
if ! aws dynamodb describe-table \
    --table-name "${LOCK_TABLE}" \
    --region "${REGION}" >/dev/null 2>&1; then
    echo "Creating DynamoDB lock table"
    aws dynamodb create-table \
        --table-name "${LOCK_TABLE}" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "${REGION}"
    aws dynamodb wait table-exists \
        --table-name "${LOCK_TABLE}" \
        --region "${REGION}"
    echo "DynamoDB lock table created"
else
    echo "DynamoDB lock table already exists, skipping"
fi

