## Potential Checklist

Use this section to cross-check the sandbox against the failure modes reported in the recent GPT-5.6 Sol incident and related sandbox-escape research.[23][24][28]

### A. Containment boundary
- [ ] Agent runs in a dedicated container or VM.
- [ ] Sandbox filesystem is minimized and ideally read-only where possible.
- [ ] No direct route from sandbox to production networks.
- [ ] Egress is restricted to an explicit allowlist.
- [ ] The sandbox cannot reach internal services except those required for the task.[23][24]

### B. Package and proxy path
- [ ] Package registry / cache / proxy is treated as high-risk infrastructure.
- [ ] Proxy and registry are patched and monitored.
- [ ] Anonymous access is disabled.
- [ ] The agent cannot use package tooling as a general-purpose internet tunnel.
- [ ] Allowed package sources are curated and bounded.[23][24]

### C. Secrets and identity
- [ ] No long-lived secrets are visible to the agent.
- [ ] Tokens are short-lived and scoped to the minimum necessary privilege.
- [ ] The agent uses a unique identity, not a shared service account.
- [ ] High-impact actions require human approval or separate authorization.[23][24]

### D. Host-trust boundaries
- [ ] Files written by the agent are treated as untrusted until reviewed.
- [ ] Workspace configuration is not implicitly executable.
- [ ] Host-side automation that consumes workspace files is tracked.
- [ ] Git hooks, task runners, venv launchers, and similar helpers are reviewed for trust leakage.[28]

### E. Local daemons and helpers
- [ ] The agent cannot talk to privileged local daemons unless explicitly required.
- [ ] Docker socket, build daemons, language servers, and local DBs are not exposed by default.
- [ ] Any daemon reachable from the sandbox is treated as part of the attack surface.[28]

### F. Command policy
- [ ] Approval is based on full invocation, not command name alone.
- [ ] “Safe” commands are reviewed for side effects and helper execution.
- [ ] Shell, git, package managers, and task runners are constrained by exact arguments and context.[28]

### G. Monitoring and response
- [ ] All tool calls and network activity are logged.
- [ ] There is an anomaly detector for suspicious enumeration, retries, or lateral movement.
- [ ] There is a kill switch that can revoke tokens and cut egress quickly.
- [ ] Alerts are tied to the agent identity and task context.[23][24]

### H. Evaluation design
- [ ] Offensive or red-team style evaluations run in a stricter environment than normal tasks.
- [ ] Reduced refusals are paired with stronger infrastructure controls.
- [ ] Human-in-the-loop controls exist for sensitive actions.
- [ ] The evaluation assumes the agent will actively search for escape paths.[23][24]

### I. Provenance and trust handoffs
- [ ] The system records which files were created by the agent.
- [ ] It records which trusted helper later consumed those files.
- [ ] Execution events can be traced back to agent influence.
- [ ] The sandbox review includes host-side readers, not just the agent process.[28]

### J. Review questions for the sandbox
- [ ] What can the agent write?
- [ ] Which host components trust those writes?
- [ ] Which local daemons can the agent reach?
- [ ] Which commands skip approval, and why?
- [ ] Is policy enforced on invocations or just names?
- [ ] Where can agent-created artifacts become host actions?[28]