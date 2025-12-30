
#!/bin/bash
# ====================================================================================
# Lab Automation: Implement Private Google Access (PGA) and Cloud NAT
# Region/Zone fixed to lab: us-central1 / us-central1-f
# ====================================================================================

set -euo pipefail

# ---------------- Colors ----------------
BLACK=$(tput setaf 0); RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6); WHITE=$(tput setaf 7)
BG_BLACK=$(tput setab 0); BG_RED=$(tput setab 1); BG_GREEN=$(tput setab 2); BG_YELLOW=$(tput setab 3)
BG_BLUE=$(tput setab 4); BG_MAGENTA=$(tput setab 5); BG_CYAN=$(tput setab 6); BG_WHITE=$(tput setab 7)
BOLD=$(tput bold); RESET=$(tput sgr0)

echo "${BG_MAGENTA}${BOLD}Starting: Private Google Access + Cloud NAT Lab${RESET}"

# ---------------- Project & Location ----------------
export DEVSHELL_PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
export ZONE="us-central1-f"             # Lab-provided zone
export REGION="${ZONE%-*}"              # -> us-central1

gcloud config set project "$DEVSHELL_PROJECT_ID" >/dev/null

echo "${CYAN}Project: ${BOLD}$DEVSHELL_PROJECT_ID${RESET}"
echo "${CYAN}Zone:    ${BOLD}$ZONE${RESET}  → Region: ${BOLD}$REGION${RESET}"

# ---------------- Enable APIs ----------------
echo "${CYAN}${BOLD}Enabling required APIs (Compute & IAP)...${RESET}"
gcloud services enable compute.googleapis.com iap.googleapis.com

# ====================================================================================
# Task 1: Create VPC network, firewall, and VM (no external IP). Test IAP SSH.
# ====================================================================================
echo "${CYAN}${BOLD}Creating VPC 'privatenet' (custom) and subnet 'privatenet-us' in ${REGION}...${RESET}"
gcloud compute networks create privatenet --subnet-mode=custom
gcloud compute networks subnets create privatenet-us \
  --network=privatenet --region="$REGION" --range=10.130.0.0/20

echo "${CYAN}${BOLD}Creating firewall rule 'privatenet-allow-ssh' (tcp:22 from 35.235.240.0/20) for ALL instances...${RESET}"
gcloud compute firewall-rules create privatenet-allow-ssh \
  --network=privatenet \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20

echo "${CYAN}${BOLD}Creating VM 'vm-internal' (Debian 12) in ${ZONE} WITHOUT external IP...${RESET}"
gcloud compute instances create vm-internal \
  --zone="$ZONE" \
  --machine-type=e2-standard-2 \
  --network-interface="network=privatenet,subnet=privatenet-us,no-address,network-tier=PREMIUM,stack-type=IPV4_ONLY" \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=10GB \
  --boot-disk-type=pd-balanced \
  --description="Internal-only VM for PGA + NAT lab"

echo "${GREEN}${BOLD}VM created → External IP should be 'None'.${RESET}"

echo "${CYAN}${BOLD}Testing IAP SSH to vm-internal (non-interactive command run)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command 'echo "Connected via IAP to $(hostname)."; ip -o addr show dev eth0 | awk '"'"'{print $2, $4}'"'"''

echo "${YELLOW}${BOLD}Testing internet ping (expected to FAIL before NAT)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command 'timeout 8 ping -c 2 www.google.com || echo "Ping failed as expected (no external IP/NAT)."'

# ====================================================================================
# Task 2: Create Cloud Storage bucket, copy test object, enable PGA, verify access.
# ====================================================================================
# Globally unique bucket (override by exporting MY_BUCKET before running if you prefer).
export MY_BUCKET="${MY_BUCKET:-${DEVSHELL_PROJECT_ID}-pga-$(date +%s)}"
echo "${CYAN}${BOLD}Creating Cloud Storage bucket: ${MY_BUCKET}${RESET}"
gcloud storage buckets create "gs://${MY_BUCKET}" --location=US --public-access-prevention=enforced

echo "${CYAN}${BOLD}Copying test object to bucket...${RESET}"
gcloud storage cp gs://cloud-training/gcpnet/private/access.svg "gs://${MY_BUCKET}/"

echo "${YELLOW}${BOLD}Trying Cloud Storage access from vm-internal (expected to FAIL before PGA)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command "timeout 8 curl -I -sSf https://storage.googleapis.com/${MY_BUCKET}/access.svg || echo 'Cloud Storage access failed (PGA disabled). OK.'"

echo "${CYAN}${BOLD}Enabling Private Google Access on subnet 'privatenet-us'...${RESET}"
gcloud compute networks subnets update privatenet-us \
  --region="$REGION" \
  --enable-private-ip-google-access

echo "${GREEN}${BOLD}Testing Cloud Storage access again (should SUCCEED with PGA)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command "curl -I -sSf https://storage.googleapis.com/${MY_BUCKET}/access.svg && echo 'PGA working: object reachable.'"

# ====================================================================================
# Task 3: Configure Cloud NAT (with logging) and verify apt update succeeds.
# ====================================================================================
echo "${CYAN}${BOLD}Creating Cloud Router 'nat-router' and NAT 'nat-config' in ${REGION}...${RESET}"
gcloud compute routers create nat-router \
  --network=privatenet \
  --region="$REGION"

gcloud compute routers nats create nat-config \
  --router=nat-router \
  --region="$REGION" \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips \
  --enable-logging \
  --logging-filter=ALL

echo "${CYAN}${BOLD}Waiting ~60s for NAT propagation...${RESET}"
sleep 60

echo "${GREEN}${BOLD}Testing outbound internet (apt-get update) from vm-internal via NAT...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command 'sudo apt-get update -y && echo "apt-get update completed via Cloud NAT."'

# ====================================================================================
# Task 4: Cloud NAT Logging (hint)
# ====================================================================================
echo "${CYAN}${BOLD}Cloud NAT logging is enabled (translations & errors). View logs in Logs Explorer.${RESET}"
echo "Navigation: Menu → Logging → Logs Explorer (filter by resource.type='nat_gateway' or use 'View in Logs Explorer' from NAT UI)."

# ---------------- Summary ----------------
echo
echo "${BG_GREEN}${BOLD}Summary${RESET}"
echo "• VPC: privatenet (custom) | Subnet: privatenet-us (${REGION}, 10.130.0.0/20)"
echo "• Firewall: privatenet-allow-ssh (tcp:22 from 35.235.240.0/20)"
echo "• VM: vm-internal (${ZONE}), NO external IP"
echo "• Bucket: gs://${MY_BUCKET} (object: access.svg)"
echo "• PGA: Enabled on privatenet-us → Google APIs reachable without external IP"
echo "• NAT: nat-config on nat-router (${REGION}) → outbound internet for updates"
echo
echo "${YELLOW}Useful checks:${RESET}"
echo "  gcloud compute ssh vm-internal --zone=${ZONE} --tunnel-through-iap"
echo "  curl -I https://storage.googleapis.com/${MY_BUCKET}/access.svg     # should succeed (PGA)"
echo "  sudo apt-get update                                               # should succeed (via NAT)"
echo
echo "${BG_RED}${BOLD}Lab Automated Successfully!${RESET}"
