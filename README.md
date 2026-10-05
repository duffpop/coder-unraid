# Coder for Unraid

An Unraid Docker template for [Coder](https://coder.com), the self-hosted platform for
cloud development environments, plus a thin wrapper image
(`ghcr.io/duffpop/coder-unraid`) that makes the official image behave well on Unraid.

The wrapper is the official `ghcr.io/coder/coder` image with a small entrypoint on top. It adds:

- **PUID/PGID** support and automatic ownership fixes for the appdata folder.
- **Docker socket access** without hand-editing `--group-add` parameters. The entrypoint
  detects the socket's group id on the host (281 on Unraid) and adds the Coder user to a
  matching group. If the socket is owned by gid 0 it adds the user to the root group instead.
- **First-run bootstrap** that creates the admin account from template fields.
- **Automatic license install.** Coder has no environment variable for licenses, so the
  entrypoint logs in as the bootstrap admin and uploads the key through the local API.
  It compares the license id against installed licenses first, so restarts never
  create duplicates.
- Blank optional fields are dropped before Coder starts, so an empty box in the Unraid
  form never overrides a Coder default.

Images are rebuilt automatically whenever Coder publishes a release. Tags follow upstream:
`latest`, `v2.36`, `v2.36.7`.

## Install

1. In Unraid open **Docker > Template Repositories** and add
   `https://github.com/duffpop/coder-unraid`, then save.
2. Click **Add Container**, pick **coder** from the template dropdown.
3. Fill in:
   - **Access URL**: how browsers and workspaces reach Coder, for example
     `http://192.168.1.10:7080`, or `https://coder.example.com` if you have a reverse proxy.
     Never `localhost`.
   - **Bootstrap Admin Email / Username / Password**: the first admin account.
     Leave all three blank if you prefer to create it in the web UI.
   - **License Key**: optional. Paste the Premium license JWT. It is applied on start
     when the bootstrap admin fields are set.
4. Apply. First start downloads the built-in PostgreSQL binaries, so give it a minute.
5. Open the WebUI and log in with the bootstrap admin.

Watch the container log for lines starting with `[coder-unraid]` and `[coder-bootstrap]`.

## Settings

Essential fields are shown by default. Toggle **Advanced View** in the Unraid form for:

| Field | Env var | Notes |
|---|---|---|
| Wildcard Access URL | `CODER_WILDCARD_ACCESS_URL` | `*.coder.example.com`, needed for workspace web apps and port forwarding |
| PostgreSQL URL | `CODER_PG_CONNECTION_URL` | External Postgres 13+. Blank uses the built-in database in appdata |
| Telemetry, Update Check | `CODER_TELEMETRY_ENABLE`, `CODER_UPDATE_CHECK` | |
| Disable Password Auth | `CODER_DISABLE_PASSWORD_AUTH` | License automation needs password auth, keep false if you rely on it |
| OIDC | `CODER_OIDC_*` | Issuer URL, client id, client secret, allow signups |
| GitHub OAuth | `CODER_OAUTH2_GITHUB_*` | Client id, secret, allowed orgs, allow signups |
| TLS | `CODER_TLS_*` | In-container HTTPS on port 7443, certs mounted at `/certs` |
| STUN Servers | `CODER_DERP_SERVER_STUN_ADDRESSES` | |
| Prometheus | `CODER_PROMETHEUS_ENABLE` | Metrics on port 2112 |
| Provisioner Daemons | `CODER_PROVISIONER_DAEMONS` | Lower on small servers |
| Experiments, Log Filter | `CODER_EXPERIMENTS`, `CODER_LOG_FILTER` | |
| PUID / PGID | | Default 99 / 100 |

Any other `coder server` flag can be set by adding `-e CODER_...=value` to
**Extra Parameters**. See `coder server --help` or the
[server reference](https://coder.com/docs/reference/cli/server).

## How the license bootstrap works

On every start a background job waits for Coder to become healthy, then:

1. If no user exists yet, it creates the bootstrap admin.
2. If a license key is set, it logs in with the bootstrap admin password, reads the
   license id from the key, and uploads it only if that id is not already installed.

Consequences:

- If you change the admin password in the UI, update the template field too, or the
  job logs a warning and skips. The server itself is unaffected.
- If you set a license key but no admin credentials, the job logs a warning and you
  can add the key under **Admin settings > Deployment > Licenses**.
- Replacing the key with a renewed one installs the new license alongside the old one.
  Delete the expired one in the UI when convenient.

## Workspaces on Unraid

The starter **Docker** template in Coder works out of the box because the Unraid
docker socket is mounted into the container. Workspace containers appear in the
Unraid Docker tab as unmanaged containers. Make sure Access URL is an address those
containers can reach, which is why `localhost` is not allowed.

## Reverse proxy

Point your proxy at port 7080 with WebSocket support enabled, set Access URL to the
public `https://` address, and leave TLS Enable off. For workspace web apps also proxy
the wildcard hostname and set Wildcard Access URL.

## Appdata notes

The `/home/coder` mount holds the built-in PostgreSQL data in `.config/coderv2/postgres`
and the Terraform provider cache in `.cache/coder`. Set the appdata share to cache-only
or point the mount at `/mnt/cache/appdata/coder`. The embedded PostgreSQL is fine for a
home deployment but does not like FUSE paths, and Coder recommends an external database
for anything serious.
To move to an external database later, follow Coder's
[migration guide](https://coder.com/docs/admin/setup#postgresql-database).

## Building locally

```sh
docker build --build-arg CODER_VERSION=v2.36.7 -t coder-unraid:dev .
```

## Repository layout

- `Dockerfile`, `rootfs/` : the wrapper image.
- `templates/coder.xml` : the Unraid template.
- `.github/workflows/build.yml` : daily check for new Coder releases and multi-arch build.
