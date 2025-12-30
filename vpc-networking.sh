
clear

#!/bin/bash
set -euo pipefail

# ------------------------------- Color variables ------------------------------------
BLACK=$(tput setaf 0); RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6); WHITE=$(tput setaf 7)
BG_BLACK=$(tput setab 0); BG_RED=$(tput setab 1); BG_GREEN=$(tput setab 2); BG_YELLOW=$(tput setab 3)
BG_BLUE=$(tput setab 4); BG_MAGENTA=$(tput setab 5); BG_CYAN=$(tput setab 6); BG_WHITE=$(tput setab 7)
BOLD=$(tput bold); RESET=$(tput sgr0)

TEXT_COLORS=($RED $GREEN $YELLOW $BLUE $MAGENTA $CYAN)
BG_COLORS=($BG_RED $BG_GREEN $BG_YELLOW $BG_BLUE $BG_MAGENTA $BG_CYAN)
RANDOM_TEXT_COLOR=${TEXT_COLORS[$RANDOM % ${#TEXT_COLORS[@]}]}
RANDOM_BG_COLOR=${BG_COLORS[$RANDOM % ${#BG_COLORS[@]}]}

echo "${RANDOM_BG_COLOR}${RANDOM_TEXT_COLOR}${BOLD}Starting Execution${RESET}"

# -------------------- Project & fixed regions from lab ------------------------------
export DEVSHELL_PROJECT_ID="$(gcloud config get-value project)"
export PROJECT_ID="${DEVSHELL_PROJECT_ID}"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"

# Primary backend region/zone (for image build VM)
export REGION="us-east1"
export ZONE="${REGION}-d"

# Secondary backend region
export REGION2="asia-southeast1"

echo "${BOLD}${CYAN}Project:${RESET} ${PROJECT_ID}"
echo "${BOLD}${CYAN}Primary Backend:${RESET} ${REGION} (${ZONE})"
echo "${BOLD}${CYAN}Secondary Backend:${RESET} ${REGION2}"

# -------------------- Enable required services --------------------------------------
echo "${BOLD}${YELLOW}Enabling Compute & IAP APIs${RESET}"
gcloud services enable compute.googleapis.com iap.googleapis.com

# -------------------- Health check firewall rule (default VPC) ----------------------
echo "${BOLD}${MAGENTA}Creating firewall rule for HTTP LB health checks (TCP:80)${RESET}"
gcloud compute firewall-rules create fw-allow-health-checks \
  --direction=INGRESS \
  --priority=1000 \
  --network=default \
  --action=ALLOW \
  --rules=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-checks

# -------------------- Cloud NAT in us-east1 on default VPC --------------------------
echo "${BOLD}${CYAN}Creating Cloud Router + NAT in ${REGION}${RESET}"
gcloud compute routers create nat-router-us1 \
  --network=default \
  --region="${REGION}"

gcloud compute routers nats create nat-config \
  --router=nat-router-us1 \
  --region="${REGION}" \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges

# -------------------- Image build VM (no external IP), install Apache ----------------
echo "${BOLD}${BLUE}Creating webserver (image-build VM) in ${ZONE}${RESET}"
gcloud compute instances create webserver \
    --project="${DEVSHELL_PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type=e2-medium \
    --network-interface="network=default,stack-type=IPV4_ONLY,no-address" \
    --metadata=enable-oslogin=true \
    --tags=allow-health-checks \
    --create-disk=boot=yes,device-name=webserver,image-family=debian-12,image-project=debian-cloud,mode=rw,size=10GB,type=pd-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=goog-ec-src=vm_add-gcloud \
    --reservation-affinity=any

echo "${BOLD}${GREEN}Installing Apache & enabling at boot${RESET}"
gcloud compute ssh webserver --zone="${ZONE}" --quiet \
  --command="sudo apt-get update && sudo apt-get install -y apache2 && sudo service apache2 start && sudo update-rc.d apache2 enable && curl -sS localhost || true"

echo "${BOLD}${YELLOW}Resetting webserver to verify auto-start${RESET}"
gcloud compute instances reset webserver --zone="${ZONE}" --quiet
for ((i=30; i>=0; i--)); do echo -ne "\rWaiting after reset: $i sec "; sleep 1; done; echo

gcloud compute ssh webserver --zone="${ZONE}" --quiet --command="sudo service apache2 status || true"

# -------------------- Create custom image from boot disk ----------------------------
echo "${BOLD}${BLUE}Creating image 'mywebserver' from webserver boot disk${RESET}"
gcloud compute instances delete webserver --zone="${ZONE}" --keep-disks=boot --quiet
gcloud compute images create mywebserver \
  --source-disk=webserver \
  --source-disk-zone="${ZONE}" \
  --quiet

# -------------------- Global instance template (no external IP) ---------------------
echo "${BOLD}${GREEN}Creating global instance template 'mywebserver-template'${RESET}"
gcloud compute instance-templates create mywebserver-template \
  --project="${DEVSHELL_PROJECT_ID}" \
  --machine-type=e2-micro \
  --network-interface="network=default,stack-type=IPV4_ONLY,no-address" \
  --metadata=enable-oslogin=true \
  --tags=allow-health-checks \
  --create-disk=auto-delete=yes,boot=yes,device-name=mywebserver-template,image=projects/${DEVSHELL_PROJECT_ID}/global/images/mywebserver,mode=rw,size=10GB,type=pd-balanced \
  --no-shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --reservation-affinity=any \
  --quiet

# -------------------- TCP health check on 80 ----------------------------------------
echo "${BOLD}${YELLOW}Creating TCP health check 'http-health-check' on port 80${RESET}"
gcloud compute health-checks create tcp http-health-check \
  --port=80 \
  --quiet

# -------------------- Regional MIGs in us-east1 & asia-southeast1 -------------------
echo "${BOLD}${MAGENTA}Creating 'us-1-mig' in ${REGION}${RESET}"
gcloud compute instance-groups managed create us-1-mig \
  --project="${DEVSHELL_PROJECT_ID}" \
  --base-instance-name=us-1-mig \
  --template=mywebserver-template \
  --region="${REGION}" \
  --size=1 \
  --health-check=http-health-check \
  --initial-delay=60 \
  --quiet

gcloud compute instance-groups managed set-autoscaling us-1-mig \
  --region="${REGION}" \
  --min-num-replicas=1 \
  --max-num-replicas=2 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60 \
  --mode=on \
  --quiet

echo "${BOLD}${MAGENTA}Creating 'notus-1-mig' in ${REGION2}${RESET}"
gcloud compute instance-groups managed create notus-1-mig \
  --project="${DEVSHELL_PROJECT_ID}" \
  --base-instance-name=notus-1-mig \
  --template=mywebserver-template \
  --region="${REGION2}" \
  --size=1 \
  --health-check=http-health-check \
  --initial-delay=60 \
  --quiet

gcloud compute instance-groups managed set-autoscaling notus-1-mig \
  --region="${REGION2}" \
  --min-num-replicas=1 \
  --max-num-replicas=2 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60 \
  --mode=on \
  --quiet

for ((i=120; i>=0; i--)); do echo -ne "\rWaiting for MIG instances to initialize: $i sec "; sleep 1; done; echo

# -------------------- Global external Application Load Balancer ---------------------
echo "${BOLD}${BLUE}Creating backend service 'http-backend' (EXTERNAL_MANAGED, HTTP)${RESET}"
gcloud compute backend-services create http-backend \
  --global \
  --protocol=HTTP \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --health-checks=http-health-check \
  --enable-logging \
  --logging-sample-rate=1.0

# Add backends: us-east1 (RATE, 50 RPS) & asia-southeast1 (UTILIZATION, 80%)
gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=us-1-mig \
  --instance-group-region="${REGION}" \
  --balancing-mode=RATE \
  --max-rate-per-instance=50 \
  --capacity-scaler=1.0 \
  --port=80

gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=notus-1-mig \
  --instance-group-region="${REGION2}" \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.8 \
  --capacity-scaler=1.0 \
  --port=80

# URL map & target HTTP proxies
echo "${BOLD}${GREEN}Creating URL map & target HTTP proxies${RESET}"
gcloud compute url-maps create http-lb \
  --global \
  --default-service=http-backend

gcloud compute target-http-proxies create http-lb-target-proxy \
  --global \
  --url-map=http-lb

gcloud compute target-http-proxies create http-lb-target-proxy-ipv6 \
  --global \
  --url-map=http-lb

# IPv4 & IPv6 forwarding rules (HTTP 80)
echo "${BOLD}${YELLOW}Creating IPv4 & IPv6 forwarding rules${RESET}"
gcloud compute forwarding-rules create http-lb-ipv4 \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --target-http-proxy=http-lb-target-proxy \
  --ports=80 \
  --ip-version=IPV4 \
  --network-tier=PREMIUM

gcloud compute forwarding-rules create http-lb-ipv6 \
  --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --target-http-proxy=http-lb-target-proxy-ipv6 \
  --ports=80 \
  --ip-version=IPV6 \
  --network-tier=PREMIUM

LB_IP_V4="$(gcloud compute forwarding-rules describe http-lb-ipv4 --global --format='value(IPAddress)')"
LB_IP_V6="$(gcloud compute forwarding-rules describe http-lb-ipv6 --global --format='value(IPAddress)')"
echo
echo "${BOLD}${CYAN}Load Balancer IPv4:${RESET} ${LB_IP_V4}"
echo "${BOLD}${CYAN}Load Balancer IPv6:${RESET} ${LB_IP_V6}"
echo

# Wait for LB to serve Apache
echo "${BOLD}${MAGENTA}Waiting for LB to serve Apache page (HTTP 80)${RESET}"
RESULT=""
for ((i=120; i>=0; i--)); do
  echo -ne "\rChecking LB readiness: $i sec "
  if RESULT=$(curl -m1 -s "http://${LB_IP_V4}" | grep -i "Apache"); then break; fi
  sleep 5
done
echo
[ -n "$RESULT" ] && echo "${GREEN}${BOLD}LB is ready — Apache detected.${RESET}" || echo "${YELLOW}${BOLD}LB check timed out; proceed to stress test.${RESET}"
echo

# -------------------- Stress-test instance (user picks a zone close to us-east1) ----
echo "${BOLD}${BLUE}Creating stress-test instance (choose a zone close to us-east1)${RESET}"
read -p "${BOLD}${CYAN}Enter STRESS_TEST_ZONE (e.g., us-central1-a): ${RESET}" STRESS_ZONE
STRESS_ZONE="${STRESS_ZONE:-us-central1-a}"

gcloud compute instances create stress-test \
    --project="${DEVSHELL_PROJECT_ID}" \
    --zone="${STRESS_ZONE}" \
    --machine-type=e2-micro \
    --network-interface="network=default,stack-type=IPV4_ONLY,network-tier=PREMIUM" \
    --metadata=enable-oslogin=true \
    --create-disk=auto-delete=yes,boot=yes,device-name=stress-test,image=projects/${DEVSHELL_PROJECT_ID}/global/images/mywebserver,mode=rw,size=10GB,type=pd-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels=goog-ec-src=vm_add-gcloud \
    --reservation-affinity=any

echo "${BOLD}${GREEN}Preparing ApacheBench & printing command${RESET}"
gcloud compute ssh stress-test --zone="${STRESS_ZONE}" --quiet \
  --command="sudo apt-get update && sudo apt-get install -y apache2-utils && echo 'LB_IP=${LB_IP_V4}' && echo 'Run: ab -n 500000 -c 1000 http://${LB_IP_V4}/'"

echo
echo "${BOLD}${CYAN}Stress command on stress-test VM:${RESET}"
echo "${BOLD}${YELLOW}ab -n 500000 -c 1000 http://${LB_IP_V4}/ ${RESET}"
echo

# -------------------- Congrats ------------------------------------------------------
function random_congrats() {
    MESSAGES=(
        "${GREEN}Congratulations For Completing The Lab! Keep up the great work!${RESET}"
        "${CYAN}Well done! Your hard work and effort have paid off!${RESET}"
        "${YELLOW}Amazing job! You’ve successfully completed the lab!${RESET}"
        "${BLUE}Outstanding! Your dedication has brought you success!${RESET}"
        "${MAGENTA}Great work! You’re one step closer to mastering this!${RESET}"
        "${RED}Fantastic effort! You’ve earned this achievement!${RESET}"
    )
    echo -e "${BOLD}${MESSAGES[$RANDOM % ${#MESSAGES[@]}]}"
}
random_congrats

echo -e "\n"

# Optional helper: remove files starting with gsp/arc/shell in $HOME
cd
remove_files() {
    for file in *; do
        if [[ "$file" == gsp* || "$file" == arc* || "$file" == shell* ]]; then
            [[ -f "$file" ]] && rm "$file" && echo "File removed: $file"
        fi
    done
}
# Uncomment to enable automatic cleanup:
# remove_files
