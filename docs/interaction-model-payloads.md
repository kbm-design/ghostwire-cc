# Interaction Model — hook payload schema note (GW-318)

Answers §9 of the [Ghostwire Interaction Model spec][spec]. Everything below was
captured from **live Claude Code sessions**, not inferred: 11 driven runs against
`claude 2.1.220` on a real PTY, plus a scan of 135 transcripts / 203 Codex rollouts
on disk. Verified 2026-07-28.

[spec]: https://linear.app/ghostwire/document/ghostwire-interaction-model-spec-066e1def9f4b

> **Headline:** a hook **can** answer both `AskUserQuestion` and `ExitPlanMode`
> directly — no keystroke injection needed for States B and C. Which hook event we
> gate on decides whether there is a race at all.

---

## 1. `AskUserQuestion` — `tool_input` (State B)

Verbatim from a live `PreToolUse`:

```json
{
  "questions": [
    {
      "question": "Do you prefer tabs or spaces for indentation?",
      "header": "Indentation",
      "options": [
        { "label": "Tabs",   "description": "Indent with tab characters — width is set by each reader's editor." },
        { "label": "Spaces", "description": "Indent with space characters — identical width everywhere." }
      ],
      "multiSelect": false
    }
  ]
}
```

Shape confirmed across **96 historical calls**:

| Field | Type | Notes |
| -- | -- | -- |
| `questions` | array | **1–4** per call (1: 63×, 2: 27×, 3: 4×, 4: 2×). The renderer must handle a multi-question call — it is not rare. |
| `questions[].question` | string | Render verbatim. |
| `questions[].header` | string | Short chip label (≤12 chars in practice). |
| `questions[].multiSelect` | bool | Always present. `true` in 10/137 questions. |
| `questions[].options` | array | **2–4** options (3: 80×, 4: 35×, 2: 22×). |
| `options[].label` | string | Chip text. |
| `options[].description` | string | Always present. |
| `options[].preview` | string | **Optional, newer** — present on 70/424 options. Monospace preview body (mockups, code). Not in the spec; the renderer needs a plan for it. |

### The answer as Claude records it

`toolUseResult` = `{questions:[…], answers:{…}, annotations?:{…}}`, where **`answers`
is keyed by the question *text*** and the value is a **free-form string**, not an
option label:

```json
"answers": { "What do you want this trading folder to be for?":
             "combination between 1 and 2 i think? probalby start with 1 not bot yet" }
```

This matters: the TUI always offers a **"Type something"** free-text row alongside
the options, so an answer is frequently *not* one of the labels. A chips-only
Choice renderer would be strictly less capable than the terminal. Ship the
free-text escape hatch with the chips.

---

## 2. `ExitPlanMode` — `tool_input` (State C)

```json
{
  "plan": "# Add a README\n\n**Context:** …",
  "planFilePath": "/Users/…/.claude/plans/drifting-sauteeing-quiche.md",
  "allowedPrompts": [
    { "tool": "Bash", "prompt": "create directories and files under trading-desk/" }
  ]
}
```

| Field | Notes |
| -- | -- |
| `plan` | Markdown. Render with `MarkdownRenderer`, never truncate. |
| `planFilePath` | Always present. The plan is **also written to disk** — the notch can read the file instead of re-rendering a huge payload, and it survives the turn. |
| `allowedPrompts` | **Optional (5/6 historical), not in the spec.** A list of `{tool, prompt}` the model wants pre-authorized as part of accepting. Accepting a plan is therefore *also* a batch permission grant — the Plan-review UI must show these, or the user is silently approving commands they were never shown. Treat as a required render element. |

`ExitPlanMode` result: `{plan, filePath, isAgent, planWasEdited}` — note
`planWasEdited`, i.e. the terminal lets the user edit the plan before accepting.

---

## 3. Which hook fires — and the race (the key finding)

Live event sequences, one line per hook invocation:

**`AskUserQuestion`** — both events fire, ~same second:
```
21:06:37  PreToolUse         AskUserQuestion   (has tool_use_id)
21:06:37  PermissionRequest  AskUserQuestion   (NO tool_use_id)
21:06:43  Notification       permission_prompt
```

**`ExitPlanMode`** — same:
```
21:17:53  PreToolUse         ExitPlanMode      permission_mode=plan
21:17:54  PermissionRequest  ExitPlanMode
21:17:59  Notification       permission_prompt
```

So **`PermissionRequest` fires for both** — State B and State C can ride the
*existing* held-socket verdict channel (`HookSocketServer`) with no new plumbing.

But the two gate points behave differently, and this is the decision:

| Gate | Terminal menu while notch holds? | Race? | Cost |
| -- | -- | -- | -- |
| **`PreToolUse`** | **No.** Held 25s → menu did not render until release. | **None** — the terminal is never offered the question. | Terminal user sees only a spinner; needs a new blocking path + long timeout. |
| **`PermissionRequest`** | **Yes.** Held 30s → menu rendered ~6s in, while the hook was still held. | **Real** — both channels live, needs §5 invalidation. | Reuses State A's socket as-is. |

Evidence for the `PreToolUse` row: with a 25s hold, `PermissionRequest` did not
fire until the hold released — the whole permission flow is suspended behind it.

**Recommendation:** gate States B and C at **`PermissionRequest`** and build the
§5 invalidation properly. Reasons: it reuses shipped infrastructure; it keeps the
terminal fully usable (a notch that is closed or crashed never locks the user out
of their own agent); and the race is already a solved problem for State A. Gating
at `PreToolUse` buys race-freedom by making the notch a single point of failure
for the terminal — the wrong trade for a companion app.

### Answering from the hook — both work

Confirmed by live runs. Both produce a clean answer with **no keystrokes**:

- **`PreToolUse`** → `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<answer>"}}`
  The model received `Error: The user answered in Ghostwire: Option B (Spaces).`
  and replied "You answered spaces." The menu never rendered.
- **`PermissionRequest`** → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"<answer>"}}}`
  Model replied "Your answer was Spaces." — **this is the existing channel**, so
  State B needs a renderer and a message format, not new transport.

Caveats:
1. The answer arrives at the model as an **`Error:`/denial**, not as a native tool
   result. Semantically fine (the model consumes and continues), cosmetically a
   wart in the terminal transcript. There is **no** hook field that supplies a real
   tool result — `PreToolUse` offers only `allow|deny|ask|defer` +
   `permissionDecisionReason` + `updatedInput`; `PermissionRequest` only
   `behavior` + `updatedInput` + `rule` ([docs][hooks]).
2. **The message must be one-shot per `tool_use_id`.** In a run where the same deny
   message was returned to three consecutive gates, the model noticed and called it
   out: *"the Ghostwire review channel is replaying stale feedback, not new
   revisions from you."* Re-sending a stale answer is a visible, model-detectable
   bug — bind each answer to its `tool_use_id` and never replay.

[hooks]: https://code.claude.com/docs/en/hooks

### Plan revise (§9 Q2) — works

Denying `ExitPlanMode` with feedback text keeps the session in plan mode
(`permission_mode` stayed `plan`) and the model revised the plan and re-presented
it via a second `ExitPlanMode` — the Accept/Revise affordance is implementable
exactly as specced. B and C can also interleave inside one turn: the same run
produced `ExitPlanMode → AskUserQuestion → Edit → ExitPlanMode`.

---

## 4. The TUI menu contract (§9 Q5) — for the fallback tier only

Single-select renders as:
```
❯ 1. Tabs            Indent with tab characters.
  2. Spaces          Indent with space characters.
  3. Type something.
  4. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
```

Multi-select renders **checkboxes plus an explicit `Submit` row** — *not* the
space+enter the spec guessed:
```
❯ 1. [] Swift   2. [] Python   3. [] Rust   4. [] Go   5. [] Type something
  Submit                                    6. Chat about this
```

- **Number keys do select.** Sending `2` chose "Spaces" (`PostToolUse` fired;
  transcript: `Do you prefer tabs or spaces? → Spaces`). The spec's assertion holds.
- Every menu carries two synthetic rows beyond the model's options — **"Type
  something"** (free-text) and **"Chat about this"**. The notch renderer should
  mirror at least the former (see §1).
- **This tier is now optional.** Since hook-answering works, keystroke injection is
  a fallback, not the primary path — which also removes the baseline-tier
  reliability worry in spec §5 for States B and C.

---

## 5. Codex (§9 Q3) — State B is available; State C is not

`request_user_input` is Codex's `AskUserQuestion`, and it is **near
schema-identical**:

```json
{"questions":[{"header":"Next Bias","id":"next_bias",
  "question":"What should the next dispatch order optimize for?",
  "options":[{"label":"Home first (Recommended)","description":"…"}]}]}
```

Differences from Claude: adds a stable per-question **`id`** (better correlation
key than question text); `multiSelect` was **not** present in any of the direct
invocations sampled — treat as unsupported until proven. It is **mode-gated**:
Codex's own prompt says *"Use the `request_user_input` tool only when it is listed
in the available tools for this turn"*, and names two modes, Default and Plan.

- **State C: no equivalent.** The only plan-shaped tool is `update_plan`, which is
  a todo list (`{plan:[{step,status}]}`), not a review gate. No approval/review
  tool exists in 203 rollouts. Codex ships A + B + D; the capability matrix's
  "⚠️ verify" for C resolves to **N/A**.
- **Residual:** whether Codex's hook system emits `PreToolUse`/`PermissionRequest`
  for `request_user_input` is **unverified** — it needs a live Codex run, and Codex
  requires manual `/hooks` trust which the app cannot automate. Cheap to close
  during GW-321; until then assume State B is Claude-only.

## 6. §9 Q4 rests on a false premise

The spec says Codex `waitingForInput` is "inferred via `JSONLInterruptWatcher`",
and asks for its false-positive rate. It isn't:

- `JSONLInterruptWatcher` detects **interrupts** (`[Request interrupted by user]`),
  not `waitingForInput`, and its delegate is `didDetectInterrupt`.
- It is **explicitly skipped for Codex** — `ClaudeSessionMonitor.swift:43` gates on
  `event.source != "codex"` (GW-138), because it reads Claude's
  `~/.claude/projects/…` path, which does not exist for Codex.
- Codex's `waitingForInput` comes from the **`Stop` hook** — a discrete structured
  event (`ghostwire-hook.py`: `Stop → waiting_for_input`), not an inference.

**So there is no false-positive rate to measure and no debounce needed.** Q4 is
closed as not-applicable. (Claude additionally emits `Notification` with
`notification_type: "idle_prompt"`, observed ~60s after a turn ends — a second,
later State-D signal.)

---

## 7. Payload fields we receive but do not forward

Live payloads carry three fields `ghostwire-hook.py` currently drops:

| Field | Value seen | Why it matters |
| -- | -- | -- |
| `permission_mode` | `acceptEdits`, `plan` | **The mode-toggle half of GW-269.** Ghostwire currently can't see the agent's own mode, so its badge can contradict reality. |
| `prompt_id` | uuid | Stable per user turn — groups every tool call in one turn. Better correlation than heuristics. |
| `effort` | `{"level":"high"}` | Session metadata. |

Also confirmed (matches the existing design): `PreToolUse` carries `tool_use_id`,
`PermissionRequest` does **not** — which is exactly why the FIFO correlation cache
in `HookSocketServer` exists. `Notification.notification_type` is
`permission_prompt` for gates and `idle_prompt` when idle.

---

## Reproducing

Harness (throwaway, not committed): a PTY driver spawning
`claude --settings <file> "<prompt>"` with a capture hook that appends every raw
stdin payload to JSONL and can answer/hold on demand. `--settings` merges, so the
capture hook coexists with the installed Ghostwire hook. Modes exercised:
`observe`, `answer` (PreToolUse deny), `permdeny` (PermissionRequest deny),
`hold` (N-second block at either event).
