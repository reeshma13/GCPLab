
#!/bin/bash
# ====================================================================================
# Google Cloud VPC Networking Lab - Full Automation Script
# - Creates auto-mode VPC (mynetwork), firewall rules (incl. IAP), and 2 VMs
# - Converts to custom-mode
# - Creates managementnet & privatenet (custom), firewall rules, and 2 VMs
# - Calculates regions automatically from zones you specify
# ====================================================================================

set -euo pipefail

# ===================== Fancy Colors =====================
BLACK=$(tput setaf 0); RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6); WHITE=$(tput setaf 7)
BG_BLACK=$(tput setab 0); BG_RED=$(tput setab 1); BG_GREEN=$(tput setab 2); BG_YELLOW=$(tput setab 3)
BG_BLUE=$(tput setab 4); BG_MAGENTA=$(tput setab 5); BG_CYAN=$(tput setab 6); BG_WHITE=$(tput setab 7)
BOLD=$(tput bold); RESET=$(tput sgr0)

echo "${BG_MAGENTA}${BOLD}Starting Execution${RESET}"

# ===================== Project, Zones & Regions =====================
# If you already exported these in Cloud Shell, the script will use your values.
# Otherwise, sensible defaults are applied for the lab.
export DEVSHELL_PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
export ZONE_1="${ZONE_1:-us-central1-c}"      # lab step: mynet-us-vm (us-central1-c)
export ZONE_2="${ZONE_2:-europe-west1-b}"     # lab step: mynet-notus-vm (europe-west1-b)
export REGION_1="${ZONE_1%-*}"                # => us-central1
export REGION_2="${ZONE_2%-*}"                # => europe-west1

gcloud config set project "$DEVSHELL_PROJECT_ID" >/dev/null

echo "${CYAN}Project: ${BOLD}$DEVSHELL_PROJECT_ID${RESET}"
echo "${CYAN}ZONE_1:  ${BOLD}$ZONE_1${RESET}  → REGION_1: ${BOLD}$REGION_1${RESET}"
echo "${CYAN}ZONE_2:  ${BOLD}$ZONE_2${RESET}  → REGION_2: ${BOLD}$REGION_2${RESET}"

# ===================== Enable Required APIs =====================
echo "${CYAN}${BOLD}Enabling required APIs...${RESET}"
gcloud services enable iap.googleapis.com networkmanagement.googleapis.com

# ===================== Task 1 (Optional): Delete 'default' VPC =====================
# The lab deletes the default network via Console. We'll safely attempt the same here.
if gcloud compute networks describe default --format="value(name)" >/dev/null 2>&1; then
  echo "${YELLOW}${BOLD}Deleting default firewall rules...${RESET}"
  for rule in $(gcloud compute firewall-rules list --filter="network:default" --format="value(name)"); do
    gcloud compute firewall-rules delete "$rule" --quiet || true
  done
  echo "${YELLOW}${BOLD}Deleting default VPC network...${RESET}"
  gcloud compute networks delete default --quiet || true
else
  echo "${GREEN}Default VPC not present; skipping deletion.${RESET}"
fi

# ===================== Task 2: Create Auto-mode VPC 'mynetwork' =====================
echo "${CYAN}${BOLD}Creating auto-mode VPC: mynetwork ...${RESET}"
gcloud compute networks create mynetwork \
  --subnet-mode=auto \
  --mtu=1460 \
  --bgp-routing-mode=regional

echo "${CYAN}${BOLD}Creating firewall rules on mynetwork...${RESET}"

# Allow ICMP (ping) from anywhere
gcloud compute firewall-rules create mynetwork-allow-icmp \
  --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW \
  --rules=icmp --source-ranges=0.0.0.0/0

# Allow RDP from anywhere
gcloud compute firewall-rules create mynetwork-allow-rdp \
  --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW \
  --rules=tcp:3389 --source-ranges=0.0.0.0/0

# Allow SSH from anywhere
gcloud compute firewall-rules create mynetwork-allow-ssh \
  --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW \
  --rules=tcp:22 --source-ranges=0.0.0.0/0

# Allow all within auto-mode global RFC1918 (internal)
gcloud compute firewall-rules create mynetwork-allow-custom \
  --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW \
  --rules=all --source-ranges=10.128.0.0/9

# IAP SSH rule: allow tcp:22 from IAP IPs; tag required: iap-gce
gcloud compute firewall-rules create allow-iap-ssh \
  --network=mynetwork --direction=INGRESS --priority=1000 --action=ALLOW \
  --rules=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=iap-gce

sleep 5

# ---------- Create mynetwork VMs ----------
echo "${CYAN}${BOLD}Creating mynet-us-vm in ${ZONE_1} (E2 e2-medium, Debian 12)...${RESET}"
gcloud compute instances create mynet-us-vm \
  --zone="$ZONE_1" \
  --machine-type=e2-medium \
  --network-interface="network=mynetwork,network-tier=PREMIUM,stack-type=IPV4_ONLY" \
  --metadata="enable-oslogin=true" \
  --maintenance-policy=MIGRATE \
  --provisioning-model=STANDARD \
  --tags="iap-gce" \
  --scopes="https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append" \
  --create-disk="auto-delete=yes,boot=yes,device-name=mynet-us-vm,image-family=debian-12,image-project=debian-cloud,mode=rw,size=10GB,type=pd-balanced" \
  --no-shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --labels="goog-ec-src=vm_add-gcloud" --reservation-affinity=any

echo "${CYAN}${BOLD}Creating mynet-notus-vm in ${ZONE_2} (E2 e2-medium, Debian 12)...${RESET}"
gcloud compute instances create mynet-notus-vm \
  --zone="$ZONE_2" \
  --machine-type=e2-medium \
  --network-interface="network=mynetwork,network-tier=PREMIUM,stack-type=IPV4_ONLY" \
  --metadata="enable-oslogin=true" \
  --maintenance-policy=MIGRATE \
  --provisioning-model=STANDARD \
  --tags="iap-gce" \
  --scopes="https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append" \
  --create-disk="auto-delete=yes,boot=yes,device-name=mynet-notus-vm,image-family=debian-12,image-project=debian-cloud,mode=rw,size=10GB,type=pd-balanced" \
  --no-shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --labels="goog-ec-src=vm_add-gcloud" --reservation-affinity=any

# ---------- Convert to Custom Mode ----------
echo "${CYAN}${BOLD}Converting mynetwork to custom subnet mode...${RESET}"
gcloud compute networks update mynetwork --switch-to-custom-subnet-mode --quiet
sleep 5

# ===================== Task 3: Create Custom VPCs =====================
# ---------- managementnet ----------
echo "${CYAN}${BOLD}Creating managementnet (custom) & subnets...${RESET}"
gcloud compute networks create managementnet --subnet-mode=custom
gcloud compute networks subnets create managementsubnet-us \
  --network=managementnet --region="$REGION_1" --range=10.240.0.0/20

# ---------- privatenet ----------
echo "${CYAN}${BOLD}Creating privatenet (custom) & subnets...${RESET}"
gcloud compute networks create privatenet --subnet-mode=custom
gcloud compute networks subnets create privatesubnet-us \
  --network=privatenet --region="$REGION_1" --range=172.16.0.0/24
gcloud compute networks subnets create privatesubnet-notus \
  --network=privatenet --region="$REGION_2" --range=172.20.0.0/20

echo "${GREEN}${BOLD}Networks:${RESET}"
gcloud compute networks list

# ---------- Firewall rules for managementnet & privatenet ----------
echo "${CYAN}${BOLD}Creating firewall rules for managementnet & privatenet...${RESET}"
gcloud compute firewall-rules create managementnet-allow-icmp-ssh-rdp \
  --network=managementnet --direction=INGRESS --priority=1000 --action=ALLOW \
  --rules=icmp,tcp:22,tcp:3389 --source-ranges=0.0.0.0/0

gcloud compute firewall-rules create privatenet-allow-icmp-ssh-rdp \
  --network=privatenet --direction=INGRESS --priority=1000 --action=ALLOW \
  --rules=icmp,tcp:22,tcp:3389 --source-ranges=0.0.0.0/0

echo "${GREEN}${BOLD}Firewall rules (sorted by network):${RESET}"
gcloud compute firewall-rules list --sort-by=NETWORK

# ---------- Create VMs in custom networks ----------
echo "${CYAN}${BOLD}Creating managementnet-us-vm in ${ZONE_1} (managementsubnet-us, Debian 12)...${RESET}"
gcloud compute instances create managementnet-us-vm \
  --zone="$ZONE_1" \
  --machine-type=e2-micro \
  --subnet=managementsubnet-us \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=10GB \
  --boot-disk-type=pd-standard \
  --boot-disk-device-name=managementnet-us-vm

echo "${CYAN}${BOLD}Creating privatenet-us-vm in ${ZONE_1} (privatesubnet-us, Debian 12)...${RESET}"
gcloud compute instances create privatenet-us-vm \
  --zone="$ZONE_1" \
  --machine-type=e2-micro \
  --subnet=privatesubnet-us \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=10GB \
  --boot-disk-type=pd-standard \
  --boot-disk-device-name=privatenet-us-vm

echo "${GREEN}${BOLD}Instances (sorted by zone):${RESET}"
gcloud compute instances list --sort-by=ZONE

# ===================== Helpful Verification Steps =====================
echo
echo "${BG_GREEN}${BOLD}Next steps to verify connectivity (as per lab):${RESET}"
echo "${YELLOW}- SSH (IAP) to mynet-us-vm:${RESET} gcloud compute ssh mynet-us-vm --zone=${ZONE_1} --tunnel-through-iap"
echo "${YELLOW}- Ping mynet-notus-vm external IP:${RESET} ping -c 3 <mynet-notus-vm-external-ip>"
echo "${YELLOW}- Ping mynet-notus-vm internal IP:${RESET} ping -c 3 <mynet-notus-vm-internal-ip>"
echo "${YELLOW}- Try pinging managementnet-us-vm / privatenet-us-vm internal IPs (expected to FAIL due to VPC isolation).${RESET}"
echo
echo "${BG_RED}${BOLD}Congratulations For Completing The Lab !!!${RESET}"
