
#!/bin/bash
# ====================================================================================
# Lab Automation: Implement Private Google Access (PGA) and Cloud NAT
# Scenario (per lab spec):
#   - VPC: privatenet (custom) with subnet privatenet-us in us-central1 (10.130.0.0/20)
#   - Firewall: SSH from IAP range 35.235.240.0/20 to ALL instances in privatenet
#   - VM: vm-internal (Debian 12) in us-central1-f WITHOUT external IP
#   - Bucket: auto-generated (or set MY_BUCKET) for PGA test object
#   - Enable Private Google Access on subnet; then configure Cloud Router + Cloud NAT in us-central1
#   - Verify connectivity via IAP and NAT
# ====================================================================================

set -euo pipefail

# ---------------- Colors ----------------
BOLD=$(tput bold); RESET=$(tput sgr0)
CYAN=$(tput setaf 6); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
BG_MAGENTA=$(tput setab 5); BG_GREEN=$(tput setab 2); BG_RED=$(tput setab 1)

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
# Helpers
# ====================================================================================

# Run a command through IAP SSH on vm-internal with retries
run_on_vm() {
  local cmd="$1"
  local attempts="${2:-3}"
  local delay="${3:-20}"

  for i in $(seq 1 "$attempts"); do
    echo "${CYAN}${BOLD}IAP SSH attempt $i/${attempts}:${RESET} ${cmd}"
    if gcloud compute ssh vm-internal \
      --project="$DEVSHELL_PROJECT_ID" \
      --zone="$ZONE" \
      --tunnel-through-iap \
      --quiet \
      --ssh-flag=-oStrictHostKeyChecking=no \
      --command "$cmd"; then
      return 0
    fi
    echo "${YELLOW}IAP SSH attempt $i failed. Retrying in ${delay}s...${RESET}"
    sleep "$delay"
  done

  echo "${RED}${BOLD}IAP SSH failed after ${attempts} attempts.${RESET}"
  echo "Run troubleshoot:"
  echo "  gcloud compute ssh vm-internal --project=$DEVSHELL_PROJECT_ID --zone=$ZONE --troubleshoot --tunnel-through-iap"
  return 1
}

# ====================================================================================
# Task 1: Create VPC network, firewall, and VM (no external IP). Test IAP SSH.
# ====================================================================================
echo "${CYAN}${BOLD}Creating VPC 'privatenet' (custom) and subnet 'privatenet-us' in ${REGION}...${RESET}"
if ! gcloud compute networks describe privatenet >/dev/null 2>&1; then
  gcloud compute networks create privatenet --subnet-mode=custom
fi

if ! gcloud compute networks subnets describe privatenet-us --region="$REGION" >/dev/null 2>&1; then
  gcloud compute networks subnets create privatenet-us \
    --network=privatenet --region="$REGION" --range=10.130.0.0/20
fi

echo "${CYAN}${BOLD}Creating firewall rule 'privatenet-allow-ssh' (tcp:22 from 35.235.240.0/20)...${RESET}"
if ! gcloud compute firewall-rules describe privatenet-allow-ssh >/dev/null 2>&1; then
  gcloud compute firewall-rules create privatenet-allow-ssh \
    --network=privatenet \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20
fi

echo "${CYAN}${BOLD}Creating VM 'vm-internal' (Debian 12) in ${ZONE} WITHOUT external IP...${RESET}"
if ! gcloud compute instances describe vm-internal --zone="$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create vm-internal \
    --zone="$ZONE" \
    --machine-type=e2-standard-2 \
    --network-interface="network=privatenet,subnet=privatenet-us,no-address,network-tier=PREMIUM,stack-type=IPV4_ONLY" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-balanced \
    --description="Internal-only VM for PGA + NAT lab"
fi

echo "${GREEN}${BOLD}VM created → External IP should be 'None'.${RESET}"

echo "${CYAN}${BOLD}Smoke-test IAP SSH connectivity to vm-internal...${RESET}"
run_on_vm 'echo "Connected via IAP to $(hostname)."; ip -o addr show dev eth0 | awk "{print \$2, \$4}"' || true

echo "${YELLOW}${BOLD}Testing internet ping (expected to FAIL before NAT)...${RESET}"
run_on_vm 'timeout 8 ping -c 2 www.google.com || echo "Ping failed as expected (no external IP/NAT)."' || true

# ====================================================================================
# Task 2: Create Cloud Storage bucket, copy test object, enable PGA, verify access.
# ====================================================================================
export MY_BUCKET="${MY_BUCKET:-${DEVSHELL_PROJECT_ID}-pga-$(date +%s)}"
echo "${CYAN}${BOLD}Creating Cloud Storage bucket: ${MY_BUCKET}${RESET}"
if ! gcloud storage buckets describe "gs://${MY_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${MY_BUCKET}" --location=US --public-access-prevention=enforced
fi

echo "${CYAN}${BOLD}Copying test object to bucket...${RESET}"
gcloud storage cp gs://cloud-training/gcpnet/private/access.svg "gs://${MY_BUCKET}/access.svg"

echo "${YELLOW}${BOLD}Trying Cloud Storage access from vm-internal (expected to FAIL before PGA)...${RESET}"
run_on_vm "timeout 8 curl -I -sSf https://storage.googleapis.com/${MY_BUCKET}/access.svg || echo 'Cloud Storage access failed (PGA disabled). OK.'" || true

echo "${CYAN}${BOLD}Enabling Private Google Access on subnet 'privatenet-us'...${RESET}"
gcloud compute networks subnets update privatenet-us \
  --region="$REGION" \
  --enable-private-ip-google-access

echo "${GREEN}${BOLD}Testing Cloud Storage access again (should SUCCEED with PGA)...${RESET}"
run_on_vm "curl -I -sSf https://storage.googleapis.com/${MY_BUCKET}/access.svg && echo 'PGA working: object reachable.'" || true

# ====================================================================================
# Task 3: Configure Cloud NAT (with logging) and verify apt update succeeds.
# ====================================================================================
echo "${CYAN}${BOLD}Creating Cloud Router 'nat-router' and NAT 'nat-config' in ${REGION}...${RESET}"
if ! gcloud compute routers describe nat-router --region="$REGION" >/dev/null 2>&1; then
  gcloud compute routers create nat-router \
    --network=privatenet \
    --region="$REGION"
fi

if ! gcloud compute routers nats describe nat-config --router=nat-router --region="$REGION" >/dev/null 2>&1; then
  gcloud compute routers nats create nat-config \
    --router=nat-router \
    --region="$REGION" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips \
    --enable-logging \
    --logging-filter=ALL
fi

echo "${CYAN}${BOLD}Waiting ~90s for NAT propagation...${RESET}"
sleep 90

echo "${GREEN}${BOLD}Testing outbound internet (apt-get update) from vm-internal via NAT...${RESET}"
run_on_vm 'sudo apt-get update -y && echo "apt-get update completed via Cloud NAT."' || true

# ====================================================================================
# Task 4: Cloud NAT Logging (hint)
# ====================================================================================
echo "${CYAN}${BOLD}Cloud NAT logging is enabled (translations & errors). View logs in Logs Explorer.${RESET}"
echo "Navigation: Menu → Logging → Logs Explorer (filter on resource.type='nat_gateway' or use 'View in Logs Explorer' from NAT UI)."

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
echo "${YELLOW}Useful manual checks (if any step above warned/fell back):${RESET}"
echo "  gcloud compute ssh vm-internal --project=$DEVSHELL_PROJECT_ID --zone=$ZONE --tunnel-through-iap"
echo "  curl -I https://storage.googleapis.com/${MY_BUCKET}/access.svg     # should succeed (PGA)"
echo "  sudo apt-get update                                               # should succeed (via NAT)"
echo
echo "${BG_RED}${BOLD}Lab Automated (with retries & diagnostics).${RESET}"
