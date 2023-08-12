#!/bin/bash

# Customization
cd /home/ubuntu/
echo "IP=\$(ip route get 1 | awk '{print \$(NF-2);exit}')" >> ~/.bashrc
echo 'export PS1="\[\e[0m\]\u\[\e[33m\]@\[\e[32m\]\H\[\e[32m\]($IP)\[\e[0m\]:\[\e[0m\][\[\e[0;96m\]\w\[\e[0m\]] \[\e[0m\]" ' >> ~/.bashrc
#echo 'export PS1="\[\e[33m\]ubuntu-vm\[\e[m\]@\[\e[32m\]$IP\[\e[m\]:[\[\e[36m\]\w\[\e[m\]]: " ' >> .bashrc
echo 'alias l="ls -la --color=auto --human-readable --time-style=long-iso --group-directories-first"' >> .bashrc
echo 'alias sudo="sudo " ' >> ~/.bashrc
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
echo "set bell-style none" | sudo tee -a /etc/inputrc
sudo timedatectl set-timezone America/Bogota

# Install Docker
sudo apt update -y
sudo apt install -y software-properties-common docker.io docker-compose jq
sudo systemctl enable docker
sudo systemctl start docker
echo -e "Docker Installed"

# Run containers
cd /home/ubuntu/
git clone https://github.com/f5devcentral/f5-waf-elk-dashboards
cd f5-waf-elk-dashboards
sudo docker-compose -f docker-compose.yaml up -d
sleep 120

KIBANA_URL=http://127.0.0.1:5601
jq -s . kibana/overview-dashboard.ndjson | jq '{"objects": . }' | \
curl -k --location --request POST "$KIBANA_URL/api/kibana/dashboards/import" \
    --header 'kbn-xsrf: true' \
    --header 'Content-Type: text/plain' -d @- \
    | jq

jq -s . kibana/false-positives-dashboards.ndjson | jq '{"objects": . }' | \
curl -k --location --request POST "$KIBANA_URL/api/kibana/dashboards/import" \
    --header 'kbn-xsrf: true' \
    --header 'Content-Type: text/plain' -d @- \
    | jq
    
#sudo docker run --name httpecho --restart=unless-stopped -d -p 8080:8080 -p 8443:8443 mendhak/http-https-echo:22
