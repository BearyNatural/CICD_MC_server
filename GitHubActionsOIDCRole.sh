#!/bin/bash
set -euo pipefail

ROLE_NAME="GitHubActionsOIDCRole"
GITHUB_OWNER="BearyNatural"
OIDC_PROVIDER_URL="token.actions.githubusercontent.com"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_URL}"

echo "Using AWS account: ${ACCOUNT_ID}"

cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_OWNER}/*"
        }
      }
    }
  ]
}
EOF

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role exists. Updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document file://trust-policy.json
else
  echo "Creating role..."
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document file://trust-policy.json
fi

echo "Done."
echo "Role ARN:"
aws iam get-role \
  --role-name "${ROLE_NAME}" \
  --query "Role.Arn" \
  --output text