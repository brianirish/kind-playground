#!/usr/bin/env bash

set -e

# CONSTANTS

readonly KIND_NODE_IMAGE=kindest/node:v1.30.0
readonly DNSMASQ_DOMAIN=kind.cluster
if [[ "$(uname)" == "Darwin" ]]; then
  readonly DNSMASQ_CONF_PATH="$(brew --prefix)/etc"
  readonly DNSMASQ_CONF_FILENAME="dnsmasq.conf"
elif [[ "$(uname)" == "Linux" ]]; then
  readonly DNSMASQ_CONF_PATH="/etc/dnsmasq.d"
  readonly DNSMASQ_CONF_FILENAME="kind.k8s.conf"
fi

# FUNCTIONS

log(){
  echo "---------------------------------------------------------------------------------------"
  echo $1
  echo "---------------------------------------------------------------------------------------"
}

wait_ready(){
  local NAME=${1:-pods}
  local TIMEOUT=${2:-5m}
  local SELECTOR=${3:---all}

  log "WAIT $NAME ($TIMEOUT) ..."

  kubectl wait -A --timeout=$TIMEOUT --for=condition=ready $NAME $SELECTOR
}

wait_pods_ready(){
  local TIMEOUT=${1:-5m}

  wait_ready pods $TIMEOUT --field-selector=status.phase!=Succeeded
}

wait_nodes_ready(){
  local TIMEOUT=${1:-5m}

  wait_ready nodes $TIMEOUT
}

network(){
  local NAME=${1:-kind}

  log "NETWORK (kind) ..."

  if [ -z $(docker network ls --filter name=^$NAME$ --format="{{ .Name }}") ]
  then 
    docker network create $NAME
    echo "Network $NAME created"
  else
    echo "Network $NAME already exists, skipping"
  fi
}

proxy(){
  local NAME=$1
  local TARGET=$2

  if [ -z $(docker ps --filter name=^proxy-gcr$ --format="{{ .Names }}") ]
  then
    docker run -d --name $NAME --restart=always --net=kind -e REGISTRY_PROXY_REMOTEURL=$TARGET registry:2
    echo "Proxy $NAME (-> $TARGET) created"
  else
    echo "Proxy $NAME already exists, skipping"
  fi
}

proxies(){
  log "REGISTRY PROXIES ..."

  proxy proxy-docker-hub https://registry-1.docker.io
  proxy proxy-quay       https://quay.io
  proxy proxy-gcr        https://gcr.io
  proxy proxy-k8s-gcr    https://k8s.gcr.io
}

get_service_lb_ip(){
  kubectl get svc -n $1 $2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

get_subnet(){
  docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' $1
}

subnet_to_ip(){
  echo $1 | sed "s@0.0/16@$2@"
}

root_ca(){
  log "ROOT CERTIFICATE ..."

  mkdir -p .ssl

  if [[ -f ".ssl/root-ca.pem" && -f ".ssl/root-ca-key.pem" ]]
  then
    echo "Root certificate already exists, skipping"
  else
    openssl genrsa -out .ssl/root-ca-key.pem 2048
    openssl req -x509 -new -nodes -key .ssl/root-ca-key.pem -days 3650 -sha256 -out .ssl/root-ca.pem -subj "/CN=kube-ca"
    echo "Root certificate created"
  fi
}

install_ca(){
  log "INSTALL CERTIFICATE AUTHORITY ..."

  sudo mkdir -p /usr/local/share/ca-certificates/kind.cluster

  sudo cp -f .ssl/root-ca.pem /usr/local/share/ca-certificates/kind.cluster/ca.crt

  if command -v update-ca-certificates >/dev/null 2>&1; then
    sudo update-ca-certificates
  elif command -v security >/dev/null 2>&1; then
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /usr/local/share/ca-certificates/kind.cluster/ca.crt
  else
    echo "Error: Cannot install the kind cluster certificate because the required system commands are not available."
    exit 1
  fi
}

cluster(){
  local NAME=${1:-kind}

  log "CLUSTER ..."

  docker pull $KIND_NODE_IMAGE

  kind create cluster --name $NAME --image $KIND_NODE_IMAGE --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
kubeadmConfigPatches:
  - |-
    kind: ClusterConfiguration
    apiServer:
      extraVolumes:
        - name: opt-ca-certificates
          hostPath: /opt/ca-certificates/root-ca.pem
          mountPath: /opt/ca-certificates/root-ca.pem
          readOnly: true
          pathType: File
      extraArgs:
        oidc-client-id: kube
        oidc-issuer-url: https://keycloak.kind.cluster/auth/realms/master
        oidc-username-claim: email
        oidc-groups-claim: groups
        oidc-ca-file: /opt/ca-certificates/root-ca.pem
    controllerManager:
      extraArgs:
        bind-address: 0.0.0.0
    etcd:
      local:
        extraArgs:
          listen-metrics-urls: http://0.0.0.0:2381
    scheduler:
      extraArgs:
        bind-address: 0.0.0.0
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["http://proxy-docker-hub:5000"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["http://proxy-quay:5000"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."k8s.gcr.io"]
      endpoint = ["http://proxy-k8s-gcr:5000"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
      endpoint = ["http://proxy-gcr:5000"]
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: control-plane
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: control-plane
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: worker
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: worker
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: worker
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
EOF
}

cilium(){
  log "CILIUM ..."

  helm upgrade --install --wait --timeout 15m --atomic --namespace kube-system --create-namespace \
    --repo https://helm.cilium.io cilium cilium --values - <<EOF
kubeProxyReplacement: true
k8sServiceHost: kind-external-load-balancer
k8sServicePort: 6443
hostServices:
  enabled: true
externalIPs:
  enabled: true
nodePort:
  enabled: true
hostPort:
  enabled: true
image:
  pullPolicy: IfNotPresent
ipam:
  mode: kubernetes
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: nginx
        cert-manager.io/cluster-issuer: ca-issuer
      hosts:
        - hubble-ui.$DNSMASQ_DOMAIN
      tls:
        - secretName: hubble-ui.$DNSMASQ_DOMAIN
          hosts:
            - hubble-ui.$DNSMASQ_DOMAIN
EOF
}

cert_manager(){
  log "CERT MANAGER ..."

  helm repo add jetstack https://charts.jetstack.io --force-update && \
  helm repo update
  kubectl create namespace cert-manager
  kubectl label namespace cert-manager cert-manager.io/disable-validation=true

  helm upgrade --install --wait --timeout 15m --atomic --namespace cert-manager --create-namespace \
    cert-manager jetstack/cert-manager --set installCRDs=true
}

cert_manager_ca_secret(){
  kubectl delete secret -n cert-manager root-ca || true
  kubectl create secret tls -n cert-manager root-ca --cert=.ssl/root-ca.pem --key=.ssl/root-ca-key.pem
}

cert_manager_ca_issuer(){
  kubectl apply -n cert-manager -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ca-issuer
spec:
  ca:
    secretName: root-ca
EOF
}

metallb(){
  log "METALLB ..."

  local KIND_SUBNET=$(get_subnet kind)
  local METALLB_START=$(subnet_to_ip $KIND_SUBNET 255.200)
  local METALLB_END=$(subnet_to_ip $KIND_SUBNET 255.250)

  helm upgrade --install --wait --timeout 15m --atomic --namespace metallb-system --create-namespace \
    --repo https://metallb.github.io/metallb metallb metallb --set controller.podSecurityContext.seccompProfile.type=RuntimeDefault --set speaker.podSecurityContext.seccompProfile.type=RuntimeDefault --values - <<EOF
labels:
  pod-security.kubernetes.io/enforce: privileged
  pod-security.kubernetes.io/audit: privileged
  pod-security.kubernetes.io/warn: privileged
EOF

  kubectl apply -n metallb-system -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - $METALLB_START-$METALLB_END
EOF
}

ingress(){
  log "INGRESS-NGINX ..."

  helm upgrade --install --wait --timeout 15m --atomic --namespace ingress-nginx --create-namespace \
    --repo https://kubernetes.github.io/ingress-nginx ingress-nginx ingress-nginx --values - <<EOF
defaultBackend:
  enabled: true
EOF
}

dnsmasq(){
  log "DNSMASQ ..."

  local INGRESS_LB_IP=$(get_service_lb_ip ingress-nginx ingress-nginx-controller)
  echo "Ingress LoadBalancer IP: $INGRESS_LB_IP"
  # local LOCAL_CUSTOM_TLD="cluster"
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "Detected Mac OS, using 'brew' to install and configure 'dnsmasq'..."
    # brew install dnsmasq
    
    echo "Making config directory at $DNSMASQ_CONF_PATH"
    mkdir -p $DNSMASQ_CONF_PATH

    echo "Writing to DNSMASQ config..."
    echo "address=/$DNSMASQ_DOMAIN/$INGRESS_LB_IP" | sudo tee $DNSMASQ_CONF_PATH/$DNSMASQ_CONF_FILENAME
    
    echo "Successfully wrote to dnsmasq config. Restarting dnsmasq..."
    sudo brew services restart dnsmasq
    
    echo "Creating resolver for .cluster TLD..."
    sudo mkdir -p /etc/resolver
    sudo echo "nameserver $INGRESS_LB_IP" > /etc/resolver/cluster
  elif [[ "$(uname)" == "Linux" ]]; then
    echo "address=/$DNSMASQ_DOMAIN/$INGRESS_LB_IP" | sudo tee $DNSMASQ_CONF_PATH/$DNSMASQ_CONF_FILENAME
    echo "Successfully wrote to dnsmasq config. Restarting dnsmasq..."
    sudo systemctl restart dnsmasq
  fi
}

cleanup(){
  log "CLEANUP ..."

  kind delete cluster || true
  sudo rm -f $DNSMASQ_CONF_PATH/$DNSMASQ_CONF_FILENAME
  sudo rm -rf /usr/local/share/ca-certificates/kind.cluster
}

# RUN

cleanup
network
proxies
root_ca
install_ca
cluster
cilium
cert_manager
cert_manager_ca_secret
cert_manager_ca_issuer
metallb
ingress
dnsmasq

# DONE

log "CLUSTER READY !"

echo "HUBBLE UI: https://hubble-ui.$DNSMASQ_DOMAIN"
