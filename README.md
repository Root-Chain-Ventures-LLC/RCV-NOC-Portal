# RCV NOC Portal

The **RCV NOC Portal** is the hub of the Root Chain Ventures network-operations
platform: it owns identity / single sign-on (SSO), API keys, the module catalog,
and the gateway that fronts the RCV modules — **PingIt**, **Site Look Up**, and
**Outage Track**.

This repository contains **operator install artifacts only** (a Kubernetes/Helm
quickstart and example values). The application ships as container images and
Helm charts from the GitHub Container Registry (GHCR); no application source
lives here.

> **Install the Portal first, then add modules from the Portal UI.** The Portal
> is the only standalone install. When you add a module, the Portal **mints its
> OIDC client + API key and deploys it for you** — you never hand-wire module
> secrets.

## License

**RCV Community License 1.0** — free for personal / home-lab use and for any
organization's own internal operations. A paid commercial license is required
only to offer the software to third parties as a hosted, managed, or SaaS
service. See [`LICENSE`](LICENSE). Commercial inquiries: **legal@rootchainventures.com**.

## Prerequisites

- Kubernetes **1.24+**
- Helm **3.8+** (OCI registry support)
- An **external PostgreSQL 14+** for the Portal — the Portal does **not** bundle a database
- A PostgreSQL the modules can use (the cluster DB authority you pass as `PORTAL_K8S_MODULE_DB`)
- An ingress controller (or wire your own routing to the Portal Service)

## 1. Install the Portal

Install the `noc-portal` chart with `rbac.create=true` — that grants the Portal a
namespaced ServiceAccount/Role **and** turns on in-cluster module deploys
(`PORTAL_ORCHESTRATOR=kubernetes`), so it can install modules into its own
namespace later. Use release name `rcv` so module→Portal URLs resolve to
`rcv-noc-portal`.

```bash
PORTAL_SECRET_KEY=$(openssl rand -hex 32)
ENC_KEY=$(python3 -c "import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())")

helm install rcv oci://ghcr.io/root-chain-ventures-llc/helm/noc-portal --version 0.1.0 \
  --namespace rcv --create-namespace \
  --set rbac.create=true \
  --set secrets.portalSecretKey="$PORTAL_SECRET_KEY" \
  --set secrets.secretsEncryptionKey="$ENC_KEY" \
  --set database.host=<portal-pg-host> \
  --set database.password=<portal-pg-password> \
  --set env.PORTAL_PUBLIC_BASE_URL=https://noc.example.com \
  --set-string env.PORTAL_K8S_MODULE_DB="moduser:modpass@<pg-host>:5432" \
  --set ingress.enabled=true \
  --set ingress.host=noc.example.com
```

Prefer a file? Copy [`values.example.yaml`](values.example.yaml), fill it in, and
`helm install rcv oci://ghcr.io/root-chain-ventures-llc/helm/noc-portal --version 0.1.0 -n rcv --create-namespace -f values.example.yaml`.

### Required configuration

| Setting | Purpose |
|---|---|
| `rbac.create=true` | Lets the Portal deploy modules in-cluster (also sets `PORTAL_ORCHESTRATOR=kubernetes`) |
| `secrets.portalSecretKey` | App secret key (`openssl rand -hex 32`) |
| `secrets.secretsEncryptionKey` | Encryption key for stored secrets — **must persist across restarts** |
| `database.host` + `database.password` | The Portal's external PostgreSQL (or `database.url`) |
| `env.PORTAL_PUBLIC_BASE_URL` | The Portal's public `https://` URL — OIDC issuer + SSO base; must match the ingress host |
| `env.PORTAL_K8S_MODULE_DB` | `user:password@host:5432` cluster DB authority modules connect to |

## 2. First-run login

- Migrations run automatically as a one-shot Job.
- No ingress yet? `kubectl -n rcv port-forward svc/rcv-noc-portal 8000:8000` then open `http://localhost:8000`.
- Sign in with the seeded admin **admin@rcv.example.com / changeme** — you will be
  required to **rotate the password** immediately.

## 3. Add modules (from the Portal)

In the Portal UI, open **Modules**, pick a module (PingIt / Site Look Up /
Outage Track), and **Install**. The Portal mints the module's OIDC client and a
scoped API key, then deploys its Deployment/Service/Secret into the `rcv`
namespace and wires it behind the gateway. No manual secret handling.

The module repos are documentation pointers only:
[RCV-Ping-It](https://github.com/Root-Chain-Ventures-LLC/RCV-Ping-It) ·
[RCV-Site-Look-Up](https://github.com/Root-Chain-Ventures-LLC/RCV-Site-Look-Up) ·
[RCV-Outage-Track](https://github.com/Root-Chain-Ventures-LLC/RCV-Outage-Track).

## Advanced: declarative multi-module install (umbrella)

For GitOps-style installs you can deploy the Portal plus module workloads
declaratively with the umbrella chart
`oci://ghcr.io/root-chain-ventures-llc/helm/rcv-platform` (set
`<module>.enabled=true`). Note this brings up module **workloads** but does not
register them with the Portal — you still register each module in the Portal
(Modules → Install) so SSO/API credentials match. For most operators, **Portal +
add-from-UI (above) is the supported path.**

## Charts & images (all `0.1.0`)

Charts (OCI): `helm/noc-portal` (Portal), `helm/rcv-module` (generic module),
`helm/rcv-platform` (umbrella) under `ghcr.io/root-chain-ventures-llc/`.
Images under `ghcr.io/root-chain-ventures-llc/`: `noc-portal-web`,
`noc-portal-deployer`, `pingit-web`, `pingit-worker`, `site-look-up`, `outage-track`.

## Uninstall

```bash
helm uninstall rcv -n rcv
```
