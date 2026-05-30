# Troubleshooting Guide — EKS Java Monitoring Stack Deployment

This document covers every issue encountered during the deployment of a Java application with a full kube-prometheus-stack monitoring setup on Amazon EKS, along with root causes and fixes.

---

## Environment

| Component | Detail |
|-----------|--------|
| EKS Version | 1.34 |
| Region | us-east-1 |
| Cluster Name | eks-java |
| Instance Type | t3.medium (production) / t3.small (demo) |
| Nodes | 2 (us-east-1a, us-east-1b) |
| VPC CIDR | 10.0.0.0/16 |
| Helm Chart | kube-prometheus-stack v85.1.3 (app v0.90.1) |
| ALB Controller | AWS Load Balancer Controller v2.7+ (Helm) |

---

## Issue #1: Pod Capacity Exceeded (t2.micro)

**Symptoms:**
- Pods stuck in `Pending` state
- Events: `0/2 nodes are available: 2 Too many pods`

**Root Cause:**
Initially used `t2.micro` instances which have a max pod limit of **4 pods per node** (due to ENI limits: `max_pods = (ENIs × IPs_per_ENI) - 1`). The monitoring stack alone requires 8+ pods.

**Fix:**
Changed instance type from `t2.micro` to `t3.small` which supports **11 pods per node**.

```yaml
# eksctl-cluster.yaml
managedNodeGroups:
  - instanceType: t3.small  # was t2.micro
```

Had to delete the old node group and create a new one with t3.small instances.

**Lesson:** Always calculate pod capacity before choosing instance types. Formula: `max_pods = (ENIs × (IPs_per_ENI - 1)) + 2`. Use https://github.com/awslabs/amazon-eks-ami/blob/master/nodeadm/internal/kubelet/eni-max-pods.txt as reference.

---

## Issue #2: Nodes Not Joining Cluster (Missing AmazonEKSWorkerNodePolicy)

**Symptoms:**
- Nodes launched by ASG but never appeared in `kubectl get nodes`
- Node group showed `Active` in AWS console but 0 registered nodes

**Root Cause:**
The node IAM role (`eks-java-node-role`) was missing the `AmazonEKSWorkerNodePolicy` managed policy, which is required for the kubelet to communicate with the EKS API server.

**Fix:**
```bash
aws iam attach-role-policy \
  --role-name eks-java-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
```

Then terminated existing EC2 instances so the ASG launched new ones with the updated role.

**Lesson:** EKS managed node groups require at minimum: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, and `AmazonEC2ContainerRegistryReadOnly` (or `AmazonEC2ContainerRegistryPullOnly`).

---

## Issue #3: Pods Stuck in ContainerCreating (Missing AmazonEKS_CNI_Policy)

**Symptoms:**
- Nodes registered successfully but pods stuck in `ContainerCreating`
- `aws-node` DaemonSet pods in `CrashLoopBackOff`
- Events: `failed to assign an IP address to container`

**Root Cause:**
The node role was missing `AmazonEKS_CNI_Policy`. The VPC CNI plugin (`aws-node`) needs this policy to allocate ENIs and IP addresses for pods.

**Fix:**
```bash
aws iam attach-role-policy \
  --role-name eks-java-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

# Restart the aws-node DaemonSet to pick up credentials
kubectl rollout restart daemonset aws-node -n kube-system
```

**Lesson:** Without CNI policy, pods can never get IP addresses. The `aws-node` daemonset silently fails and pods remain in ContainerCreating indefinitely.

---

## Issue #4: EBS CSI Driver CrashLoopBackOff (IMDS Access Denied)

**Symptoms:**
- `ebs-csi-controller` pods in `CrashLoopBackOff` with 56+ restarts
- Containers failing: `csi-provisioner`, `csi-attacher`, `csi-snapshotter`, `csi-resizer`, `ebs-plugin`
- Liveness/readiness probes returning HTTP 500
- Logs: `failed to get region from IMDS` or credential errors

**Root Cause:**
The EBS CSI controller pods run on worker nodes but cannot access IMDS (Instance Metadata Service) for IAM credentials. EKS managed node groups with IMDSv2 enforced (hop limit = 1) prevent pods from reaching IMDS. The controller needs IRSA (IAM Roles for Service Accounts) to get credentials.

**Fix:**
```bash
# Create IRSA for EBS CSI driver
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster eks-java \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --override-existing-serviceaccounts

# Delete and recreate the addon with the IRSA role
aws eks delete-addon --cluster-name eks-java --addon-name aws-ebs-csi-driver --region us-east-1
sleep 30
aws eks create-addon \
  --cluster-name eks-java \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::<Account ID>:role/eksctl-eks-java-addon-iamserviceaccount-kube--Role1-ZoAMTOPeUNeO \
  --region us-east-1
```

**Lesson:** EBS CSI driver on EKS ALWAYS needs IRSA. Controller pods cannot access IMDS even with correct node IAM role permissions. This is the #1 most common EBS CSI issue on EKS.

---

## Issue #5: ALB Controller Not Creating Load Balancer (Missing IAM Policy)

**Symptoms:**
- Ingress resource created but no ALB provisioned
- ALB controller logs: `AccessDenied` errors
- `kubectl describe ingress` showed no address

**Root Cause:**
The AWS Load Balancer Controller needs a specific IAM policy with 50+ permissions for EC2, ELB, WAF, Shield, etc. This policy doesn't exist as an AWS managed policy — it must be created manually.

**Fix:**
```bash
# Download the IAM policy
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

# Create the policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# Create IRSA for the controller
eksctl create iamserviceaccount \
  --cluster eks-java \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::<Account ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

**Lesson:** ALB Controller requires its own dedicated IAM policy. Download from the official repo matching your controller version.

---

## Issue #6: ALB Controller — DescribeRouteTables Permission Denied

**Symptoms:**
- ALB created but target groups not registering targets
- Controller logs: `AccessDenied: ec2:DescribeRouteTables`

**Root Cause:**
The downloaded IAM policy (v2.7.1) was missing the `ec2:DescribeRouteTables` permission, which the controller needs to determine subnet routing for target group registration.

**Fix:**
```bash
# Create a new version of the policy with the missing permission added
aws iam create-policy-version \
  --policy-arn arn:aws:iam::<Account ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy-v3.json \
  --set-as-default
```

Added to the policy:
```json
{
  "Effect": "Allow",
  "Action": ["ec2:DescribeRouteTables"],
  "Resource": "*"
}
```

**Lesson:** Always check controller logs after initial setup. The official IAM policy JSON may not cover all permissions needed depending on your VPC configuration.

---

## Issue #7: ALB Controller IRSA Annotation Overwritten

**Symptoms:**
- ALB controller pods restarting with credential errors
- `kubectl describe sa aws-load-balancer-controller -n kube-system` showed wrong/missing annotation

**Root Cause:**
The `ingress.yaml` file contained a `ServiceAccount` definition for the ALB controller that was re-applied, overwriting the IRSA annotation (`eks.amazonaws.com/role-arn`) that `eksctl` had set.

**Fix:**
Updated `ingress.yaml` to include the correct IRSA role ARN in the ServiceAccount annotation:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::<Account ID>:role/eksctl-eks-java-addon-iamserviceaccount-kube--Role1-O3e6dBTqsx66"
```

**Lesson:** If you manage ServiceAccounts in manifests that are also managed by `eksctl`, ensure the IRSA annotation is preserved. Otherwise, each `kubectl apply` overwrites it.

---

## Issue #8: ALB Host-Based Routing Invalid (Non-FQDN Hostnames)

**Symptoms:**
- Ingress created but ALB rules not routing correctly
- Controller logs: `InvalidParameterValue: host header condition value must be a FQDN`

**Root Cause:**
The initial ingress used host-based routing with short names like `eks-java`, `eks-java-prometheus`. AWS ALB requires fully qualified domain names (FQDNs) for host-based routing rules. Since we had no registered domain, host-based routing was not viable.

**Fix:**
Switched from host-based to path-based routing with a single ALB rule:
```yaml
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: java-service
                port:
                  number: 80
          - path: /grafana
            pathType: Prefix
            backend:
              service:
                name: monitoring-grafana
                port:
                  number: 80
          - path: /prometheus
            pathType: Prefix
            backend:
              service:
                name: prometheus-prometheus
                port:
                  number: 9090
          - path: /alertmanager
            pathType: Prefix
            backend:
              service:
                name: prometheus-alertmanager
                port:
                  number: 9093
```

**Lesson:** AWS ALB host-based routing requires real FQDNs (e.g., `app.example.com`). For demos without a domain, use path-based routing instead.

---

## Issue #9: Alertmanager Crash with externalUrl Path

**Symptoms:**
- Alertmanager pod in `CrashLoopBackOff`
- Logs: `error parsing external URL`

**Root Cause:**
Set `externalUrl: "/alertmanager"` (just a path) in the Alertmanager spec. Alertmanager's `--web.external-url` flag requires a full URL with scheme (e.g., `http://...`), not just a path.

**Fix:**
Used `routePrefix` instead of `externalUrl` for path-based serving:
```yaml
alertmanager:
  alertmanagerSpec:
    routePrefix: /alertmanager
```

`routePrefix` tells Alertmanager to serve its UI under `/alertmanager/` without requiring a full URL.

**Lesson:** `externalUrl` requires a complete URL with `http://` scheme. For sub-path serving behind a reverse proxy, use `routePrefix` instead.

---

## Issue #10: PVC Bound to Wrong AZ — Pod Unschedulable

**Symptoms:**
- Prometheus/Grafana pods stuck in `Pending`
- Events: `node(s) had volume node affinity conflict`

**Root Cause:**
PersistentVolumeClaims (PVCs) using gp2 StorageClass were bound to EBS volumes in `us-east-1a`, but the pod was being scheduled to a node in `us-east-1b`. EBS volumes are AZ-specific and cannot be mounted cross-AZ.

**Fix:**
Disabled persistence entirely since this is a short-lived demo:
```yaml
prometheus:
  prometheusSpec:
    storageSpec: {}  # No PVC

grafana:
  persistence:
    enabled: false

alertmanager:
  alertmanagerSpec:
    storage: {}
```

**Alternative Fix (Production):**
Use `volumeBindingMode: WaitForFirstConsumer` in the StorageClass so PVCs bind only after a pod is scheduled:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2-wait
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
```

**Lesson:** Default `gp2` StorageClass uses `volumeBindingMode: Immediate` which binds PVCs to a random AZ. Multi-AZ clusters should use `WaitForFirstConsumer` to ensure PVCs bind in the same AZ as the pod.

---

## Issue #11: Helm Install --wait Stuck on Admission Patch Job

**Symptoms:**
- `helm install --wait` command hung indefinitely
- `prometheus-admission-patch` job/pod stuck in `Pending`
- Events: `0/2 nodes are available: 2 Too many pods`

**Root Cause:**
The kube-prometheus-stack chart creates a post-install hook job (`prometheus-admission-patch`) that patches the admission webhook with a valid CA certificate. This job creates a pod, but with 11 pods/node limit already exhausted, the pod couldn't schedule. Since `--wait` was used, helm waited indefinitely for the hook to complete.

**Fix:**
Killed the hung helm process. Then deleted the unschedulable job:
```bash
kubectl delete job prometheus-admission-patch -n java
```

**Lesson:** Never use `helm install --wait` on resource-constrained clusters without first verifying pod capacity for all helm hooks. Alternatively, disable the webhook patch entirely (see Issue #13).

---

## Issue #12: Helm Release Stuck in "pending-install" Status

**Symptoms:**
- `helm list` shows status `pending-install`
- `helm upgrade` fails: `another operation (install/upgrade/rollback) is in progress`
- Label/annotation patches on helm secret don't fix it

**Root Cause:**
When `helm install --wait` was killed (Ctrl+C), the release was left in `pending-install` state. Helm stores release status inside the base64+gzip encoded `data.release` field of the secret `sh.helm.release.v1.<name>.v<revision>`, not in labels or annotations. Patching labels alone doesn't change helm's view.

**Fix:**
```bash
# Force uninstall the stuck release
helm uninstall monitoring -n java --no-hooks

# Clean reinstall
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f Monitoring/kube-prometheus-values.yaml \
  -n java \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --no-hooks
```

**Why Other Approaches Failed:**
- Patching secret labels (`status: deployed`) — Helm reads encoded data, not labels
- `helm upgrade` — Blocked by the "operation in progress" lock
- Deleting secret + reinstalling — Still hit webhook issues (see #13)

**Lesson:** A stuck helm release in `pending-install` is best fixed with `helm uninstall --no-hooks` followed by a fresh install. If uninstall also fails, delete the helm secret manually first.

---

## Issue #13: Webhook TLS Certificate Failure Blocking Helm Install

**Symptoms:**
- `helm install` fails with repeated errors:
  ```
  failed calling webhook "prometheusrulemutate.monitoring.coreos.com":
  tls: failed to verify certificate: x509: certificate signed by unknown authority
  ```

**Root Cause:**
The previous install created a `MutatingWebhookConfiguration` named `prometheus-admission` that intercepts all `PrometheusRule` resource creation/updates. The admission-patch job (which injects the correct CA certificate into this webhook) never ran because it couldn't schedule (pod limit). So the webhook existed with an invalid/empty CA bundle, causing all PrometheusRule API calls to fail TLS verification.

**Fix:**
```bash
# Delete the broken webhook configuration
kubectl delete mutatingwebhookconfigurations prometheus-admission

# Now helm install will succeed because no webhook intercepts PrometheusRule creation
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f Monitoring/kube-prometheus-values.yaml \
  -n java \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --no-hooks
```

**Key Detail:** The webhook name was `prometheus-admission` (not `prometheus-kube-prometheus-admission` as the label-based delete expected). Always verify with:
```bash
kubectl get mutatingwebhookconfigurations | grep prom
kubectl get validatingwebhookconfigurations | grep prom
```

**Lesson:** When disabling admission webhooks for reinstall, you must also delete any existing `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` resources from the previous install. They persist even after helm secret deletion and will block API calls.

---

## Issue #14: Grafana Returning 503 (Wrong Service Name in Ingress)

**Symptoms:**
- Accessing `/grafana/` via ALB returned HTTP 503 (Service Temporarily Unavailable)
- ALB returned `Server: awselb/2.0` header (meaning ALB itself generated the 503, not the backend)

**Root Cause:**
The ingress referenced service `prometheus-grafana` but the actual Grafana service was named `monitoring-grafana`. With kube-prometheus-stack:
- `fullnameOverride: prometheus` affects Prometheus, Alertmanager, and Operator service names
- Grafana uses `{release-name}-grafana` format → `monitoring-grafana`

The ALB target group had no registered targets because the referenced service didn't exist.

**Fix:**
Updated `ingress.yaml`:
```yaml
# Wrong
name: prometheus-grafana
# Correct
name: monitoring-grafana
```

**Verification:**
```bash
kubectl get svc -n java | grep grafana
# monitoring-grafana   ClusterIP   172.20.5.135   <none>   80/TCP
```

**Lesson:** Always verify actual service names with `kubectl get svc` after helm install. The `fullnameOverride` in kube-prometheus-stack doesn't override Grafana's naming convention (which uses the helm release name).

---

## Issue #15: Prometheus Redirect to Wrong Path (Missing externalUrl)

**Symptoms:**
- Accessing `/prometheus/` via ALB returned 302 redirect to `/query`
- Following the redirect hit a 404 because `/query` isn't a valid ingress path
- Expected: redirect to `/prometheus/query`

**Root Cause:**
Prometheus was configured with `routePrefix: /prometheus` which tells it to serve at that path. However, when generating redirect URLs (e.g., from `/prometheus/` to the default page), Prometheus v3.x uses `--web.external-url` to determine the absolute redirect path. Without `externalUrl` set, Prometheus generated redirects relative to `/` instead of `/prometheus/`.

**Fix:**
Added `externalUrl` to the Prometheus spec in values:
```yaml
prometheus:
  prometheusSpec:
    routePrefix: /prometheus
    externalUrl: "http://k8s-javamonitoring-773696cefe-1053052287.us-east-1.elb.amazonaws.com/prometheus"
```

Then upgraded:
```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -f Monitoring/kube-prometheus-values.yaml \
  -n java \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --no-hooks
```

**Lesson:** When using `routePrefix` with Prometheus behind a reverse proxy, always set `externalUrl` to the full public-facing URL including the path prefix. This ensures redirects include the correct path.

---

## Issue #16: Invalid YAML Key `nodeAffinity` in Helm Values

**Symptoms:**
- Helm install succeeds but pods not scheduled to expected nodes
- No affinity applied to Prometheus Operator pods
- `kubectl describe pod` shows no node affinity constraints

**Root Cause:**
Used `nodeAffinity:` as the key in the Helm values file instead of the correct `affinity:`. The kube-prometheus-stack chart expects `affinity:` at the component level (containing the full Kubernetes affinity spec). `nodeAffinity:` is a Kubernetes API field that goes *inside* `affinity:`, not at the chart level.

**Wrong:**
```yaml
prometheusOperator:
  nodeAffinity:        # ← WRONG: chart doesn't recognize this key
    requiredDuring...
```

**Correct:**
```yaml
prometheusOperator:
  affinity:            # ← Correct: chart passes this to pod spec
    nodeAffinity:
      requiredDuring...
```

**Lesson:** Helm chart value keys ≠ Kubernetes API fields. The chart wraps `affinity:` into the pod spec's `.spec.affinity`. Always check the chart's `values.yaml` for the correct top-level key.

---

## Issue #17: Invalid Grafana Admin Key `adminuser` vs `admin`

**Symptoms:**
- Grafana pod starts but ignores the Kubernetes secret for credentials
- Default admin/admin login still works (secret not mounted)

**Root Cause:**
Used `adminuser:` in the Grafana Helm values instead of the correct `admin:` key:

**Wrong:**
```yaml
grafana:
  adminuser:                      # ← Not a valid chart key
    existingSecret: grafana-admin-secret
```

**Correct:**
```yaml
grafana:
  admin:                          # ← Correct key
    existingSecret: grafana-admin-secret
    userKey: admin-user
    passwordKey: admin-password
```

**Lesson:** The Grafana subchart uses `admin.existingSecret`, not `adminuser`. Always reference the subchart's `values.yaml` for correct keys.

---

## Issue #18: Invalid Selector Key `justMatchLabels` in Prometheus Spec

**Symptoms:**
- Prometheus not discovering ServiceMonitors from expected namespaces
- `kubectl get servicemonitors -n java` shows resources exist but Prometheus targets page is empty

**Root Cause:**
Used a non-existent key `justMatchLabels` in `serviceMonitorNamespaceSelector`:

**Wrong:**
```yaml
serviceMonitorNamespaceSelector:
  justMatchLabels:          # ← Not a valid Kubernetes label selector key
    app: java
```

**Correct:**
```yaml
serviceMonitorNamespaceSelector:
  matchLabels:              # ← Standard Kubernetes label selector
    app: java
```

The valid keys under a label selector are `matchLabels` and `matchExpressions`. Anything else is silently ignored.

**Lesson:** Kubernetes label selectors only support `matchLabels` (key-value equality) and `matchExpressions` (set-based). Any typo is silently ignored — no error, just no matching.

---

## Issue #19: Ingress Host Field Contains URL Scheme

**Symptoms:**
- ALB Ingress controller logs: `invalid host header value`
- Ingress created but no ALB rules for the host

**Root Cause:**
The Ingress `host` field contained a full URL with scheme (`https://app.example.com`) instead of just the hostname:

**Wrong:**
```yaml
rules:
  - host: https://app.example.com    # ← Scheme not allowed
```

**Correct:**
```yaml
rules:
  - host: app.example.com            # ← Just the FQDN, no scheme
```

The `host` field in an Ingress spec is strictly a hostname for HTTP Host header matching — it never includes a scheme or port.

**Lesson:** Ingress `host` is matched against the HTTP `Host` header, which browsers send without a scheme. Never include `http://` or `https://` in the host field.

---

## Issue #20: Grafana Service Name Mismatch with fullnameOverride

**Symptoms:**
- Ingress references `prometheus-grafana` service
- ALB returns 503 for Grafana host

**Root Cause:**
With `fullnameOverride: prometheus` in kube-prometheus-stack:
- Prometheus service → `prometheus-prometheus` ✓
- Alertmanager service → `prometheus-alertmanager` ✓
- Grafana service → `prometheus-grafana` ✓ (uses `{fullnameOverride}-grafana`)

During the demo deployment with release name `monitoring` (without `fullnameOverride`), the service was `monitoring-grafana`. After adding `fullnameOverride: prometheus` for production, the service name changed to `prometheus-grafana`.

**Fix:**
Updated ingress to reference `prometheus-grafana`:
```yaml
backend:
  service:
    name: prometheus-grafana
    port:
      number: 80
```

**Lesson:** Grafana's service name in kube-prometheus-stack follows the pattern `{fullnameOverride}-grafana` (or `{release-name}-grafana` if no fullnameOverride). Always verify with `kubectl get svc` after changing naming overrides.

---

## Issue #21: defaultRules Disabled — No Built-in Alerts

**Symptoms:**
- No PrometheusRules created by the Helm chart
- `kubectl get prometheusrules -n java` only shows custom rules
- No default alerts in Alertmanager (KubePodCrashLooping, NodeNotReady, etc.)

**Root Cause:**
Had `defaultRules.create: false` in the values file, which disables all 200+ community-maintained alerting rules that come with kube-prometheus-stack.

**Fix:**
```yaml
defaultRules:
  create: true
  rules:
    alertmanager: true
    general: true
    kubernetesApps: true
    # ... enable what you need
    etcd: false              # Disable what's not accessible on EKS
    kubeScheduler: false
    kubeControllerManager: false
    kubeProxy: false
```

**Lesson:** `defaultRules.create: true` is essential for production. These rules cover critical scenarios (node down, pod crash loops, disk pressure, etc.) that custom rules alone won't catch. Disable only the ones for components you can't scrape (etcd, scheduler, controller-manager on managed EKS).

---

## Quick Reference: Final Working Configuration

### Required Node Role Policies
```
AmazonEKSWorkerNodePolicy
AmazonEKS_CNI_Policy
AmazonEBSCSIDriverPolicy
AmazonEC2ContainerRegistryPullOnly
AmazonElasticContainerRegistryPublicReadOnly
```

### IRSA Roles Required
| Component | Service Account | Namespace |
|-----------|----------------|-----------|
| EBS CSI Driver | ebs-csi-controller-sa | kube-system |
| ALB Controller | aws-load-balancer-controller | kube-system |

### Helm Install Command (Final Working)
```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  -f Monitoring/kube-prometheus-values.yaml \
  -n java \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --no-hooks
```

### Key Helm Values for Path-Based Routing
```yaml
prometheus:
  prometheusSpec:
    routePrefix: /prometheus
    externalUrl: "http://<ALB_DNS>/prometheus"

alertmanager:
  alertmanagerSpec:
    routePrefix: /alertmanager

grafana:
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s/grafana"
      serve_from_sub_path: true
```

### Verified Working Endpoints
| Service | Path | HTTP Status |
|---------|------|-------------|
| Java App (Actuator) | /actuator | 200 |
| Java Metrics | /actuator/prometheus | 200 |
| Grafana | /grafana/ | 302 → /grafana/login (200) |
| Prometheus | /prometheus/query | 200 |
| Alertmanager | /alertmanager/ | 200 |

---

## Common Pitfalls Summary

1. **EBS CSI on EKS always needs IRSA** — node role permissions are not enough
2. **ALB requires FQDNs for host-based routing** — use path-based for demos
3. **Never `helm install --wait` on constrained clusters** — hooks may not schedule
4. **Check actual service names** after helm install — naming conventions vary per sub-chart
5. **`routePrefix` + `externalUrl`** must both be set for correct reverse proxy behavior
6. **Stuck helm releases** → `helm uninstall --no-hooks` is the cleanest fix
7. **Stale webhooks block reinstalls** — delete `MutatingWebhookConfiguration` before retrying
8. **EBS volumes are AZ-bound** — use `WaitForFirstConsumer` or disable persistence
9. **t3.small = 11 pods/node, t3.medium = 17 pods/node** — plan pod count before choosing instance types
10. **Always verify IAM policies match controller version** — missing permissions cause silent failures
11. **Chart keys ≠ K8s API fields** — use `affinity:` not `nodeAffinity:` at chart level
12. **`matchLabels` not `justMatchLabels`** — typos in label selectors are silently ignored
13. **Ingress `host` is just a hostname** — never include `http://` or `https://`
14. **Grafana naming: `{fullnameOverride}-grafana`** — changes when you add/modify fullnameOverride
15. **`defaultRules.create: true` is essential** — provides 200+ community alerts for production
