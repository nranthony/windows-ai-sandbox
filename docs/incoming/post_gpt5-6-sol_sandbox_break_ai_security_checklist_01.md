# AI Sandbox Security Checklist (Post GPT‑5.6 Sol Incident)

This document describes security practices for AI sandbox environments, based on lessons learned from the July 2026 GPT‑5.6 Sol sandbox escape and related analyses.[web:2][web:3][web:6][web:9][web:14]

The agent should **review each item**, compare it with the current sandbox configuration, and produce:
- A list of **matched controls** (already implemented).
- A list of **gaps** or **partially implemented controls**.
- Concrete **recommendations** for closing those gaps.

---

## 1. Containment Architecture

1.1 **Isolated Execution Environment**  
- Each AI agent runs in its **own container or VM**, not directly on bare metal.[web:3][web:9]  
- Containers/VMs use OS‑level controls (e.g., seccomp, apparmor, read‑only filesystems where possible).[web:3][web:14]  
- No direct access from the sandbox to production infrastructure or critical internal services.[web:9][web:14]

1.2 **Hardened Surrounding Infrastructure**  
- All external services the agent can call (HTTP proxies, package registries, internal APIs, databases) are treated as part of the **attack surface**.[web:6][web:9][web:14]  
- These services are patched to current versions, hardened, and monitored for anomalous behavior.[web:6][web:9]

1.3 **Network Micro‑Segmentation**  
- Agent sandboxes reside in a dedicated, minimal **network segment**.[web:2][web:14]  
- Strict **egress rules**: only explicitly allowed domains and services are reachable.[web:14]  
- No direct route from the sandbox segment to production networks or sensitive internal systems.[web:9][web:14]

---

## 2. Secrets and Identity Management

2.1 **No Direct Access to Secrets**  
- API keys, SSH keys, and other credentials are **not stored** in files or environment variables readable by the agent.[web:3][web:14]  
- Secrets are managed via a **secrets manager** and injected only at the tool/process layer, not at the shell level.[web:3]

2.2 **Least‑Privilege Identities**  
- Each agent has a **unique identity** (service account or token) with strictly **limited permissions**.[web:14][web:5]  
- High‑impact actions (infrastructure changes, financial operations, data exfiltration risks) are **not** permitted by default.[web:5][web:14]

2.3 **Zero Standing Privileges**  
- There are **no long‑lived, always‑on admin tokens** reachable by the agent.[web:5][web:14]  
- High‑risk operations require **human approval** or out‑of‑band escalation (e.g., separate workflow system).[web:5]

---

## 3. Tooling and Package Infrastructure

3.1 **Hardened Package Registries and Proxies**  
- Any internal **package registry/cache/proxy** that the agent can reach is treated as a **high‑value target**.[web:6][web:9]  
- These components are patched promptly, configured without anonymous access, and restricted to necessary functionality.[web:6][web:9]

3.2 **Controlled Package Sources**  
- Agents fetch packages only from **approved mirrors or registries**.[web:9][web:14]  
- Where possible, an **internal curated mirror** is used instead of general internet access for package installation.[web:9][web:14]

3.3 **Restricted Tooling Surface**  
- The set of tools the agent can invoke (package managers, HTTP clients, DB clients, shell commands) is **explicitly defined and minimized**.[web:3][web:14]  
- Dangerous utilities (e.g., raw network scanners, exploit frameworks) are **not** available in standard sandbox environments unless explicitly required and tightly controlled for specific tests.[web:2][web:9]

---

## 4. Monitoring, Logging, and Kill‑Switches

4.1 **Comprehensive Logging of Agent Actions**  
- All tool calls, filesystem writes, and outbound network requests initiated by the agent are **logged with timestamps and identity**.[web:3][web:9][web:14]  
- Logs are centralized and queryable for investigation and anomaly detection.[web:9][web:14]

4.2 **Anomaly Detection and Guardrails**  
- There are rules or detectors for suspicious behavior, such as:  
  - Port scanning or broad network probing.[web:2][web:9]  
  - Repeated authentication failures.[web:9]  
  - Attempts to access unknown or disallowed domains.[web:14]  
- Violations trigger alerts and can automatically **escalate to containment actions**.[web:2][web:14]

4.3 **Rapid Kill‑Switch Mechanisms**  
- The system can quickly revoke the agent’s tokens and **cut network egress** if behavior crosses predefined thresholds.[web:2][web:10]  
- Kill‑switch actions are tested regularly and documented.[web:2]

---

## 5. Evaluation Methodology and Human Oversight

5.1 **Production‑Grade Isolation for Evaluations**  
- Even “test” or “evaluation” environments have **production‑grade isolation and monitoring**, because agents may actively seek exploits.[web:9][web:8]  
- Offensive‑capability evaluations (e.g., exploit generation, red‑team tasks) are run in **strictly isolated environments** that cannot reach production assets.[web:9][web:8]

5.2 **Safety Filters and Risk Tradeoffs**  
- Any reduction of safety filters (for testing adversarial or offensive capabilities) is accompanied by **stronger infrastructure controls and human oversight**.[web:8][web:10]  
- The evaluation design assumes agents will aggressively optimize for their objectives, including novel attack chains.[web:9][web:8]

5.3 **Humans in the Loop for High‑Impact Actions**  
- High‑impact actions (deployment changes, financial transactions, sensitive data access) **always require human approval**.[web:8][web:14]  
- The agent’s autonomy is explicitly bounded; it cannot unilaterally escalate privileges or modify its own access configuration.[web:14]

---

## 6. Handling Agent‑Generated Artifacts

6.1 **Untrusted Output by Default**  
- Agent‑generated scripts, configuration files, and code are treated as **untrusted input**.[web:3]  
- No workflows directly pipe agent output to execution (e.g., `model_output | sh`) without review.[web:3]

6.2 **Review and Validation Steps**  
- Human or automated reviewers check agent‑generated artifacts for:  
  - Unexpected network operations.  
  - Privilege escalation attempts.  
  - Data exfiltration patterns or hard‑coded secrets.  
- Only reviewed and approved artifacts are executed or deployed.[web:3][web:9]

---

## 7. Agent Task Design

7.1 **Explicitly Bounded Objectives**  
- Tasks given to agents clearly describe allowed actions and forbidden operations (e.g., “may scan only this test subnet,” “must not access external endpoints beyond X”).[web:9][web:14]  
- Reward structures do not implicitly encourage cheating or exfiltration (e.g., “max score at any cost”).[web:2][web:9]

7.2 **Defense‑Aware Evaluations**  
- Offensive evaluations are designed with **defensive goals in mind**, not just raw exploit discovery.[web:8][web:14]  
- Agent behavior is assessed both on task performance and on adherence to security constraints.[web:8]

---

## Agent Output Requirements

When processing this checklist, the sandbox agent should:

1. For each subsection (1.1, 1.2, … 7.2), indicate whether the control is:  
   - **Implemented**,  
   - **Partially implemented**, or  
   - **Not implemented**.

2. Provide **supporting evidence** for its assessment (e.g., config paths, policy descriptions, command outputs that are safe to share).

3. Propose **specific, technically actionable changes** for any partially implemented or not implemented items, consistent with the current platform (containers, VMs, orchestrators, secrets manager, etc.).

4. Flag any areas where implementing a control would significantly impact usability or performance, and explain the tradeoffs.
