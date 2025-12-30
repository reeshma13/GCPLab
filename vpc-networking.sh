
#!/bin/bash
# ====================================================================================
# Lab: Implement Private Google Access and Cloud NAT
# - Creates a custom VPC (privatenet) & subnet (privatenet-us)
# - Adds IAP SSH firewall rule (source: 35.235.240.0/20)
# - Creates a VM with NO external IP (vm-internal) and connects via IAP
# - Creates a Cloud Storage bucket and copies a test object
# - Enables Private Google Access on the subnet, verifies access from vm-internal
# - Configures Cloud Router + Cloud NAT (with logging) and verifies outbound internet
# - Zones are configurable; regions are auto-derived from zones
# ====================================================================================

set -euo pipefail

# ===================== Colors =====================
BLACK=$(tput setaf 0); RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6); WHITE=$(tput setaf 7)
BG_BLACK=$(tput setab 0); BG_RED=$(tput setab 1); BG_GREEN=$(tput setab 2); BG_YELLOW=$(tput setab 3)
BG_BLUE=$(tput setab 4); BG_MAGENTA=$(tput setab 5); BG_CYAN=$(tput setab 6); BG_WHITE=$(tput setab 7)
BOLD=$(tput bold); RESET=$(tput sgr0)

echo "${BG_MAGENTA}${BOLD}Starting: Private Google Access + Cloud NAT Lab Automation${RESET}"

# ===================== Project & Location =====================
export DEVSHELL_PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
export ZONE="${ZONE:-us-central1-c}"          # <-- change if your lab uses a different zone
export REGION="${ZONE%-*}"                    # auto-derive region from zone (e.g., us-central1-c -> us-central1)

gcloud config set project "$DEVSHELL_PROJECT_ID" >/dev/null

echo "${CYAN}Project: ${BOLD}$DEVSHELL_PROJECT_ID${RESET}"
echo "${CYAN}Zone:    ${BOLD}$ZONE${RESET}  → Region: ${BOLD}$REGION${RESET}"

# ===================== Enable Required APIs =====================
echo "${CYAN}${BOLD}Enabling required APIs...${RESET}"
gcloud services enable compute.googleapis.com iap.googleapis.com

# ===================== Task 1: Create VPC + Firewall + VM (no external IP) =====================
echo "${CYAN}${BOLD}Creating custom VPC 'privatenet' and subnet 'privatenet-us'...${RESET}"
gcloud compute networks create privatenet --subnet-mode=custom
gcloud compute networks subnets create privatenet-us \
  --network=privatenet --region="$REGION" --range=10.130.0.0/20

echo "${CYAN}${BOLD}Creating IAP SSH firewall rule (tcp:22 from 35.235.240.0/20)...${RESET}"
gcloud compute firewall-rules create privatenet-allow-ssh \
  --network=privatenet --direction=INGRESS --priority=1000 --action=ALLOW \
  --rules=tcp:22 --source-ranges=35.235.240.0/20

echo "${CYAN}${BOLD}Creating VM 'vm-internal' WITHOUT external IP in $ZONE...${RESET}"
gcloud compute instances create vm-internal \
  --zone="$ZONE" \
  --machine-type=e2-standard-2 \
  --network-interface="network=privatenet,subnet=privatenet-us,no-address,network-tier=PREMIUM,stack-type=IPV4_ONLY" \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=10GB \
  --boot-disk-type=pd-balanced \
  --description="Internal-only VM for PGA + NAT lab"

echo "${GREEN}${BOLD}VM created. External IP should be 'None'.${RESET}"

# Quick IAP connectivity smoke-test (non-interactive, creates SSH keys if needed)
echo "${CYAN}${BOLD}Testing IAP SSH connectivity to vm-internal...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command 'echo "Connected via IAP to $(hostname)."; ip -o addr show dev eth0 | awk '"'"'{print $2, $4}'"'"''

# Attempt to ping public internet (expected to FAIL — no NAT, no external IP)
echo "${YELLOW}${BOLD}Testing internet connectivity (expected to FAIL before NAT)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command 'timeout 8 ping -c 2 www.google.com || echo "Ping failed as expected (no external IP/NAT)."'

# ===================== Task 2: Create Bucket + Enable Private Google Access =====================
# Create a globally unique bucket name using project ID and timestamp
export MY_BUCKET="${MY_BUCKET:-${DEVSHELL_PROJECT_ID}-pga-$(date +%s)}"
echo "${CYAN}${BOLD}Creating test Cloud Storage bucket: ${MY_BUCKET}${RESET}"
# Location: multi-region (US); enforce public access prevention as per lab
gcloud storage buckets create "gs://${MY_BUCKET}" --location=US --public-access-prevention=enforced

echo "${CYAN}${BOLD}Copying test object into the bucket...${RESET}"
gcloud storage cp gs://cloud-training/gcpnet/private/access.svg "gs://${MY_BUCKET}/"

echo "${GREEN}${BOLD}Bucket ready and object copied: gs://${MY_BUCKET}/access.svg${RESET}"

# Try to access the object from vm-internal (expected to FAIL before enabling PGA)
echo "${YELLOW}${BOLD}Testing access to Cloud Storage from vm-internal (expected to FAIL before PGA)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command "timeout 8 curl -I -sSf https://storage.googleapis.com/${MY_BUCKET}/access.svg || echo 'Cloud Storage access failed (PGA disabled). OK.'"

# Enable Private Google Access on the subnet
echo "${CYAN}${BOLD}Enabling Private Google Access on subnet 'privatenet-us'...${RESET}"
gcloud compute networks subnets update privatenet-us \
  --region="$REGION" \
  --enable-private-ip-google-access

# Verify accessing Cloud Storage now works from vm-internal
echo "${GREEN}${BOLD}Testing Cloud Storage access from vm-internal (should SUCCEED with PGA)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command "curl -I -sSf https://storage.googleapis.com/${MY_BUCKET}/access.svg && echo 'PGA working: object reachable.'"

# ===================== Task 3: Configure Cloud NAT (with logging) =====================
echo "${CYAN}${BOLD}Creating Cloud Router and NAT in region ${REGION}...${RESET}"
# Create Cloud Router attached to privatenet
gcloud compute routers create nat-router \
  --network=privatenet \
  --region="$REGION"

# Create Cloud NAT and map ALL subnet IP ranges; auto-allocate external IPs; enable logging (translations + errors)
gcloud compute routers nats create nat-config \
  --router=nat-router \
  --region="$REGION" \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips \
  --enable-logging \
  --logging-filter=ALL

echo "${CYAN}${BOLD}Waiting ~60s for NAT propagation...${RESET}"
sleep 60

# Verify apt-get update now succeeds via NAT
echo "${GREEN}${BOLD}Testing outbound internet from vm-internal (apt-get update should SUCCEED)...${RESET}"
gcloud compute ssh vm-internal \
  --zone="$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --ssh-flag=-oStrictHostKeyChecking=no \
  --command 'sudo apt-get update -y && echo "apt-get update completed via Cloud NAT."'

# ===================== Task 4: (Optional) Show Logs Explorer hint =====================
echo "${CYAN}${BOLD}Cloud NAT logging is enabled. View logs in: Navigation Menu → Logging → Logs Explorer.${RESET}"
echo "You can filter on resource.type='nat_gateway' or use the 'View in Logs Explorer' link from the NAT gateway UI."

# ===================== Summary & Helpful Commands =====================
echo
echo "${BG_GREEN}${BOLD}Summary${RESET}"
echo "• VPC: privatenet (custom) | Subnet: privatenet-us (${REGION}, 10.130.0.0/20)"
echo "• Firewall: privatenet-allow-ssh (tcp:22 from 35.235.240.0/20)"
echo "• VM: vm-internal (${ZONE}), NO external IP"
echo "• Bucket: gs://${MY_BUCKET} (object: access.svg)"
echo "• PGA: Enabled on privatenet-us → Google APIs reachable without external IP"
echo "• NAT: nat-config on nat-router (${REGION}) → outbound internet for updates"
echo
echo "${YELLOW}Useful manual checks:${RESET}"
echo "  gcloud compute ssh vm-internal --zone=${ZONE} --tunnel-through-iap"
echo "  curl -I https://storage.googleapis.com/${MY_BUCKET}/access.svg     # should succeed (PGA)"
echo "  sudo apt-get update                                               # should succeed (via NAT)"
echo
echo "${BG_RED}${BOLD}Lab Automated Successfully!${RESET}"
