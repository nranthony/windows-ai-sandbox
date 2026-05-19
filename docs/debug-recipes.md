# Debug recipes

Routine commands for operating a profile. Non-obvious gotchas live in `../CLAUDE.md`.

```bash
# Force recreate (covers compose/seccomp/mount changes)
scripts/profile.sh <p> recreate

# Full rebuild + recreate (covers Dockerfile changes)
scripts/profile.sh <p> rebuild

# Blank-slate a profile but KEEP auth (claude creds + claude.json + gh + glab +
# git identity + gemini oauth + db.env). Tears down containers, nukes everything
# else under profiles/<p>/, then re-seeds settings.json + skills from config/.
# DB volumes (postgres-data/mongo-data) are preserved unless --all-volumes.
scripts/profile.sh <p> wipe --dry-run
scripts/profile.sh <p> wipe                    # interactive confirm
scripts/profile.sh <p> wipe --yes              # skip prompt
scripts/profile.sh <p> wipe --all-volumes      # also drop DB named volumes

# Recreate only (covers seccomp / mounts / env / squid.conf changes)
PROFILE=<p> COMPOSE_PROJECT_NAME=ai-sandbox-<p> docker compose up -d --force-recreate

# Proxy reload (covers allowed_domains.txt) — per profile
docker exec egress-proxy-<p> squid -k reconfigure

# Probe gitstatusd / zsh init with a TTY
docker exec -t ai-sandbox-<p> zsh -ic 'echo ok'

# Verify a domain reaches through the proxy
scripts/profile.sh <p> exec curl -sI https://<host>/ -o /dev/null -w '%{http_code}\n'

# Tail Squid access log (forensic trail of every proxy request)
docker exec -u proxy egress-proxy-<p> tail -f /var/log/squid/access.log

# In-container hardening sweep (streamed via stdin)
scripts/profile.sh <p> verify

# Tier 2 structured audit (~80 probes, JSON output)
scripts/profile.sh <p> audit

# Trivy scan (host-side, requires trivy installed)
scripts/trivy-scan.sh                    # all three (default)
scripts/trivy-scan.sh config             # Dockerfile/compose misconfig only
scripts/trivy-scan.sh image              # CVE scan of windows-ai-sandbox:latest

# DB reset (wipe postgres data volume, fresh initdb)
scripts/profile.sh <p> db-reset

# Stage sandbox config into a profile workspace for in-container audit
scripts/stage-audit-package.sh <p>              # stage /workspace/temp_audit_package/
scripts/stage-audit-package.sh <p> --clean      # remove when done
```

Accepted CVEs/misconfigs live in `../.trivyignore.yaml` with dated `expired_at` fields — on each expiry, re-run Trivy, and either delete the entry (upstream fixed it) or extend the date with a refreshed statement.
