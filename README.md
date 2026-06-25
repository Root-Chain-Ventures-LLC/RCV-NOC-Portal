# RCV NOC Portal

The **RCV NOC Portal** is the hub of the Root Chain Ventures network-operations
platform: it provides single sign-on (SSO) / identity for, and a single gateway
in front of, the RCV modules — **PingIt**, **Site Look Up**, and **Outage Track**.

This repository contains **operator install artifacts only** (a Kubernetes/Helm
quickstart and example values). The application ships as container images and
Helm charts from the GitHub Container Registry (GHCR); no application source
lives here.

## License

**RCV Community License 1.0** — free for personal / home-lab use and for any
organization's own internal operations. A paid commercial license is required
only to offer the software to third parties as a hosted, managed, or SaaS
service. See [`LICENSE`](LICENSE). Commercial inquiries: **legal@rootchainventures.com**.

## Prerequisites

- Kubernetes **1.24+**
- Helm **3.8+** (OCI registry support)
- An **external PostgreSQL 14+** reachable from the cluster — the Portal does
  **not** bundle a database
- An ingress controller (or wire your own routing to the Portal's ClusterIP Service)

## Quickstart — the whole platform (umbrella chart)

The umbrella chart installs the Portal (always) plus any modules you enable.
Install with the release name `rcv` so in-cluster module→Portal URLs resolve to
`rcv-noc-portal`.

```bash
# Generate the two required secrets (no extra packages needed):
PORTAL_SECRET_KEY=$(openssl rand -hex 32)
ENC_KEY=$(python3 -c "import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())")

helm install rcv oci://ghcr.io/root-chain-ventures-llc/helm/rcv-platform --version 0.1.0 \
  --namespace rcv --create-namespace \
  --set noc-portal.secrets.portalSecretKey="$PORTAL_SECRET_KEY" \
  --set noc-portal.secrets.secretsEncryptionKey="$ENC_KEY" \
  --set noc-portal.database.host=<pg-host> \
  --set noc-portal.database.password=<pg-password> \
  --set noc-portal.env.PORTAL_PUBLIC_BASE_URL=https://noc.example.com \
  --set noc-portal.ingress.enabled=true \
  --set noc-portal.ingress.host=noc.example.com
```

Prefer a values file? Copy [`values.example.yaml`](values.example.yaml), fill in
the blanks, and:

```bash
helm install rcv oci://ghcr.io/root-chain-ventures-llc/helm/rcv-platform --version 0.1.0 \
  --namespace rcv --create-namespace -f values.example.yaml
```

Enable modules by setting `pingit.enabled=true`, `siteLookUp.enabled=true`,
and/or `outageTrack.enabled=true` (each is OFF by default). Modules can run with
an in-chart PostgreSQL (`<module>.postgres.enabled=true`, the default) or point
at your own.

## Quickstart — Portal only

```bash
helm install rcv oci://ghcr.io/root-chain-ventures-llc/helm/noc-portal --version 0.1.0 \
  --namespace rcv --create-namespace \
  --set secrets.portalSecretKey="$PORTAL_SECRET_KEY" \
  --set secrets.secretsEncryptionKey="$ENC_KEY" \
  --set database.host=<pg-host> --set database.password=<pg-password> \
  --set env.PORTAL_PUBLIC_BASE_URL=https://noc.example.com
```

## Required configuration

| Setting (umbrella key) | Purpose |
|---|---|
| `noc-portal.secrets.portalSecretKey` | App secret key (`openssl rand -hex 32`) |
| `noc-portal.secrets.secretsEncryptionKey` | Encryption key for stored secrets — **must persist across restarts** (a urlsafe-base64 32-byte / Fernet key) |
| `noc-portal.database.host` + `noc-portal.database.password` | External PostgreSQL (or set `noc-portal.database.url` to a full URL) |
| `noc-portal.env.PORTAL_PUBLIC_BASE_URL` | The Portal's public `https://` URL — the OIDC issuer + SSO redirect base; must match your ingress host |

Alternatively, pre-create a Secret with `PORTAL_SECRET_KEY`,
`PORTAL_SECRETS_ENCRYPTION_KEY`, and `PORTAL_DATABASE_URL`, then set
`noc-portal.existingSecret=<name>`.

## After install

- Schema migrations run automatically as a one-shot pre-install/upgrade Job.
- No ingress? Reach the Portal via the Service:
  ```bash
  kubectl -n rcv port-forward svc/rcv-noc-portal 8000:8000
  # open http://localhost:8000/healthz
  ```
- A first-run admin is seeded (**admin@rcv.example.com / changeme**) — **rotate it immediately**.
- Add/enable modules from the Portal UI.

## Charts & images (all `0.1.0`)

Helm charts (OCI):
- `oci://ghcr.io/root-chain-ventures-llc/helm/rcv-platform` — umbrella (Portal + modules)
- `oci://ghcr.io/root-chain-ventures-llc/helm/noc-portal` — Portal only
- `oci://ghcr.io/root-chain-ventures-llc/helm/rcv-module` — generic module chart

Container images:
- `ghcr.io/root-chain-ventures-llc/noc-portal-web`
- `ghcr.io/root-chain-ventures-llc/noc-portal-deployer`
- `ghcr.io/root-chain-ventures-llc/pingit-web`, `…/pingit-worker`
- `ghcr.io/root-chain-ventures-llc/site-look-up`
- `ghcr.io/root-chain-ventures-llc/outage-track`

## Uninstall

```bash
helm uninstall rcv -n rcv
```
