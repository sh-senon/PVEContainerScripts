# Obsi project tracker

Last reviewed: 2026-10-21. This is the living source of truth for our Obsi project. Update after every implementation or testing session. Use DONE only for confirmed working behavior, IMPLEMENTED for code committed but not fully tested, and TODO for unfinished work.

## Goal

Build a reliable shared IT knowledge assistant in Open WebUI, primarily for professional Work operations and also for Homelab. Two separate users should have consistent answers from the same permitted Markdown knowledge vault. Obsi should document systems, screenshots, troubleshooting, changes, incidents, dependencies, and verified solutions. It should answer historical questions with evidence and mark uncertainty honestly.

## Key decisions

- Canonical knowledge areas: Work/ and Homelab/. Legacy Infrastructure/ notes are redirects.
- Both intended users may read Homelab. Professional Work documentation requires organizational authorization and approved model data processing.
- New notes may be created automatically after checking for duplicates. Changes to existing notes require an approval dialog and full diff.
- Technical notes and screenshots are historical evidence, not necessarily live verification.
- Unverified hypotheses and attempted fixes must not be described as confirmed resolutions.
- Enforce future multiuser permissions in the backend, not only in a prompt.
- Protect secrets, credentials and confidential company information.

## Implementation references

Repository: https://github.com/sh-senon/PVEContainerScripts

Sources:
- scripts/obsi-hybrid-tool.py (latest committed version at initial review: 1.9.2)
- scripts/obsi-write-server.py
- scripts/obsi_audit.py
- scripts/obsi_relationships.py
- scripts/obsi_incidents.py
- templates/obsi-work-incident.md

Architecture: Open WebUI UI plus MCP knowledge retrieval, an authenticated note-writing service, and a persistent Markdown vault on network storage. Deployed revisions must be checked independently of GitHub commits. The complete canonical system prompt should be added to version control.

## Confirmed working

- Search, list and read Homelab Markdown notes.
- Create notes and request explicit approval before replacing existing notes.
- Screenshot capture and retrieval; external visual analysis implemented with consent requirement.
- Read-only vault auditor and approved cleanup of ambiguous Homelab links.
- Read-only relationship discovery (existing links and conservative candidate matching).
- Read-only environment-scoped keyword incident search.
- Create fictional incident in Homelab.
- Repair a legacy incident note damaged by literal backslash-n formatting.
- Record investigation progress on repaired note using approval, with verified note read afterward.

## Implemented but not fully tested

- Incident tool version 1.9.2 corrected newline generation for future incident creation and updates; fresh-note regression test pending.
- Incident resolution with verification and approval dialog; live end-to-end test pending.
- Work incident note template.

## Known defects and limitations

- Progress appends leave stale placeholder text and poorly format multiline observations and unspecified dates.
- Fictional test incidents currently appear in normal incident searches. Add test-data true metadata and exclude tests by default.
- An earlier tool version serialized actual line breaks as literal backslash-n; repair only legacy affected files. Obsi's old memory recommending repair after every new incident must be corrected.
- Incident matching is keyword-based, not semantic. Relationship discovery is title/link-based, not verified live dependencies.
- Earlier code commits had regex and newline bugs; introduce automated tests before further rollout.
- The colleague's Obsi account could not retrieve a fact available to the original user; root cause unknown. Possible model/tool access configuration difference, not confirmed.
- Work knowledge base currently unpopulated. Work security and external AI data handling need approval.
- Two legacy redirect notes remain; no authorized deletion.
- Repository commits do not prove the corresponding version is deployed.

## Roadmap (in priority order)

### P0: Stabilize lifecycle
- [ ] Fix investigation formatting, placeholders, multiline entries, timestamps.
- [ ] Mark fictional incidents and exclude them from normal searches; opt-in search for test records.
- [ ] Run complete new incident, progress, resolution and verification tests.
- [ ] Add syntax, regression, integration and approval tests.
- [ ] Write deployment, version validation and rollback procedure.

### P1: Multiuser shared knowledge
- [ ] Test same Obsi model with two Open WebUI accounts in clean sessions.
- [ ] Check access to MCP knowledge tools, Python tool, permissions and note retrieval for both.
- [ ] Make shared read and write workflows consistent.
- [ ] Track author/approver identity and preserve concurrent edit protections.
- [ ] Both may access Homelab; Work access requires company authorization.

### P2: Incident and solution intelligence
- [ ] Semantic search for similar symptoms with evidence and citations to notes.
- [ ] Prioritize real verified fixes; never contaminate retrieval with fictional examples.
- [ ] Recurrence detection, incident-to-system links, reopening, change history.
- [ ] Improve recording of troubleshooting during ordinary chat.

### P2a: Web-assisted troubleshooting (proposed, not implemented)
- [ ] Search permitted internal KB and incident history first, ranking verified fixes and relevant systems.
- [ ] When local evidence is insufficient, research current official vendor documentation and selected credible external sources with links and retrieval dates.
- [ ] Minimize external queries: never send internal hostnames, user identifiers, tenant IDs, confidential error details or screenshots to external search without explicit authorization.
- [ ] Start or continue a scoped incident, recording symptoms, diagnostic evidence, attempted steps and observed outcomes. Avoid unnecessary duplicate tickets.
- [ ] If a step fails, re-evaluate assumptions, check for contradictory/outdated internal notes, consult new sources, and ask focused follow-up questions.
- [ ] Do not automatically overwrite shared KB procedures because one user had a different outcome; propose an evidence-backed correction with approval.
- [ ] On resolution, record the exact action and actual successful verification, then link to systems, vendor sources and prior incidents.
- [ ] Provide human approval for note edits and any production-changing actions; normal internet browsing can be automated within safe data boundaries.
- [ ] Allow both users to retrieve newly verified solutions from shared knowledge, not private chat context alone.
- [ ] Choose web tool/integration and test permissions, external processing and source reliability before deployment.

### P3: Knowledge intelligence
- [ ] Evidence-backed service dependency mapping.
- [ ] Freshness and verification tracking, conflict detection.
- [ ] Smarter audits with expected exceptions and meaningful priorities.
- [ ] Runbooks, systems, service hubs, backups and recovery documentation.
- [ ] Visual graph and dashboards are lower priority.

### P4: Production Work readiness (security work runs in parallel)
- [ ] Approve AI processing arrangement for confidential Work information.
- [ ] Backend authorization and accountable edits for multiple users.
- [ ] Guard secrets and personal data; define retention and incident logging.
- [ ] Verified vault backup and restore.
- [ ] Controlled Work documentation import, handover and operations guide.

### P3a: Automated specialist agents (proposed, not built)
- [ ] Knowledge Guardian: scheduled read-only vault audit and freshness report (daily).
- [ ] Incident Detective: detect similar/repeated incidents and unverified solutions (event-triggered or daily), excluding test data.
- [ ] Dependency Mapper: suggest evidence-backed service relationships, never assert mere co-occurrence as dependencies (weekly).
- [ ] Change Reviewer: review a proposed diff for lost facts, unsupported edits or security leakage; does not replace human approval.
- [ ] Start with deterministic scheduled Python jobs and stored review reports; add LLM analysis only when useful and authorized.
- [ ] Provide job ownership, logs, error handling, deduplication, resource budgets, monitoring and manual disable switches.
- [ ] Enforce per-environment authorization and keep confidential Work data on an approved inference path.
- [ ] No autonomous note edits or infrastructure changes; user approval remains mandatory.

## Next actions

First fix test incident handling and formatting; then test complete incident closure. Next diagnose shared knowledge access for the colleague. Then advance semantic retrieval and dependency mapping. Plan Work security before importing sensitive company material.

## Change log

2026-10-21: Added planned KB-first web-assisted troubleshooting and adaptive incident learning workflow; not yet implemented.

2026-10-21: Proposed read-only specialist agents and their security/operational safeguards; not implemented.

2026-10-21: Tracker established from existing project discussions and observed tests.

## Update instructions

After every Obsi task, record new decisions, code commit, deployed version (if independently checked), test outcome, remaining blockers and next actions. Never claim a commit is deployed or a workflow tested unless confirmed. Keep this document free of credentials and confidential operational details.
