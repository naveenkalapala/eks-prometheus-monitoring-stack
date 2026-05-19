# EKS Java Application — Production Monitoring Stack

End-to-end deployment of a Java application on Amazon EKS with a production-grade monitoring stack using **kube-prometheus-stack** (Prometheus, Grafana, Alertmanager).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AWS Cloud (us-east-1)                       │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    EKS Cluster (eks-java)                    │   │
│  │                                                              │   │
│  │  ┌─────────────── Namespace: java ────────────────────────┐  │   │
│  │  │                                                        │  │   │
│  │  │  ┌──────────┐  ┌────────────┐  ┌────────────────────┐  │  │   │
│  │  │  │ Java App │  │ Prometheus │  │ Alertmanager       │  │  │   │
│  │  │  │ (Spring  │  │ (50Gi gp3) │  │ (2Gi gp3)          │  │  │   │
│  │  │  │  Boot)   │  │ 14d retain │  │ Slack integration  │  │  │   │
│  │  │  └──────────┘  └────────────┘  └────────────────────┘  │  │   │
│  │  │                                                        │  │   │
│  │  │  ┌──────────┐  ┌────────────┐  ┌────────────────────┐  │  │   │
│  │  │  │ Grafana  │  │ kube-state │  │ node-exporter      │  │  │   │
│  │  │  │ (5Gi gp3)│  │ -metrics   │  │ (DaemonSet)        │  │  │   │
│  │  │  └──────────┘  └────────────┘  └────────────────────┘  │  │   │
│  │  └────────────────────────────────────────────────────────┘  │   │
│  │                                                              │   │
│  │  ┌─────────────── Namespace: kube-system ─────────────────┐  │   │
│  │  │  ALB Controller │ EBS CSI Driver │ CoreDNS │ VPC CNI   │  │   │
│  │  └────────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐     │
│  │              Application Load Balancer (ALB)               │     │
│  │  app.example.com → Java App                                │     │
│  │  grafana.example.com → Grafana                             │     │
│  │  prometheus.example.com → Prometheus                       │     │
│  │  alertmanager.example.com → Alertmanager                   │     │
│  └────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Component | Version/Detail |
|-----------|---------------|
| EKS | v1.34 |
| Instance Type | t3.medium (17 pods/node, 4GB RAM) |
| Helm Chart | kube-prometheus-stack (latest) |
| ALB Controller | AWS Load Balancer Controller v2.7+ |
| Storage | gp3 (encrypted, WaitForFirstConsumer) |
| Java App | Spring Boot with Micrometer/Actuator |
| Alerting | Slack Channel / Webhook |
| Routing | Host-based (HTTPS via ACM certificate) |

---

## Project Structure

```
Monitoring/
├── README.md                      # This file
├── eksctl-cluster.yaml            # EKS cluster definition (eksctl)
├── deployment.yaml                # Namespace + Java app Deployment + Service
├── ingress.yaml                   # ALB ServiceAccount+gp3 StorageClass+Ingress
├── kube-prometheus-values.yaml    # Helm values for kube-prometheus-stack
├── service-monitor.yaml           # ServiceMonitor + PrometheusRule (5 alerts)
├── grafana-secrets.yaml           # Grafana admin secret template
├── deploy.sh                      # Automated deployment script (end-to-end)
└── troubleshooting.md             # 15+ documented issues with fixes
```

---

## Prerequisites

- AWS CLI v2 configured with appropriate IAM permissions
- `eksctl` installed
- `kubectl` installed
- `helm` v3 installed
- A registered domain (for host-based routing) with ACM certificate
- VPC with at least 2 public subnets in different AZs

---

## Quick Start (Automated)

```bash
cd Monitoring/
chmod +x deploy.sh
./deploy.sh
```

The script automates the entire process from cluster creation to live endpoints.

---

## Manual Deployment

### Step 1: Create EKS Cluster

Update `eksctl-cluster.yaml` with your VPC/subnet IDs, then:

```bash
eksctl create cluster -f eksctl-cluster.yaml
aws eks update-kubeconfig --name eks-java --region us-east-1
```

### Step 2: Setup ALB Controller IAM

```bash
# Create IAM policy
curl -fsSL -o /tmp/alb-iam-policy.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-iam-policy.json

# Create IAM role with OIDC trust (replace ACCOUNT_ID and OIDC_PROVIDER)
aws iam create-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
```

### Step 3: Apply Infrastructure (ingress.yaml)

Update placeholders in `ingress.yaml` (role ARN, subnet IDs, certificate ARN, security group), then:

```bash
kubectl apply -f ingress.yaml
```

This creates:
- ALB Controller ServiceAccount (with IRSA annotation)
- gp3 StorageClass (encrypted, Retain, WaitForFirstConsumer)
- ALB Ingress (host-based routing with HTTPS)

### Step 4: Install ALB Controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

VPC_ID=$(aws eks describe-cluster --name eks-java --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-java \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId="$VPC_ID"
```

### Step 5: Deploy Java Application

```bash
kubectl apply -f deployment.yaml
kubectl rollout status deployment/java-example -n java
```

### Step 6: Create Grafana Secret

```bash
kubectl create secret generic grafana-admin-secret -n java \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<YOUR_SECURE_PASSWORD>'
```

### Step 7: Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm install prometheus prometheus-community/kube-prometheus-stack \
  -f kube-prometheus-values.yaml \
  -n java \
  --timeout 10m \
  --wait
```

### Step 8: Apply ServiceMonitor & Alerts

```bash
kubectl apply -f service-monitor.yaml
```

### Step 9: Configure DNS

Point CNAME records to the ALB DNS:

```
app.example.com          → <ALB_DNS>
grafana.example.com      → <ALB_DNS>
prometheus.example.com   → <ALB_DNS>
alertmanager.example.com → <ALB_DNS>
```

---

## Configuration Highlights

### Monitoring Features

- **Prometheus**: 14-day retention, 45GB retention size, 30s scrape interval
- **Grafana**: Persistent dashboards, auto-discovery via sidecar, 50+ default dashboards
- **Alertmanager**: Slack integration with severity-based routing (warning → #all-prometheus, critical → #all-prometheus with [CRITICAL] prefix)
- **ServiceMonitor**: Scrapes Java app `/actuator/prometheus` endpoint
- **PrometheusRules**: 5 custom alerts (PodNotReady, HighMemory, HighCPU, PodRestarting, AppDown)

### Security

- All components run as non-root (UID 1000, GID 2000)
- Grafana admin credentials stored in Kubernetes Secret (not in values file)
- EBS volumes encrypted at rest
- HTTPS enforced via ACM certificate + HTTP→HTTPS redirect
- ALB drops invalid headers
- IRSA for least-privilege IAM (no broad node role permissions)

### High Availability Considerations

- Nodes across 2 AZs (us-east-1a, us-east-1b)
- Auto-scaling: min 2, max 4 nodes
- WaitForFirstConsumer storage binding (prevents AZ mismatch)
- RollingUpdate strategy for Java app (maxSurge: 1, maxUnavailable: 0)
- Liveness/readiness probes on Java app

### Node Affinity

All monitoring components are pinned to nodes with label `role: java-worker` using `requiredDuringSchedulingIgnoredDuringExecution`.

---

## Alerts

| Alert | Condition | Severity | For |
|-------|-----------|----------|-----|
| JavaAppPodNotReady | Pod not ready | warning | 5m |
| JavaAppHighMemoryUsage | Memory > 80% of limit | warning | 5m |
| JavaAppHighCPUUsage | CPU > 80% of limit | warning | 5m |
| JavaAppPodRestarting | > 3 restarts in 1h | critical | — |
| JavaAppDown | 0 available replicas | critical | 1m |

---

## Placeholders to Replace Before Deployment

| File | Placeholder | Replace With |
|------|------------|--------------|
| `eksctl-cluster.yaml` | `vpc-xxxxx`, `subnet-xxxxx` | Your VPC and subnet IDs |
| `ingress.yaml` | `arn:aws:iam::account-id:role/role-name` | ALB controller IRSA role ARN |
| `ingress.yaml` | `subnet-xxxxx,subnet-yyyyy` | Your public subnet IDs |
| `ingress.yaml` | `arn:aws:acm:...:certificate/cert-id` | Your ACM certificate ARN |
| `ingress.yaml` | `sg-xxxxx` | Your ALB security group ID |
| `ingress.yaml` | `*.example.com` hosts | Your actual FQDNs |
| `kube-prometheus-values.yaml` | `example.com` URLs | Your actual domain |
| `kube-prometheus-values.yaml` | Slack webhook URL | Your Slack webhook |

---

## Useful Commands

```bash
# Check all pods
kubectl get pods -n java -o wide

# Check Prometheus targets
kubectl port-forward svc/prometheus-prometheus -n java 9090:9090
# Visit http://localhost:9090/targets

# Check Grafana
kubectl port-forward svc/prometheus-grafana -n java 3000:80
# Visit http://localhost:3000 (admin / <your-password>)

# View alerts
kubectl get prometheusrules -n java
kubectl port-forward svc/prometheus-alertmanager -n java 9093:9093

# Check ServiceMonitor discovery
kubectl get servicemonitors -n java

# View ALB status
kubectl get ingress -n java
kubectl describe ingress monitoring-ingress -n java

# Helm release status
helm list -n java
helm get values prometheus -n java
```

---

## Teardown

```bash
# Delete monitoring stack
helm uninstall prometheus -n java
helm uninstall aws-load-balancer-controller -n kube-system

# Delete Kubernetes resources
kubectl delete -f service-monitor.yaml
kubectl delete -f ingress.yaml
kubectl delete -f deployment.yaml

# Delete cluster (removes all AWS resources)
eksctl delete cluster --name eks-java --region us-east-1

# Clean up IAM (after cluster deletion)
aws iam detach-role-policy --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole
aws iam delete-policy --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy
```

---

## Troubleshooting

See [troubleshooting.md](troubleshooting.md) for a comprehensive guide covering 17+ issues encountered during deployment with root causes, fixes, and lessons learned.

---

## Cost Estimate

### Production (Monthly)

| Resource | Cost |
|----------|------|
| EKS Control Plane | ~$73 |
| 2× t3.medium nodes | ~$60 |
| 3× gp3 EBS volumes (57Gi total) | ~$5 |
| ALB | ~$22 + data transfer |
| **Total** | **~$160/month** |

### Demo (Few Hours)

| Resource | Cost |
|----------|------|
| EKS Control Plane | ~$0.10/hr |
| 2× t3.medium nodes | ~$0.08/hr |
| EBS volumes | ~$0.01/hr |
| ALB | ~$0.02/hr |
| **Total (4-hour demo)** | **~$0.84** |

*Tear down immediately after demo to avoid charges. EKS bills per hour even when idle.*
