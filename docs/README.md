# Documentation index

Every document lives under `docs/`. Each file stays small and links to its neighbours; start from the entry for your question and follow links only as far as you need.

For product work, start with [PRODUCT.md](PRODUCT.md) for the big picture and [ROADMAP.md](ROADMAP.md) for the one current delivery, its acceptance and the next action. Dated maps and research support those two entries; their dates do not set priority.

Three kinds of document, and how to treat them:

- **Current** — describes the code and product as they are now. Must be updated in the same change that makes it wrong (see the documentation sync rule in [`AGENTS.md`](../AGENTS.md)).
- **Dated contract** — a working contract with a date in its name; its contract sections are maintained, its evidence sections are append-only.
- **Frozen record** — what happened on that day. Never rewritten; when a fact expires, write the correct version in a current document and say what it supersedes. Details: [development/README.md](development/README.md).

## Product and direction (current)

| Document | Answers |
| --- | --- |
| [PRODUCT.md](PRODUCT.md) | Who she is, the value function, decided directions |
| [ROADMAP.md](ROADMAP.md) | Single current delivery/status entry, product management rules, candidates and stage exit criteria |
| [lineage.md](lineage.md) | Frozen predecessor repositories and what to port from them |
| [terminology.md](terminology.md) | The one name for each stage, metric and component |
| [research/incredible-reconstruction.md](research/incredible-reconstruction.md) | Competitor architecture evidence with confidence levels |
| [research/decision-layer-comparison.md](research/decision-layer-comparison.md) | JEV vs local Cua-S1-4B as the decision layer; evidence for stage 7 |
| [research/delegation-references.md](research/delegation-references.md) | How open-source projects hand work to Claude Code / Codex; evidence for Stage 4 decisions |
| [research/full-duplex-echo.md](research/full-duplex-echo.md) | 全双工还是半双工：ChatGPT、Gemini、LiveKit、Pipecat、Samuel 怎么处理「听见自己」，以及 Her 的选项 |
| [research/2026-09-27-architecture-from-references.md](research/2026-09-27-architecture-from-references.md) | 方案（未批准）：从 openhanako、CowAgent 源码学到的六条架构改造，以及顺带查出的 Her 现有缺陷 |
| [design-references.md](design-references.md) | Where UI design references come from |
| [design/her-continuity-interaction.md](design/her-continuity-interaction.md) | Interaction prototype: quiet updates while away, preserved context on return, and explicit simulation boundaries |

## How the app works (current)

| Document | Answers |
| --- | --- |
| [architecture/README.md](architecture/README.md) | System overview and map of the architecture documents |
| [architecture/provider-modes.md](architecture/provider-modes.md) | StepFun voice, JEV text; onboarding; voice defaults |
| [architecture/runtime.md](architecture/runtime.md) | Engine boundaries, grounding, perception, open_app, describe_screen |
| [architecture/step-completion.md](architecture/step-completion.md) | The code-owned rule for when a step counts as done |
| [architecture/task-continuity.md](architecture/task-continuity.md) | The off-by-default task continuity path |
| [architecture/key-files.md](architecture/key-files.md) | Key source files, purpose and approximate size |
| [source-layout.md](source-layout.md) | Directory responsibilities |
| [tiptour-agent-contract.md](tiptour-agent-contract.md) | Localhost harness on `127.0.0.1:19474` |

## Working on it (current)

| Document | Answers |
| --- | --- |
| [guides/build-and-verification.md](guides/build-and-verification.md) | Building in Xcode, isolated test suites, what counts as evidence |
| [guides/acceptance.md](guides/acceptance.md) | Real-user-path acceptance infrastructure |
| [guides/code-style.md](guides/code-style.md) | Naming, clarity and Swift/SwiftUI conventions |
| [local-development.md](local-development.md) | Signing, bundle identifier, Sparkle feed, remotes |
| [tools/voice-acceptance.md](tools/voice-acceptance.md) | Fixture page and DEBUG probe launch arguments |
| [tools/acceptance-runner.md](tools/acceptance-runner.md) | `scripts/acceptance/` runner, reviewer and evidence layout |
| [tools/acceptance-cassettes.md](tools/acceptance-cassettes.md) | Replay cassettes (never acceptance) |
| [tools/cua-host.md](tools/cua-host.md) | Controlled desktop host app |
| [tools/stepprobe.md](tools/stepprobe.md) | StepFun API probes |
| [tools/scripts.md](tools/scripts.md) | Release and helper scripts in `scripts/` |

## Dated contracts and records

| Document | Kind |
| --- | --- |
| [development/README.md](development/README.md) | Classification of every file in `development/` |
| [research/2026-09-26-today-incredible-experience.md](research/2026-09-26-today-incredible-experience.md) | Dated research: Today live recall tests, Incredible installation and design sources, with verification limits |
| [research/2026-09-26-coordination-architecture.md](research/2026-09-26-coordination-architecture.md) | Dated research: Grok Bot, Today, Incredible, OpenMausBot and OpenMuse; coordination mechanisms, source provenance and Her-specific tradeoffs |
| [research/2026-09-26-today-proactivity.md](research/2026-09-26-today-proactivity.md) | Dated research: actual proactive messages, official claims, a factual counterexample and Her-specific proposals |
| [research/2026-09-28-interest-discovery.md](research/2026-09-28-interest-discovery.md) | 3.2 设计：从 Claude Code、Codex、git、Obsidian 看出「你在意的方向」，每条带出处；材料实测、做法、验收和待定的外发授权 |
| [research/2026-09-26-open-connector-pilot.md](research/2026-09-26-open-connector-pilot.md) | Live pilot: GitHub HTTP/MCP reads and write denial verified; temporary credential cleanup; Notion awaiting its own page-scoped authorization |
| [development/2026-09-25-claude-code-delegation-map.md](development/2026-09-25-claude-code-delegation-map.md) | Stage 4 detailed contract and evidence; current scheduling belongs to ROADMAP.md |
| [development/2026-09-25-listen-and-baseline-map.md](development/2026-09-25-listen-and-baseline-map.md) | Dated contract: parked map — Her hears you, then the first failure list from the acceptance tasks |
| [development/2026-09-25-product-definition-map.md](development/2026-09-25-product-definition-map.md) | Frozen product-definition decisions; current direction is PRODUCT.md, current delivery is ROADMAP.md |
| [development/2026-09-23-first-run-and-interface.md](development/2026-09-23-first-run-and-interface.md) | Dated contract: stage 3, first-run guidance and interface design |
| [development/2026-09-23-voice-conversation-quality.md](development/2026-09-23-voice-conversation-quality.md) | Dated contract: stage 2, voice conversation quality, with evidence |
| [development/2026-09-23-acceptance-infrastructure.md](development/2026-09-23-acceptance-infrastructure.md) | Dated contract: acceptance infrastructure |
| [development/2026-09-22-voice-task-lifecycle.md](development/2026-09-22-voice-task-lifecycle.md) | Dated contract: long-running voice task lifecycle |
| [development/2026-09-21-trustworthy-desktop-control.md](development/2026-09-21-trustworthy-desktop-control.md) | Dated contract: trustworthy desktop control |
| [development/2026-09-21-open-app-1349-postmortem.md](development/2026-09-21-open-app-1349-postmortem.md) | Frozen record |
| [development/2026-09-21-realtime-voice-continuity.md](development/2026-09-21-realtime-voice-continuity.md) | Frozen record |
| [development/2026-09-21-decision-packet-fanout.md](development/2026-09-21-decision-packet-fanout.md) | Frozen record |
| [development/2026-09-20-desktop-companion-acceptance.md](development/2026-09-20-desktop-companion-acceptance.md) | Frozen record |
| [development/2026-09-20-voice-audio-format.md](development/2026-09-20-voice-audio-format.md) | Frozen record |
| [development/2026-09-20-voice-click.md](development/2026-09-20-voice-click.md) | Frozen record |
| [development/2026-09-20-voice-rebuild.md](development/2026-09-20-voice-rebuild.md) | Frozen record |
| [tasks/2026-09-23-her-parallel-gates/README.md](tasks/2026-09-23-her-parallel-gates/README.md) | Dated work orders for the parallel acceptance gates: [00-freeze-baseline](tasks/2026-09-23-her-parallel-gates/00-freeze-baseline.md) · [01-voice-multistep-intent](tasks/2026-09-23-her-parallel-gates/01-voice-multistep-intent.md) · [01R-sequence-contract](tasks/2026-09-23-her-parallel-gates/01R-sequence-contract.md) · [02-progress-evidence-language](tasks/2026-09-23-her-parallel-gates/02-progress-evidence-language.md) · [03-her-e2e-runner](tasks/2026-09-23-her-parallel-gates/03-her-e2e-runner.md) · [03R-runner-preconditions](tasks/2026-09-23-her-parallel-gates/03R-runner-preconditions.md) · [04-unknown-recovery-e2e](tasks/2026-09-23-her-parallel-gates/04-unknown-recovery-e2e.md) · [05-contract-docs-truth](tasks/2026-09-23-her-parallel-gates/05-contract-docs-truth.md) · [06-keychain-error-reconciliation](tasks/2026-09-23-her-parallel-gates/06-keychain-error-reconciliation.md) · [06R-key-state-ui](tasks/2026-09-23-her-parallel-gates/06R-key-state-ui.md) · [07-unified-task-authority](tasks/2026-09-23-her-parallel-gates/07-unified-task-authority.md) · [08-diagnostic-identity](tasks/2026-09-23-her-parallel-gates/08-diagnostic-identity.md) · [INTEGRATION-RECHECK](tasks/2026-09-23-her-parallel-gates/INTEGRATION-RECHECK.md) |
| [desktop-companion-plan.md](desktop-companion-plan.md) | Frozen record: 2026-09-20 plan; interaction rules still referenced by `PRODUCT.md` |
| [model-research-findings.md](model-research-findings.md) | Frozen record: 2026-09-20 model probes, with a correction note |
| [voice-rebuild-acceptance.md](voice-rebuild-acceptance.md) | Frozen record: voice rebuild acceptance |

Raw evidence files under `development/evidence/` and run outputs under `out/` (git-ignored) are not documents and are not indexed here.
