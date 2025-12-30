
#!/bin/bash

# ---------------------------------------------
# Implement Private Google Access and Cloud NAT
# Region/Zone per lab: us-east4 / us-east4-b
# ---------------------------------------------

set -euo pipefail

# Fetch project; set zone/region from lab spec
DEVSHELL_PROJECT_ID="$(gcloud config get-value project)"
ZONE="us-east4-b"
REGION="${ZONE%-*}"   # -> us-east4

echo "Project: ${DEVSHELL_PROJECT_ID}"
echo "Zone:    ${ZONE}"
echo "Region:  ${REGION}"

# Enable required APIs
gcloud services enable compute.googleapis.com iap.googleapis.com

# ------------------------------------------------------------------
# Task 1: Create VPC + subnet + IAP SSH firewall (tcp:22 from IAP CIDR)
# ------------------------------------------------------------------
gcloud compute networks create privatenet \
  --project="${DEVSHELL_PROJECT_ID}" \
  --subnet-mode=custom --mtu=1460 --bgp-routing-mode=regional

gcloud compute networks subnets create privatenet-us \
  --project="${DEVSHELL_PROJECT_ID}" \
  --network=privatenet --region="${REGION}" \
  --range=10.130.0.0/20 --stack-type=IPV4_ONLY

# IAP TCP forwarding range (required for SSH via IAP) 35.235.240.0/20
# Ref: https://cloud.google.com/iap/docs/using-tcp-forwarding
gcloud compute firewall-rules create privatenet-allow-ssh \
  --project="${DEVSHELL_PROJECT_ID}" \
  --direction=INGRESS --priority=1000 \
  --network=privatenet --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20

# ------------------------------------------------------------------
# Create VM with NO external IP (Debian 12, E2 standard-2) in us-east4-b
# ------------------------------------------------------------------
gcloud compute instances create vm-internal \
  --project="${DEVSHELL_PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type=e2-standard-2 \
  --network-interface="network=privatenet,subnet=privatenet-us,no-address,stack-type=IPV4_ONLY,network-tier=PREMIUM" \
  --create-disk="auto-delete=yes,boot=yes,device-name=vm-internal,image-family=debian-12,image-project=debian-cloud,mode=rw,size=10GB,type=pd-balanced" \
  --maintenance-policy=MIGRATE --provisioning-model=STANDARD \
  --labels=goog-ec-src=vm_add-gcloud \
  --reservation-affinity=any

# ------------------------------------------------------------------
# Task 2: Create bucket, copy object; enable Private Google Access
# ------------------------------------------------------------------
# Use a globally-unique bucket name (override by: export MY_BUCKET=my-unique-name)
MY_BUCKET="${MY_BUCKET:-${DEVSHELL_PROJECT_ID}-pga-$(date +%s)}"

# Create a multi‑region US bucket and copy the test object
gsutil mb -l US "gs://${MY_BUCKET}"
gsutil cp gs://cloud-training/gcpnet/private/access.svg "gs://${MY_BUCKET}/access.svg"

# Enable Private Google Access on the subnet (required for VM without external IP)
# Ref: https://cloud.google.com/vpc/docs/configure-private-google-access
gcloud compute networks subnets update privatenet-us \
  --project="${DEVSHELL_PROJECT_ID}" \
  --region="${REGION}" \
  --enable-private-ip-google-access

# ------------------------------------------------------------------
# Task 3: Configure Cloud NAT (with logging) in us-east4
# ------------------------------------------------------------------
# Create Cloud Router
gcloud compute routers create nat-router \
  --project="${DEVSHELL_PROJECT_ID}" \
  --region="${REGION}" \
  --network=privatenet

# Create NAT for all subnet IP ranges, auto-allocate EIPs, and enable logging
# Ref (logging options): https://cloud.google.com/nat/docs/monitoring
gcloud compute routers nats create nat-config \
  --project="${DEVSHELL_PROJECT_ID}" \
  --router=nat-router \
  --region="${REGION}" \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips \
  --enable-logging \
  --logging-filter=ALL

# ------------------------------------------------------------------
# Helpful outputs and next steps
# ------------------------------------------------------------------
echo "---------------------------------------------"
echo "Resources created:"
echo "  • VPC: privatenet"
echo "  • Subnet: privatenet-us (${REGION}, 10.130.0.0/20)"
echo "  • Firewall: privatenet-allow-ssh (tcp:22 from 35.235.240.0/20)"
echo "  • VM: vm-internal (${ZONE}) — NO external IP"
echo "  • Bucket: gs://${MY_BUCKET}  (object: access.svg)"
echo "  • Cloud Router: nat-router (${REGION})"
echo "  • Cloud NAT: nat-config (logging enabled)"
echo "---------------------------------------------"
echo "Verification commands (run in Cloud Shell):"
echo "  # SSH via IAP (no external IP required)"
echo "  gcloud compute ssh vm-internal --zone ${ZONE} --tunnel-through-iap"
echo
echo "  # Verify Private Google Access from inside vm-internal:"
echo "  gcloud compute ssh vm-internal --zone ${ZONE} --tunnel-through-iap --command \"curl -I -sSf https://storage.googleapis.com/${MY_BUCKET}/access.svg && echo 'PGA works'\""
echo
echo "  # After ~1–2 minutes, verify Cloud NAT (apt update succeeds):"
echo "  gcloud compute ssh vm-internal --zone ${ZONE} --tunnel-through-iap --command \"sudo apt-get update -y && echo 'NAT works'\""
echo
echo "  # View Cloud NAT logs:"
echo "  # Console → Network services → Cloud NAT → nat-config → View in Logs Explorer"
echo "---------------------------------------------"
