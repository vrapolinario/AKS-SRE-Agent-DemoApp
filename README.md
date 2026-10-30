# AKS HTTP 500 / SRE Agent demo

A small ASP.NET Core (.NET 10 LTS) web app with an intentionally reversible,
ConfigMap-driven application failure. This project creates a **new standard AKS
cluster**, a public HTTP LoadBalancer, and dedicated monitoring resources. It
does not configure SRE Agent, its permissions, or its alert integration.

## What gets created

```text
Browser --------------------------> public LoadBalancer --> demo-web
demo-traffic (one request / 2 sec) ------------------------> /api/status
                                                              |
ConfigMap demo-settings --> mounted failure-mode file ---------+
                                                              |
                    Azure Monitor OpenTelemetry --> Application Insights
                                                              |
AKS Container Insights --> container logs --> Log Analytics <--+
                                                  |
                                  HTTP 5XX log alert (severity 1)
```

- AKS Free control-plane tier, two Linux system nodes by default, Azure CNI
  Overlay, managed identity, and Kubernetes RBAC.
- Basic Azure Container Registry. The kubelet identity receives `AcrPull`.
  Azure Container Registry Tasks builds the app; local Docker is not required.
- Workspace-based Application Insights and a shared, 30-day Log Analytics
  workspace. Application telemetry uses the Azure Monitor OpenTelemetry SDK.
- Managed-identity Container Insights, enabled by Azure CLI with its associated
  data collection configuration.
- A stateful Azure Monitor scheduled-query alert: **at least 5 HTTP 5XX requests
  within 5 minutes**, evaluated every minute. The threshold is parameterized.
  The query filters to this Application Insights resource and application role.
  The alert targets the Application Insights resource; its description/custom
  properties identify the AKS cluster, namespace, deployment, and ConfigMap.
  There is **no email, action group, or SRE Agent integration** by default.
- One app replica and one lightweight, continuous traffic-generator replica in
  namespace `sre-demo`. Neither pod needs Kubernetes API access.

**Costs:** nodes/disks, public IP/load balancer, ACR/builds, telemetry ingestion,
retention, and log alerts can incur charges. This is not a free deployment.
The traffic generator and 100% trace sampling are intentional for a short demo.
Delete the dedicated resource group after use.

**Demo-only security tradeoffs:** the browser endpoint is public HTTP with no
authentication or TLS; the AKS API is public and local administrator credentials
are enabled. Application Insights uses connection-string ingestion. Do not send
real customer data or use this deployment as a production baseline. There is no
public endpoint that changes the failure setting.

## Prerequisites

- Azure subscription, permission to register resource providers, adequate
  regional VM quota, and availability of the selected AKS node size.
- Permission to create resources and role assignments, obtain AKS administrator
  credentials, run ACR builds, and query monitoring data. For a disposable lab,
  subscription **Owner** covers deployment; a least-privilege alternative needs
  resource creation rights plus role-assignment rights at the relevant scope.
- PowerShell **7.2+**, a current Azure CLI supporting
  `az aks update --enable-azure-monitor-logs`, `kubectl`, and Bicep CLI.
- Network access to Azure APIs, the AKS API, public container registries,
  Application Insights ingestion endpoints, and the deployed public IP.
- No local .NET SDK or Docker is required to deploy. Local tests need the
  **.NET 10 SDK**.

```powershell
az login
az bicep install
az version
kubectl version --client
```

If your CLI does not recognize `--enable-azure-monitor-logs`, update Azure CLI
before deploying.

## Deploy

Run from this project directory in PowerShell 7. Choose a **new dedicated
resource group**; deployment refuses an existing group without matching demo
ownership tags. All deployment choices are variables/parameters. Replace every
`<...>` placeholder below with your own deployment values before running:

```powershell
$SubscriptionId = '<subscription-id>'
$ResourceGroup = '<resource-group-name>'
$Location = '<azure-region>'
$NamePrefix = '<name-prefix>'   # 3-12 lowercase letters/digits, starting with a letter
$NodeCount = 2
$NodeVmSize = 'Standard_D4s_v5'  # system pools need at least 4 vCPUs per node
$KubernetesVersion = ''        # empty uses the AKS default supported version
$AlertThreshold = 5

.\scripts\Deploy.ps1 `
    -SubscriptionId $SubscriptionId `
    -ResourceGroup $ResourceGroup `
    -Location $Location `
    -NamePrefix $NamePrefix `
    -NodeCount $NodeCount `
    -NodeVmSize $NodeVmSize `
    -KubernetesVersion $KubernetesVersion `
    -AlertThreshold $AlertThreshold
```

Allow roughly 10-25 minutes, sometimes longer depending on Azure provisioning.
The script builds/uploads the image in ACR, creates the telemetry Secret without
printing its value, deploys the app/traffic generator, waits for rollouts and a
public IP, and verifies **both the browser page and API return HTTP 200**.

The script uses explicit subscription arguments and a dedicated
`.state\kubeconfig`; it does not switch your default Azure subscription or
Kubernetes context. `.state\deployment.json` records resource IDs and the image.
Treat the kubeconfig as a credential. Both files are ignored by Git.
Use a separate project copy for each simultaneously active deployment.

Before sharing the project folder, remove `.state\deployment.json`,
`.state\kubeconfig`, and generated `src\DemoWeb\bin` and `src\DemoWeb\obj`
folders. Git ignores these paths, but they can still be included in folder
copies or archives. Removing local state does not delete Azure resources and
prevents the demo management scripts from using that state until it is recreated.

Re-running deployment reuses deterministically named resources, builds a new
image tag, and **resets the failure mode to healthy**. It is not the recommended
way to recover a live demo incident; change the ConfigMap instead.
Container Insights enablement is skipped when its existing workspace and
managed-identity authentication already match. A mismatched configuration causes
an explicit error instead of disabling or replacing existing monitoring.

The defaults follow current AKS system-pool requirements: two nodes with at least
four vCPUs each. This costs more than the application itself needs, but avoids
relying on older, smaller system-pool configurations. Budget quota for upgrade
surge capacity as well.

## Rehearse and demonstrate

### 1. Confirm healthy behavior and telemetry

Open the HTTP URL printed by deployment. The page shows a green **HTTP 200**
status, active mode, pod name, timestamp, and trace ID.

```powershell
.\scripts\Test-Demo.ps1

# Run after initial telemetry has had several minutes to arrive:
.\scripts\Test-Demo.ps1 -CheckTelemetry
```

The telemetry check verifies matching `AppRequests` and `ContainerLogV2` records
actually exist, not just that Azure resources were provisioned. It errors if
records are missing; a fresh table may initially produce a query error. Wait
and retry, or investigate ingestion if the problem persists.

Before recording, connect your SRE Agent to the appropriate subscription,
cluster, Application Insights, workspace, and alert using your own setup.
Creating an alert does **not** by itself attach it to an SRE Agent.

### 2. Introduce a Kubernetes configuration regression

```powershell
.\scripts\Set-FailureMode.ps1 -Mode http500
```

This patches only `demo-settings.data.failure-mode`. It **does not** restart
pods, change the image, or redeploy the app. The setting is mounted as a
directory, **not a `subPath` mount** and **not an environment variable**, so
Kubernetes projects updates into the running container. The app reads the
file on each business request.

Projected-volume changes are asynchronous: allow around 1-2 minutes, sometimes
longer. The script waits for three consecutive API responses with mode
`http500` and HTTP 500, then checks the browser page is also HTTP 500.
Refresh the browser to show the red incident page. This is a real HTTP 500
response, not just a red page returning 200.

The equivalent manual operation is:

```powershell
kubectl --kubeconfig .\.state\kubeconfig -n sre-demo edit configmap demo-settings
# Set data.failure-mode to http500, save, and wait for projection.
```

### 3. Show detection and investigate

The traffic generator continues making one business request every two seconds,
including during failures. It deliberately does not use `curl --fail`:
HTTP 500 is recorded as an HTTP response, not mistaken for a transport error.

In Azure:

1. **Application Insights > Failures**: inspect failed requests and transactions.
2. **Log Analytics > Logs**: run the separate queries in
   [queries/investigation.kql](queries/investigation.kql).
3. **Azure Monitor > Alerts**: filter to the demo resource group and verify the
   severity-1 alert reaches **Fired**.
4. Open your configured SRE Agent investigation workflow.

Allow several minutes for telemetry export/ingestion and alert evaluation;
neither detection nor resolution is instantaneous. Do not schedule a recording
around a guaranteed alert latency.

Useful Kubernetes evidence:

```powershell
kubectl --kubeconfig .\.state\kubeconfig -n sre-demo get pods
kubectl --kubeconfig .\.state\kubeconfig -n sre-demo get configmap demo-settings -o yaml
kubectl --kubeconfig .\.state\kubeconfig -n sre-demo logs deployment/demo-web --tail=30
kubectl --kubeconfig .\.state\kubeconfig -n sre-demo logs deployment/demo-traffic --tail=15
.\scripts\Test-Demo.ps1 -CheckTelemetry
```

The application logs identify `failure-mode=http500`, pod, HTTP status, and trace
ID. Invalid, empty, or unreadable settings also produce explicit error logs and
HTTP 500 instead of silently falling back to healthy.

**Why pods stay Ready:** `/health/live` and `/health/ready` deliberately return
200 during the injected incident. This keeps the service routed to the app so
the browser sees the real application HTTP 500 and avoids a restart loop or
an infrastructure-level 503. This is intentional demonstration behavior, not
a general recommendation for production readiness semantics.

### 4. Recover without restarting

```powershell
.\scripts\Set-FailureMode.ps1 -Mode healthy
.\scripts\Test-Demo.ps1
```

The page returns to green HTTP 200 on the same pod. The alert is stateful and
auto-resolving; the five-minute lookback must clear and Azure Monitor must
observe its required healthy evaluations before it becomes **Resolved**.
Allow additional time before repeating the demo if you want a fresh Fired event.

## Local validation

The following test builds the real app, starts it on a temporary localhost port,
and checks healthy/failing/recovered behavior, HTML and JSON status codes,
non-cached responses, trace IDs, independent probes, and invalid/empty/missing
configuration. It cleans up its process and temporary files. No Azure resources
or telemetry connection string are needed.

```powershell
.\tests\Test-App.ps1
.\tests\Test-Monitoring.ps1
az bicep build --file .\infra\main.bicep
```

Local tests do not validate Azure provisioning, ACR builds, AKS volume projection,
telemetry ingestion, or fired alert instances. Use the deployment/rehearsal checks
above for those.
The monitoring test uses a mocked Azure CLI to check first-run enablement,
safe reruns, configuration mismatches, and CLI failures without Azure changes.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Node creation fails | Regional vCPU quota, node SKU availability, AKS version availability, and Azure deployment operations. Change `NodeVmSize`/region if needed. |
| `ImagePullBackOff` | Kubelet `AcrPull` assignment, propagation delay, ACR egress, and pod events. The deployment waits up to ten minutes for app rollout. |
| ACR build rejected | Permission to queue builds and subscription/registry support for ACR Tasks. Some restricted subscriptions cannot run cloud builds. |
| ACR publish fails with `NETSDK1064` after a successful restore | Local `bin`/`obj` files can overwrite Linux restore metadata during Docker `COPY`. Keep the build-output exclusions in `.dockerignore`, including explicit descendant patterns without trailing directory slashes, and include `.dockerignore` itself in the context. Inspect the failed run with `az acr task logs --subscription $SubscriptionId --registry <registry-name> --run-id <run-id>`. After correcting the context, rerun the same deployment command; existing Azure resources are reused. |
| Pending public IP | `kubectl describe service demo-web -n sre-demo`, public IP quota, Azure policy restrictions. |
| ConfigMap changed but still HTTP 200 | Wait for projected-volume sync. Do not replace the directory mount with `subPath` or use an environment variable. |
| Missing `AppRequests` | Check telemetry Secret, exporter logs, outbound HTTPS, and ingestion delay. Role name must be `aks-sre-demo`. |
| Missing `ContainerLogV2` | Check AKS Container Insights, its agent pods, data collection rule/association, workspace target, and ingestion delay. |
| Alert not firing | Verify actual 500 telemetry, resource/role filters, enabled rule, threshold, and five-minute time window. The alert query is intentionally not validated before first telemetry creates its table. |
| Alert fired but SRE Agent did nothing | Configure the agent's alert integration, resource access, and workflow separately; this project does not do that. |

## Cleanup

This deletes the **entire dedicated resource group** and the AKS-managed node
resources, not just the Kubernetes app. Verify you have not added unrelated
resources to the group. The script checks demo ownership tags, supports
`-WhatIf`, and asks for confirmation.

```powershell
.\scripts\Remove-Demo.ps1 `
    -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix -WhatIf

.\scripts\Remove-Demo.ps1 `
    -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix
```

After successful deletion, matching local deployment metadata and kubeconfig
are removed. Azure monitoring resources can have soft-delete retention.

## References

- [Azure Monitor OpenTelemetry for .NET](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable?tabs=aspnetcore)
- [Enable AKS monitoring](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable)
- [Mounted ConfigMap update behavior](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically)
- [Scheduled query alert resource reference](https://learn.microsoft.com/azure/templates/microsoft.insights/2023-12-01/scheduledqueryrules)
