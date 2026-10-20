# security-audit

A reusable GitHub Actions workflow that audits a repository for what
Dependabot does not cover.

| Check | Tool | On a finding |
|---|---|---|
| Secrets in the checked-out tree | gitleaks 8.30.1 (`dir`) | **fails the job** |
| Secrets in git history | gitleaks 8.30.1 (`git`) | reported in the run summary |
| Locked Python dependencies | pip-audit 2.10.1 (from `uv.lock`, else `requirements.txt`) | reported |
| Python code, high severity | bandit 1.9.4 | reported |

gitleaks runs with `--redact`: logs and the summary show the rule, file and
line, never the value. The gitleaks binary is downloaded from its release and
checked against a pinned SHA-256; actions are pinned by commit.

## Use

```yaml
# .github/workflows/security-audit.yml
name: Security audit
on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: "17 5 * * 1"
  workflow_dispatch:
permissions:
  contents: read
jobs:
  audit:
    uses: bartoszkobylinski/security-audit/.github/workflows/audit.yml@<commit sha>
    with:
      runner: '"ubuntu-latest"'        # private repos: '["self-hosted","macOS","<label>"]'
```

Inputs: `runner` (JSON for `runs-on`), `timeout` (minutes, default 20),
`bandit-paths` (default `src`), `requirements-file` (default
`requirements.txt`), `scan-history` (default `true`).

This repository is public because a public repository cannot call a reusable
workflow that lives in a private one. Nothing in it is confidential.
