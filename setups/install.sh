#!/bin/bash
set -e -o pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)

source ${REPO_ROOT}/setups/utils.sh

echo -e "${GREEN}Installing with the following options: ${NC}"
echo -e "${GREEN}----------------------------------------------------${NC}"
yq '... comments=""' ${REPO_ROOT}/setups/config.yaml
echo -e "${GREEN}----------------------------------------------------${NC}"
echo -e "${PURPLE}\nTargets:${NC}"
echo "Kubernetes cluster: $(kubectl config current-context)"
echo "AWS profile (if set): ${AWS_PROFILE}"
echo "AWS account number: $(aws sts get-caller-identity --query "Account" --output text)"

echo -e "${GREEN}\nAre you sure you want to continue?${NC}"
read -p '(yes/no): ' response
if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
  echo 'exiting.'
  exit 0
fi

# Substitute Github Organization/User name in files.
export GITHUB_URL=$(yq '.repo_url' ./setups/config.yaml)
export HOSTED_ZONE_ID=$(yq '.hosted_zone_id' ./setups/config.yaml)
export GITHUB_ORG=$(echo "${GITHUB_URL}" | sed 's/\/[^/]*$//')
export BASE_DOMAIN_NAME=$(aws route53 get-hosted-zone \
                      --id "${HOSTED_ZONE_ID}" --query 'HostedZone.Name' \
                      --output text | sed 's/\.$//')

# Update Backstage config with Github URL
sed -i "s|GITHUB_URL|${GITHUB_URL}|g" "${REPO_ROOT}/packages/backstage/dev/cm-backstage-config.yaml"

find "${REPO_ROOT}/packages/backstage-templates" -type f -name "*.yaml" | while read file; do
    sed -i \
        -e "s|GITHUB_URL|${GITHUB_URL}|g" \
        -e "s|GITHUB_ORG|${GITHUB_ORG}|g" \
        -e "s|BASE_DOMAIN_NAME|${BASE_DOMAIN_NAME}|g" \
        "$file"
done

# Push modified files to Github
cd "${REPO_ROOT}"
git add . && git commit -m "Updated config files for reference implementation" && git push origin main
cd -

# Set up ArgoCD. We will use ArgoCD to install all components.
cd "${REPO_ROOT}/setups/argocd/"
./install.sh
cd -

# The rest of the steps are defined as a Terraform module. Parse the config to JSON and use it as the Terraform variable file. This is done because JSON doesn't allow you to easily place comments.
cd "${REPO_ROOT}/terraform/"
yq -o json '.'  ../setups/config.yaml > terraform.tfvars.json
terraform init -upgrade
terraform apply -auto-approve
