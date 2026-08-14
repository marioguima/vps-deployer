# Security model

`vps-deployer` is intentionally small, but it is a network-triggered deployment system and must be treated as privileged infrastructure.

## Trust boundary

The HTTP payload never becomes a shell command. A webhook can only select an exact `repository + branch` entry already present in `/etc/vps-deployer/projects.json`. The executable and its arguments come exclusively from that root-managed registry.

Every webhook must use a strong secret. The receiver validates the raw request body using `X-Hub-Signature-256` and HMAC-SHA256 with a constant-time comparison before parsing or queuing it.

`X-GitHub-Delivery` is unique in the local SQLite database, so a redelivery with the same delivery ID is idempotent.

## Service account

The service runs as `vps-deployer`, not root. The installer adds that user to the `docker` group only if Docker exists. **Docker group membership is effectively root-equivalent** and should be treated accordingly.

If a project deployment needs `systemctl`, Nginx, Certbot, or another privileged operation, prefer a narrow sudoers rule for the exact command rather than giving the service unrestricted sudo.

## Network

Recommended mode:

- receiver binds only to `127.0.0.1:9100`;
- Nginx exposes `/github` and `/health` over HTTPS;
- use a valid certificate for the public IP;
- expose only ports 80/443 externally.

Emergency/bootstrap mode can bind directly to `0.0.0.0:9100` over HTTP. HMAC still protects authenticity/integrity of accepted GitHub payloads, but HTTP exposes metadata and is vulnerable to network-level interference. Do not keep this mode longer than necessary.

## Repository credentials

The deployer does not store GitHub API credentials. Project scripts normally use Git/SSH. Use the narrowest credential practical for your environment and keep private keys outside the repository.
