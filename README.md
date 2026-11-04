# litellminstall

Run [LiteLLM](https://github.com/BerriAI/litellm) as a proxy in front of **Claude on Google Vertex AI**, so tools that speak the OpenAI API (such as [Open WebUI](https://github.com/open-webui/open-webui)) can use it with a plain URL and API key.
Note: please make sure you go into google(model garden) and accept the agreement for each model you plan to use.  If you don't and you add a model below, it will fail when making the call to vertex. 

## Why a proxy?

- **No static API key.** Vertex AI only accepts short-lived Google OAuth tokens, which expire after about an hour.
- **Different API format.** Claude on Vertex uses Anthropic's Messages API. Open WebUI expects an OpenAI-compatible `/v1/chat/completions` endpoint.

LiteLLM handles the Google authentication and translates between the two APIs. You get a fixed URL and a key you choose:

```
Open WebUI  --(OpenAI API + your key)-->  LiteLLM  --(Google OAuth)-->  Vertex AI (Claude)
```

## Repository layout

| Path | Purpose |
|---|---|
| `k8s/litellm-k8s.yaml` | Namespace, ConfigMap (model list), Deployment, and Service |
| `k8s/secrets.example.yaml` | Template for the two required Secrets (placeholders only) |
| `docker/config.yaml` | Model list for running locally in Docker |
| `docker/run.sh` | Starts LiteLLM locally in Docker |

## Placeholders

Replace these before deploying:

| Placeholder | Example | Where to find it |
|---|---|---|
| `<your-gcp-project-id>` | `my-project-123456` | `gcloud projects list` (use the **Project ID**, not the name) |
| `<your-vertex-region>` | `global`, `us-east5`, `europe-west1` | A region where Claude is enabled in Vertex AI Model Garden |
| `<your-litellm-master-key>` | `sk-...` | Generate one: `echo "sk-$(openssl rand -hex 32)"` |
| `<paste-your-google-credentials-json-here>` | | Your Google credentials file (see below) |

Fill in the project and region in place:

```bash
sed -i 's/<your-gcp-project-id>/my-project-123456/g; s/<your-vertex-region>/global/g' \
  k8s/litellm-k8s.yaml docker/config.yaml
```

## Quick start (Kubernetes)

1. Replace the placeholders in `k8s/litellm-k8s.yaml` (see [Placeholders](#placeholders)).
2. Generate your Google credentials (see [Step 2](#step-2-generate-your-google-credentials)).
3. Create the secrets and deploy:

```bash
kubectl create namespace litellm
#create the master key - the one you use as a token
kubectl -n litellm create secret generic litellm-master-key   --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)"
#create the secret that uses your vertex credentials - as created in step 2
kubectl -n litellm create secret generic gcp-creds   --from-file=adc.json=$HOME/.config/gcloud/application_default_credentials.json
#deploy litellm
kubectl apply -f <dir>/litellm-k8s.yaml
```

`<dir>` is the `k8s` directory of this repo. For example, from the repo root: `kubectl apply -f k8s/litellm-k8s.yaml`.

4. Verify the deployment and get your token:
   ```bash
   # make sure your credentials file (adc.json) gets deployed in the pod
   kubectl -n litellm exec deploy/litellm -- ls -la /creds/
   # get the token/key to use in liz or openwebui
   kubectl -n litellm get secret litellm-master-key -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d; echo
   ```
   The `ls` output should list `adc.json`. If it doesn't, see [Troubleshooting](#troubleshooting).

5. URL for the LiteLLM service, as configured by the deployment. **Do not leave `/v1` off the end; it's required.**
   ```
   http://litellm.litellm.svc.cluster.local:4000/v1
   ```
   This address works from inside the cluster. For other setups, see [URL to use](#url-to-use) and [Connecting Open WebUI](#connecting-open-webui).

The sections below explain each step in detail.

## Step 1: Prepare your GCP project

1. **Enable the Vertex AI API:**
   ```bash
   gcloud services enable aiplatform.googleapis.com --project <your-gcp-project-id>
   ```
2. **Enable the Claude models in Vertex AI Model Garden.** In the Google Cloud console, go to **Vertex AI → Model Garden**. Search for each Claude model you list in the config (for example Claude Opus 5.5 and Claude Haiku 4.5) and click **Enable**.

## Step 2: Generate your Google credentials

LiteLLM needs a Google credentials JSON file to call Vertex AI. Pick one of these options.

### Option 1: Your own login (fine for testing)

1. Install the Google Cloud CLI if you don't have it: <https://cloud.google.com/sdk/docs/install>
2. Log in and set your project:
   ```bash
   gcloud auth login
   gcloud config set project <your-gcp-project-id>
   ```
3. Create Application Default Credentials (ADC). This opens a browser to sign in:
   ```bash
   gcloud auth application-default login
   gcloud auth application-default set-quota-project <your-gcp-project-id>
   ```
   This writes the credentials file to:
   ```
   $HOME/.config/gcloud/application_default_credentials.json
   ```
   This is the file the quick start uses for the `gcp-creds` secret.
4. Check that the credentials work and can reach Claude on Vertex:
   ```bash
   ls -la $HOME/.config/gcloud/application_default_credentials.json
   gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
   ```

These credentials are tied to your personal Google account. They may expire or be revoked, for example if you change your password or your organization enforces re-authentication. When that happens, rerun `gcloud auth application-default login` and recreate the `gcp-creds` secret.

### Option 2: A service account key (recommended for long-running use)

This uses a dedicated service account that only has permission to call Vertex AI:

```bash
gcloud iam service-accounts create litellm --project <your-gcp-project-id>

gcloud projects add-iam-policy-binding <your-gcp-project-id> \
  --member "serviceAccount:litellm@<your-gcp-project-id>.iam.gserviceaccount.com" \
  --role roles/aiplatform.user

gcloud iam service-accounts keys create litellm-key.json \
  --iam-account litellm@<your-gcp-project-id>.iam.gserviceaccount.com
```

Then use `--from-file=adc.json=./litellm-key.json` when you create the `gcp-creds` secret. Some organizations block service account key creation by policy. If yours does, use Option 1 or Option 3.

### Option 3: Workload Identity on GKE (no key file)

See [Using Workload Identity](#using-workload-identity-gke).

> **Never commit credentials.** `.gitignore` excludes `.env`, `k8s/secrets.yaml`, and common credential file names. Even so, check `git status` before you commit.

---

## Option A: Kubernetes

### 1. Create the namespace and secrets

Run these from the machine where you generated the credentials file (Step 2), and make sure `kubectl` points at the right cluster (`kubectl config current-context`). If you create the secret on a machine that doesn't have the file, the secret ends up empty.

```bash
kubectl create namespace litellm

#create the master key - the one you use as a token
kubectl -n litellm create secret generic litellm-master-key \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)"

#create the secret that uses your vertex credentials - as created in step 2
# The key name inside the secret MUST be adc.json
kubectl -n litellm create secret generic gcp-creds \
  --from-file=adc.json=$HOME/.config/gcloud/application_default_credentials.json
#   or, with a service account key: --from-file=adc.json=./litellm-key.json
```

Check that the credentials secret isn't empty. The output should be a few hundred or more, not `0`:

```bash
kubectl -n litellm get secret gcp-creds -o jsonpath='{.data.adc\.json}' | wc -c
```

To create the secrets from a file instead (for example through the Rancher UI or GitOps), copy `k8s/secrets.example.yaml` to `k8s/secrets.yaml`, fill it in, and apply it. `k8s/secrets.yaml` is git-ignored.

### 2. Deploy

```bash
kubectl apply -f k8s/litellm-k8s.yaml
kubectl -n litellm rollout status deploy/litellm
kubectl -n litellm logs -f deploy/litellm
```

### 3. Test from inside the cluster

```bash
KEY=$(kubectl -n litellm get secret litellm-master-key -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)

kubectl -n litellm run curltest --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://litellm.litellm.svc.cluster.local:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-5-5","messages":[{"role":"user","content":"Say hi"}]}'
```

### URL to use

The Service is a `ClusterIP`, so it's only reachable inside the cluster.

| Where the client runs | URL |
|---|---|
| Same cluster, different namespace | `http://litellm.litellm.svc.cluster.local:4000/v1` |
| Same cluster, `litellm` namespace | `http://litellm:4000/v1` |
| Outside the cluster (testing) | `kubectl -n litellm port-forward svc/litellm 4000:4000`, then `http://localhost:4000/v1` |
| Outside the cluster (permanent) | Add an Ingress or NodePort. Keep it on a private network and use TLS. |

---

## Option B: Local Docker

```bash
cd docker
echo "LITELLM_MASTER_KEY=sk-$(openssl rand -hex 32)" > .env   # git-ignored
./run.sh
```

`run.sh` mounts `~/.config/gcloud/application_default_credentials.json` by default. To use a different file:

```bash
GOOGLE_CREDS_FILE=/path/to/<your-credentials>.json ./run.sh
```

Test it:

```bash
source .env
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

| Where the client runs | URL |
|---|---|
| On the host | `http://localhost:4000/v1` |
| In another Docker container on the same host | `http://host.docker.internal:4000/v1` |

---

## Connecting Open WebUI

1. Go to **Admin Panel → Settings → Connections → OpenAI API → +**.
2. **URL:** the URL from the table for your setup. In-cluster, that is `http://litellm.litellm.svc.cluster.local:4000/v1`. **The `/v1` is required; without it Open WebUI finds no models.**
3. **Key:** your LiteLLM master key.
   - **Kubernetes:**
     ```bash
     kubectl -n litellm get secret litellm-master-key -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d; echo
     ```
   - **Docker:** the value in `docker/.env`.
4. Save. `claude-opus-5-5` and `claude-haiku-4-5` appear in the model list.

## Adding or changing models

Add entries to the `model_list` in `k8s/litellm-k8s.yaml` (ConfigMap) or `docker/config.yaml`:

```yaml
  - model_name: <name-shown-in-open-webui>
    litellm_params:
      model: vertex_ai/<vertex-model-id>
      vertex_project: <your-gcp-project-id>
      vertex_location: <your-vertex-region>
```

Then restart the proxy:

- **Kubernetes:** `kubectl apply -f k8s/litellm-k8s.yaml && kubectl -n litellm rollout restart deploy/litellm`
- **Docker:** `./run.sh`

## Using Workload Identity (GKE)

To avoid key files on GKE:

1. Remove the `GOOGLE_APPLICATION_CREDENTIALS` env var, the `gcp-creds` volume, and its volume mount from `k8s/litellm-k8s.yaml`.
2. Create a Kubernetes ServiceAccount annotated with `iam.gke.io/gcp-service-account: litellm@<your-gcp-project-id>.iam.gserviceaccount.com`, and set `serviceAccountName` on the Deployment.
3. Grant that Google service account `roles/aiplatform.user`. Then grant `roles/iam.workloadIdentityUser` to `serviceAccount:<your-gcp-project-id>.svc.id.goog[litellm/<k8s-service-account-name>]`.

## Troubleshooting

| Error | Cause and fix |
|---|---|
| `UnsafeMasterKeyError: no master key is set` | `LITELLM_MASTER_KEY` isn't reaching the container. Check that the `litellm-master-key` secret has a non-empty `LITELLM_MASTER_KEY` key, or that `docker/.env` exists. |
| `File /creds/adc.json was not found` | The `gcp-creds` secret is empty or the key isn't named `adc.json`. Recreate it with `--from-file=adc.json=<path>`. |
| Pod stuck in `CreateContainerConfigError` | A required secret or secret key is missing: `kubectl -n litellm describe pod -l app=litellm`. |
| `403 Permission denied` / `PERMISSION_DENIED` | The credentials lack `roles/aiplatform.user`, or the Claude model isn't enabled in Model Garden for that project. |
| `404 Not found` for the model | Wrong model ID or region. Check that the model is available in `<your-vertex-region>`. |
| `invalid_grant` / `Reauthentication needed` | Your personal login expired. Run `gcloud auth application-default login`, then recreate the `gcp-creds` secret (or rerun `run.sh`). |
| Open WebUI shows no models | The URL is missing `/v1`, the key is wrong, or Open WebUI can't reach the URL from where it runs. |

## Security notes

- Anyone with the master key and network access to the proxy can use your Vertex AI quota, and it's billed to your project. Don't expose the proxy to the internet without TLS and network restrictions.
- Prefer a dedicated service account with only `roles/aiplatform.user` over your personal credentials.
- Rotate the master key by recreating the `litellm-master-key` secret and restarting the deployment.
