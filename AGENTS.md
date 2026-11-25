## Active session queue handling

For Autopilot work, read the installed `wingman-sessions` skill; for Flight Deck tasks or supervised dispatch also read `flight-deck-workflow` and its dispatch reference before updates/briefs. Local entrypoints: `/Users/mini/.codex/skills/wingman-sessions/SKILL.md` and `/Users/mini/.codex/skills/flight-deck-workflow/SKILL.md`; use the harness’s installed equivalents when available.

Check your own queue before starting, at milestones/decisions, validation and handoff: `bun /Users/mini/code/wm/autopilot/clis/wingman.ts session queue list`. Read complete items and referenced authoritative records. Immediately consume only exact revisions incorporated into context/plan with `session queue consume <id> --revision <read-revision> --reason <incorporation-reason>`. Consumption is not completion: retain unfinished obligations on the task/plan; leave unrelated/unincorporated/newer items pending. If consume is denied, use the skill’s verified alias-compatible acknowledge fallback and report the gap. Preserve conflict and uncertain-delivery safeguards; never clear blindly or consume merely to suppress turns.

Every worker brief includes manager session ID, Autopilot location/connection, exact supported communication command and task/report destination. Workers ask questions; managers retain worker IDs, check their own queue and worker progress, and answer the exact worker. Use authorized `bun <autopilot-checkout>/clis/sessions.ts send <target-session-id> "<worker session/task; decision; recommendation; blocking status>" --bot-crypto --json`; queue-add only when specifically authorized. Sending may queue while busy; no immediate interrupt guarantee. Continue independent work while awaiting answers and pause dependent decisions.

Own queue management never authorizes consuming another session’s queue. Callback inboxes remain separate: review evidence and follow up, then acknowledge/close only reviewed callbacks. No runtime injection, scope bypass or background polling is implied; recheck before handoff.

<!-- post-work-cleanup:v1 -->
## Build, simulator and test cleanup

Before declaring build/test work complete, remove the disposable outputs created by the task: temporary build trees, test results, simulator clones, emulator snapshots and scratch downloads. Shut down task-owned test devices and processes when finished. Preserve source, signing material, release deliverables, required evidence, installed user data and anything used by concurrent work. Check ownership and active processes before deleting shared caches or devices; use supported simulator/emulator tooling. Measure disk space before and after cleanup and report what was reclaimed, what remains and why. Cleanup is part of completion; workers must include it in their handoff. Retain large caches or test environments only with an explicit reason and a cleanup owner/time.
<!-- /post-work-cleanup:v1 -->
