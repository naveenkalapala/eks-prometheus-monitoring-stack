#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="eks-java"
REGION="us-east-1"
NAMESPACE="java"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }


# Pre-flight checks

preflight() {
  log "Running pre-flight checks..."
  for cmd in aws eksctl kubectl helm curl; do
    command -v "$cmd" >/dev/null 2>&1 || error "'$cmd' not found. Please install it first."
  done
  aws sts get-caller-identity >/dev/null 2>&1 || error "AWS credentials not configured."

  ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
  log "AWS Account ID: ${ACCOUNT_ID}"
  log "All pre-flight checks passed."
}


# Step 1: Create EKS Cluster

create_cluster() {
  log "Creating EKS cluster '${CLUSTER_NAME}'..."

  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    warn "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
  else
    eksctl create cluster -f "${SCRIPT_DIR}/eksctl-cluster.yaml"
    log "Cluster created successfully."
  fi

  # Update kubeconfig
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
  log "kubeconfig updated."

  # Verify connectivity
  kubectl get nodes || error "Cannot connect to cluster after creation."
  log "Cluster is ready."
}


# Step 2: Setup IAM for ALB Controller

setup_alb_iam() {
  log "Setting up IAM for ALB controller..."

  OIDC_PROVIDER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

  # Create IAM policy (idempotent)
  POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
  POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
  if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    log "Creating IAM policy..."
    curl -fsSL -o /tmp/alb-iam-policy.json \
      "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
    aws iam create-policy \
      --policy-name "$POLICY_NAME" \
      --policy-document file:///tmp/alb-iam-policy.json
  else
    warn "IAM policy already exists."
  fi

  # Create IAM role with OIDC trust policy
  ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
  if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    log "Creating IAM role..."
    cat > /tmp/alb-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }
  ]
}
EOF
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document file:///tmp/alb-trust-policy.json
    aws iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn "$POLICY_ARN"
  else
    warn "IAM role already exists."
  fi

  log "ALB IAM setup complete."
}


# Step 3: Apply ingress.yaml (ServiceAccount + StorageClass + Ingress)

apply_ingress() {
  log "Applying ingress.yaml (ServiceAccount, StorageClass, Ingress)..."
  kubectl apply -f "${SCRIPT_DIR}/ingress.yaml"

  # Annotate ServiceAccount with actual role ARN (overrides placeholder)
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSLoadBalancerControllerRole"
  kubectl annotate serviceaccount aws-load-balancer-controller \
    -n kube-system \
    "eks.amazonaws.com/role-arn=${ROLE_ARN}" \
    --overwrite

  log "ingress.yaml applied."
}


# Step 4: Install AWS Load Balancer Controller (Helm)

install_alb_controller() {
  log "Installing AWS Load Balancer Controller..."

  VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text)

  helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
  helm repo update eks

  if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
    warn "ALB controller already installed. Upgrading..."
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName="$CLUSTER_NAME" \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set region="$REGION" \
      --set vpcId="$VPC_ID" \
      --set resources.requests.cpu=10m \
      --set resources.requests.memory=48Mi \
      --set resources.limits.cpu=50m \
      --set resources.limits.memory=96Mi
  else
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName="$CLUSTER_NAME" \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller \
      --set region="$REGION" \
      --set vpcId="$VPC_ID" \
      --set resources.requests.cpu=10m \
      --set resources.requests.memory=48Mi \
      --set resources.limits.cpu=50m \
      --set resources.limits.memory=96Mi
  fi

  kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
  log "ALB controller installed."
}


# Step 5: Deploy Java Application (Namespace + Deployment + Service)

deploy_java_app() {
  log "Deploying Java application..."
  kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"
  kubectl rollout status deployment/java-example -n "$NAMESPACE" --timeout=120s
  log "Java application deployed."
}


# Step 6: Create Grafana Admin Secret

create_grafana_secret() {
  if ! kubectl get secret grafana-admin-secret -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Applying Grafana admin secret from grafana-secrets.yaml..."
    kubectl apply -f "${SCRIPT_DIR}/grafana-secrets.yaml"
  else
    warn "Grafana admin secret already exists."
  fi
}


# Step 7: Install kube-prometheus-stack (Helm)

install_monitoring() {
  log "Installing kube-prometheus-stack..."

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community

  if helm status prometheus -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "Already installed. Upgrading..."
    helm upgrade prometheus prometheus-community/kube-prometheus-stack \
      -f "${SCRIPT_DIR}/kube-prometheus-values.yaml" \
      -n "$NAMESPACE" \
      --timeout 10m \
      --wait
  else
    helm install prometheus prometheus-community/kube-prometheus-stack \
      -f "${SCRIPT_DIR}/kube-prometheus-values.yaml" \
      -n "$NAMESPACE" \
      --timeout 10m \
      --wait
  fi

  log "kube-prometheus-stack installed."
}


# Step 8: Apply ServiceMonitor & PrometheusRules

apply_monitors() {
  log "Applying ServiceMonitor and PrometheusRules..."
  kubectl apply -f "${SCRIPT_DIR}/service-monitor.yaml"
  log "ServiceMonitor and PrometheusRules applied."
}


# Step 9: Verify Deployment

verify() {
  echo ""
  log "==================== DEPLOYMENT SUMMARY ===================="
  echo ""
  log "Cluster: ${CLUSTER_NAME} (${REGION})"
  echo ""
  log "Nodes:"
  kubectl get nodes -o wide
  echo ""
  log "Pods in namespace '${NAMESPACE}':"
  kubectl get pods -n "$NAMESPACE" -o wide
  echo ""
  log "Services:"
  kubectl get svc -n "$NAMESPACE"
  echo ""
  log "Ingress:"
  kubectl get ingress -n "$NAMESPACE"
  echo ""

  # Wait for ALB DNS
  log "Waiting for ALB to provision..."
  ALB_DNS=""
  for i in $(seq 1 30); do
    ALB_DNS=$(kubectl get ingress monitoring-ingress -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n "$ALB_DNS" ]]; then
      break
    fi
    sleep 10
  done

  ALB_DNS="${ALB_DNS:-PENDING}"

  log "==================== ACCESS ENDPOINTS ===================="
  echo ""
  echo "  ALB DNS: ${ALB_DNS}"
  echo ""
  echo "  Configure DNS CNAME records pointing to the ALB:"
  echo ""
  echo "    app.example.com          → ${ALB_DNS}"
  echo "    grafana.example.com      → ${ALB_DNS}"
  echo "    prometheus.example.com   → ${ALB_DNS}"
  echo "    alertmanager.example.com → ${ALB_DNS}"
  echo ""
  echo "  Then access:"
  echo "    Java App:     https://app.example.com"
  echo "    Grafana:      https://grafana.example.com"
  echo "    Prometheus:   https://prometheus.example.com"
  echo "    Alertmanager: https://alertmanager.example.com"
  echo ""
  log "==========================================================="
}


# Main

main() {
  log "Starting full deployment pipeline..."
  echo ""
  log "This script automates the entire manual deployment process:"
  log "  1. Create EKS cluster (eksctl)"
  log "  2. Setup IAM for ALB controller"
  log "  3. Apply ingress.yaml (ServiceAccount + StorageClass + Ingress)"
  log "  4. Install ALB controller (Helm)"
  log "  5. Deploy Java application"
  log "  6. Create Grafana admin secret"
  log "  7. Install kube-prometheus-stack (Helm)"
  log "  8. Apply ServiceMonitor & PrometheusRules"
  log "  9. Verify & print endpoints"
  echo ""

  preflight
  create_cluster
  setup_alb_iam
  apply_ingress
  install_alb_controller
  deploy_java_app
  create_grafana_secret
  install_monitoring
  apply_monitors
  verify

  log "Deployment complete! Project is live."
}

main "$@"
