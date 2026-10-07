#!/usr/bin/env bash
# Create (or re-apply settings to) the shared Terraform state bucket.
# Idempotent: safe to rerun. Each project stores state under its own prefix:
#   s3://<bucket>/<project>/terraform.tfstate
#
# Usage: scripts/bootstrap-state-bucket.sh [bucket] [region]
set -euo pipefail

REGION="${2:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${1:-tfstate-$ACCOUNT_ID-$REGION}"

log() { printf '==> %s\n' "$*" >&2; }

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "bucket $BUCKET exists; re-applying settings"
else
  log "creating bucket $BUCKET in $REGION"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  aws s3api wait bucket-exists --bucket "$BUCKET"
fi

log "blocking public access"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log "disabling ACLs (BucketOwnerEnforced)"
aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

log "enabling versioning"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

log "enabling default encryption (SSE-S3)"
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

log "denying non-TLS access"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}}
  }]
}
EOF
)"

log "setting lifecycle rules"
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [
    {"ID": "expire-noncurrent-versions", "Status": "Enabled", "Filter": {},
     "NoncurrentVersionExpiration": {"NoncurrentDays": 90}},
    {"ID": "remove-expired-delete-markers", "Status": "Enabled", "Filter": {},
     "Expiration": {"ExpiredObjectDeleteMarker": true}},
    {"ID": "abort-incomplete-uploads", "Status": "Enabled", "Filter": {},
     "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}}
  ]
}' >/dev/null

log "tagging"
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=Purpose,Value=terraform-state},{Key=ManagedBy,Value=bootstrap-state-bucket.sh}]'

log "done: s3://$BUCKET (use key \"<project>/terraform.tfstate\")"
