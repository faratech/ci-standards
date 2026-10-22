# faratech CI standards

Shared, report-first GitHub Actions governance for faratech repositories.

This repository provides one reusable workflow that scans a caller
repository's workflow definitions for the structural patterns that have
caused the largest GitHub Actions cost and capacity problems. It reports
findings as workflow annotations. It only fails a run when the caller
opts in to strict mode.

## Contents

- [What this is](#what-this-is)
- [Who should adopt it](#who-should-adopt-it)
- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Policy reference](#policy-reference)
- [Report-first and strict mode](#report-first-and-strict-mode)
- [Per-repo configuration: `.github/ci-policy.yml`](#per-repo-configuration-githubci-policyyml)
- [What the checker scans and outputs](#what-the-checker-scans-and-outputs)
- [Limitations](#limitations)
- [Development](#development)
- [Repository layout](#repository-layout)
- [License](#license)

## What this is

`faratech/ci-standards` is a central policy checker for GitHub Actions
workflows. Instead of copying lint rules into every repository, a caller
adds one thin workflow that delegates to the reusable workflow in this
repository.

The reusable workflow checks out the caller repository and runs a Ruby
script — [`scripts/check-actions-policy.rb`](scripts/check-actions-policy.rb) —
over every file under the caller's `.github/workflows/` directory. The
script looks for missing cost controls: jobs that can run forever,
workflows that duplicate work on every push and pull request, matrices
that fan out without a cap, and similar structural problems. It does not
run the caller's workflows, measure real spend, or inspect job logs.

The policy is intentionally report-first. Existing repositories can
adopt it, read the findings, fix or document exceptions, and only then
turn on strict mode. See
[Report-first and strict mode](#report-first-and-strict-mode).

## Who should adopt it

Adopt this policy in a faratech repository if any of the following apply:

- The repository has more than a trivial GitHub Actions setup and you
  want the same cost controls applied everywhere without maintaining a
  local copy of the rules.
- Jobs have run long, duplicated each other, or fanned out in ways that
  consumed runner capacity.
- The repository has several CI lanes — for example a fast lane, a deep
  or scheduled lane, and a release lane — and you want that routing to
  be explicit and checked. See
  [Per-repo configuration](#per-repo-configuration-githubci-policyyml).
- You want findings to appear as annotations on workflow runs first,
  with an opt-in switch to make them blocking once the repository is
  clean.

You do not need a separate installation step. If a repository has no
workflows, the checker scans zero files and reports nothing. If a
repository cannot use GitHub-hosted runners, note that the reusable
workflow itself runs on `ubuntu-latest`; see [Limitations](#limitations).

## How it works

The call chain has three layers, all in this repository:

```text
caller workflow  (in your repository)
  |  uses: faratech/ci-standards/.github/workflows/actions-policy.yml@main
  v
reusable workflow  .github/workflows/actions-policy.yml
  |  checks out the caller repository (actions/checkout@v4)
  |  calls the composite action with strict = inputs.policy_strict
  v
composite action  .github/actions/policy/action.yml
  |  sets POLICY_STRICT from its `strict` input
  v
ruby scripts/check-actions-policy.rb  (run from the caller repo root)
```

1. The **reusable workflow**
   ([`.github/workflows/actions-policy.yml`](.github/workflows/actions-policy.yml))
   declares one `workflow_call` input, `policy_strict`, runs a single
   `policy` job on `ubuntu-latest` with a 5-minute timeout, checks out
   the caller repository, and invokes the composite action.
2. The **composite action**
   ([`.github/actions/policy/action.yml`](.github/actions/policy/action.yml))
   maps its `strict` input to the `POLICY_STRICT` environment variable
   and runs the Ruby checker.
3. The **checker**
   ([`scripts/check-actions-policy.rb`](scripts/check-actions-policy.rb))
   reads the optional `.github/ci-policy.yml`, scans the workflow files,
   prints annotations and a summary line, and exits non-zero only in
   strict mode when there is something to report.

## Quick start

Add a thin workflow to your repository, for example at
`.github/workflows/actions-policy.yml`:

```yaml
name: Actions policy

on:
  push:
    paths:
      - ".github/workflows/**"
      - ".github/dependabot.yml"
      - ".github/ci-policy.yml"
  pull_request:
    paths:
      - ".github/workflows/**"
      - ".github/dependabot.yml"
      - ".github/ci-policy.yml"
  schedule:
    - cron: "17 6 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  policy:
    uses: faratech/ci-standards/.github/workflows/actions-policy.yml@main
    permissions:
      contents: read
```

That is the complete caller in report-first mode. The workflow reference
(`faratech/ci-standards/.github/workflows/actions-policy.yml@main`) and
the `contents: read` permission are exactly what the reusable workflow
declares and what the previous version of this README documented.

About the triggers: this repository's guidance is that the caller should
run when workflow or dependabot configuration changes and on a weekly
schedule. The example above implements that guidance: `push` and
`pull_request` are filtered to the workflow, dependabot, and policy
paths, `schedule` runs weekly (06:17 UTC on Mondays in the example), and
`workflow_dispatch` allows a manual run. The reusable workflow itself
declares no triggers other than `workflow_call`; trigger choice is the
caller's responsibility, so adjust the paths and cron expression to the
repository.

To make findings blocking once the repository is clean, pass the
reusable workflow's input:

```yaml
jobs:
  policy:
    uses: faratech/ci-standards/.github/workflows/actions-policy.yml@main
    with:
      policy_strict: true
    permissions:
      contents: read
```

The reusable workflow defines exactly one input:

| Input | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `policy_strict` | boolean | no | `false` | Fail the run when policy findings or parse errors are present. Forwarded to the composite action as `strict` and then to the checker as the `POLICY_STRICT` environment variable. |

The reusable workflow requests `contents: read` and the `policy` job
runs with `timeout-minutes: 5` on `ubuntu-latest`. No secrets are
declared or needed. Keep the caller's permission at `contents: read`
unless the repository's default token policy requires it to be stated
explicitly.

## Policy reference

The checker applies the rules below to every scanned workflow. Every
rule produces the same kind of output — a `::warning` annotation — and
every rule behaves the same way in both modes: it is always detected
and reported; strict mode only changes whether the run fails at the
end. There are no per-rule severity levels and no inline suppression
syntax.

### Workflow tiers

Several rules depend on a workflow's tier. The tier expresses how
expensive or time-sensitive the workflow is meant to be:

| Tier | Intended routing |
| --- | --- |
| `fast` | Ordinary change validation that is expected on pushes and pull requests. |
| `deep` | Expensive or long-running checks (for example CodeQL, fuzzing, or audits) that should not be triggered by `push` or `pull_request`. |
| `release` | Release, publishing, or signing workflows. Exempt from the `cancel-in-progress` rule. |
| `event` | Anything else: event-driven, scheduled, or manually dispatched workflows that do not fit the tiers above. This is the fallback tier. |

The checker resolves the tier in this order:

1. If the workflow path is listed in `.github/ci-policy.yml`, the
   declared tier wins.
2. Otherwise the tier is inferred from the workflow file name
   (case-insensitive substring match):
   - `release`, `publish`, or `sign` in the name → `release`
   - `codeql`, `fuzz`, `miri`, `pty`, `interop`, `validation`, or
     `audit` in the name → `deep`
   - `ci`, `build`, or `test` in the name → `fast`
   - anything else → `event`

Inference is a heuristic. Repositories with more than one CI lane
should declare tiers explicitly; see
[Per-repo configuration](#per-repo-configuration-githubci-policyyml).

### The rules

#### 1. Missing top-level `concurrency`

- **Message:** `missing top-level concurrency`
- **Why:** Without a top-level
  [`concurrency`](https://docs.github.com/en/actions/using-jobs/using-concurrency)
  block, repeated pushes to the same branch or pull request start
  parallel runs that duplicate work and consume capacity until they
  finish on their own.
- **Fix:** Add a top-level `concurrency` block, typically grouping by
  workflow and ref and setting `cancel-in-progress` appropriately for
  the workflow's tier.

#### 2. Job without `timeout-minutes`

- **Message:** `job '<job>' has no timeout-minutes`
- **Why:** A hung or unexpectedly slow job runs until the platform's
  outer limits stop it, holding a runner the whole time. An explicit
  per-job timeout is the primary cost backstop.
- **Fix:** Set `timeout-minutes` on every job to a value appropriate
  for that job.
- **Scope note:** Jobs that call a reusable workflow (`jobs.<id>.uses`)
  are skipped by this rule and the matrix and self-hosted rules below,
  because the called workflow owns its own job definitions.

#### 3. Matrix job without `max-parallel`

- **Message:** `matrix job '<job>' has no max-parallel`
- **Why:** An uncapped matrix fans out to one job per combination as
  soon as the workflow starts. A matrix that grows with operating
  systems, versions, or targets can consume a large share of runner
  capacity in a single run.
- **Fix:** Set `strategy.max-parallel` to cap how many matrix jobs run
  at once.

#### 4. Self-hosted job without a timeout

- **Message:** `self-hosted job '<job>' has no post-allocation timeout`
- **Why:** On a self-hosted runner there is no hosted-runner safety
  net: a job that hangs after a runner has been allocated holds scarce
  self-hosted capacity indefinitely. This rule flags the same missing
  `timeout-minutes` as rule 2 but calls out the self-hosted case
  separately so it is not overlooked.
- **Trigger:** The job's `runs-on` value contains `self-hosted` and
  the job has no `timeout-minutes`.
- **Fix:** Set `timeout-minutes` on the job.

#### 5. Overlapping `push` and `pull_request` without path filtering

- **Message:** `push and pull_request both lack path filtering`
- **Why:** A workflow triggered by both `push` and `pull_request` with
  no path filters runs twice for the same change — once for the branch
  push and once for the pull request — including for changes that
  cannot affect it.
- **Trigger:** Both `push` and `pull_request` are present and neither
  declares `paths` or `paths-ignore`. The rule passes as soon as at
  least one of the two declares either key.
- **Fix:** Add `paths` or `paths-ignore` to at least one of the two
  triggers, or remove the redundant trigger.

#### 6. `cancel-in-progress: false` on a non-release workflow

- **Message:** `cancel-in-progress is false on a non-release workflow`
- **Why:** Explicitly disabling cancellation keeps superseded runs
  alive after a newer push, spending runner time on commits that no
  longer matter.
- **Trigger:** The top-level `concurrency` block is a mapping with
  `cancel-in-progress: false`, and the workflow is not release-like
  (its file name does not contain `release`, `publish`, or `sign`).
  Release workflows are exempt because cancelling a release, publish,
  or signing run mid-flight can be worse than letting it finish.
- **Fix:** Remove the explicit `false` or set `cancel-in-progress:
  true` for non-release workflows.

#### 7. Deep-tier workflow triggered by `push` or `pull_request`

- **Message:** `deep workflow is triggered by push/pull_request`
- **Why:** Deep checks — the filename heuristic looks for names such as
  CodeQL, fuzzing, and audit workflows — are the expensive lanes.
  Triggering them on every push and pull request multiplies that cost
  across every change.
- **Trigger:** The workflow's resolved tier is `deep` and its `on`
  includes `push` or `pull_request`.
- **Fix:** Move the workflow to a schedule, a manual dispatch, or a
  label/merge-gated trigger — or reclassify it in
  `.github/ci-policy.yml` if it is genuinely a fast lane.

#### 8. Invalid `.github/ci-policy.yml` structure

- **Message:** `ci-policy.yml must contain version: 1 and a workflows mapping`
- **Why:** The per-repo configuration is the explicit record of the
  intended routing. If its shape is wrong, the checker cannot trust
  the declared tiers and falls back to filename inference silently.
- **Trigger:** `.github/ci-policy.yml` exists but is not a mapping
  with `version: 1` and a `workflows` mapping.
- **Fix:** See the format reference in
  [Per-repo configuration](#per-repo-configuration-githubci-policyyml).

#### 9. Unknown tier in `.github/ci-policy.yml`

- **Message:** `workflow '<path>' has unknown tier '<value>'`
- **Why:** A misspelled or invented tier would otherwise be stored and
  compared against the known tiers, quietly disabling tier-dependent
  rules for that workflow.
- **Trigger:** A value in the `workflows` mapping is not one of
  `fast`, `deep`, `release`, or `event`.
- **Fix:** Use one of the four supported tier names.

#### 10. Workflow root is not a mapping

- **Message:** `workflow root is not a mapping`
- **Why:** A workflow file whose top level is a list or a scalar is
  not a workflow at all. Flagging it separately from a YAML parse
  error distinguishes "valid YAML, wrong shape" from "not parseable".
- **Fix:** Make the file a mapping with the usual `on` and `jobs`
  keys.

### Parse errors

A file that cannot be parsed as YAML at all — including an invalid
`.github/ci-policy.yml` — is recorded as a parse error, reported with
the title `Workflow parser compatibility`, and skipped for the
remaining rules. Parse errors count toward the strict-mode failure
condition exactly like findings.

A note on the previous README's wording: it said the checker "fails on
invalid YAML". The precise behavior in the current script is that
parse errors are always reported as warnings and only fail the run in
strict mode, together with policy findings. See the next section.

## Report-first and strict mode

Detection never changes between modes. Only the exit code does.

| | Report-first (default) | Strict |
| --- | --- | --- |
| Caller setting | Omit `policy_strict`, or set it to `false` | `policy_strict: true` |
| Findings | Printed as `::warning` annotations | Printed as `::warning` annotations |
| Parse errors | Printed as `::warning` annotations | Printed as `::warning` annotations |
| Summary line | Always printed | Always printed |
| Exit code | Always `0`; the run succeeds | Non-zero (`abort`) if there is at least one finding or parse error; otherwise `0` |

The flag travels through three names, one per layer:

```text
caller job:        with: policy_strict: true     (boolean input)
reusable workflow: inputs.policy_strict
composite action:  inputs.strict                 (default 'false')
checker process:   POLICY_STRICT=true            (environment variable)
```

Inside the checker, strict mode is on exactly when
`POLICY_STRICT` lower-cased equals `true` and the combined list of
findings and parse errors is non-empty. The failure message printed on
abort is `Actions policy failed in strict mode.`

Recommended adoption path:

1. Add the caller workflow in report-first mode.
2. Read the annotations on the next few runs and fix the workflows, or
   declare the intended tiers in `.github/ci-policy.yml` where the
   routing is deliberate.
3. Set `policy_strict: true` once the report is clean, so new findings
   block the policy run instead of accumulating silently.

## Per-repo configuration: `.github/ci-policy.yml`

A repository with more than one CI lane can declare the intended tier
of each workflow in `.github/ci-policy.yml`, at the repository root's
`.github/` directory. The file is optional; without it, the checker
uses filename inference for every workflow.

### Format

```yaml
version: 1
workflows:
  .github/workflows/ci.yml: fast
  .github/workflows/codeql.yml: deep
  .github/workflows/release.yml: release
```

The example above is the one this README has always shown. The format
as implemented by the checker is:

- The document must be a mapping.
- `version` is required and must be the integer `1`.
- `workflows` is required and must be a mapping from workflow path to
  tier. Keys are paths exactly as the checker discovers them, that is,
  relative paths such as `.github/workflows/ci.yml`.
- Each value is either a tier name directly, or a mapping with a
  `tier` key. Both forms are accepted:

  ```yaml
  workflows:
    .github/workflows/ci.yml: fast
    .github/workflows/codeql.yml:
      tier: deep
  ```

- Supported tiers are `fast`, `deep`, `release`, and `event`. Any
  other value is reported by rule 9.
- A declared tier overrides filename inference for that workflow only.
  Workflows that are not listed keep their inferred tier. Listing a
  path that does not exist is not itself an error, but it has no
  effect.
- If the file exists but the `version`/`workflows` shape is wrong,
  rule 8 is reported and no declared tiers are applied. If the file
  cannot be parsed as YAML, it is reported as a parse error instead.

### When to add the file

Add `.github/ci-policy.yml` when filename inference would misclassify
a workflow — for example a deep check whose file name contains `ci`,
or a fast check named after the tool it runs — or when the team wants
the intended routing of each lane recorded in the repository rather
than implied by file names.

## What the checker scans and outputs

### Inputs scanned

- **Workflow files:** every file matching
  `.github/workflows/**/*.{yml,yaml}` under the caller repository
  root, in sorted order, including files in subdirectories. Any path
  ending in `actions-policy.yml` is excluded, so a caller file (or
  this repository's own reusable workflow) named `actions-policy.yml`
  is never scanned.
- **Per-repo policy:** `.github/ci-policy.yml`, if it exists. Its
  absence is not a finding.
- Nothing else is read: not job logs, not artifacts, not the
  repository's other configuration.

Each workflow file is parsed with Ruby's Psych `safe_load` with
aliases enabled. The checker tolerates the YAML 1.1 quirk in which the
unquoted key `on` parses as the boolean `true`, and accepts `on` in
its scalar, list, and mapping forms.

Rules are applied to the top-level `concurrency` block, the trigger
set, and each entry under `jobs`. Jobs that call a reusable workflow
(`uses:`) are skipped for the job-level rules because their internals
live in the called workflow.

### Output

For each parse error, one workflow command line:

```text
::warning title=Workflow parser compatibility::<path>: <first line of the parser error>
```

For each finding, one workflow command line with a file reference:

```text
::warning file=<path>,title=Actions cost policy::<message>
```

These appear as annotations in the Actions run UI and in the run log.
The run always ends with a plain summary line, for example:

```text
Actions policy scanned 4 workflow(s): 3 finding(s), 0 parse error(s).
```

There is no SARIF output, no pull-request comment, no artifact upload,
and no step summary. The caller's only signals are the annotations,
the summary line, and — in strict mode — the failing exit code with
the message `Actions policy failed in strict mode.`

## Limitations

- **Structural checks only.** The checker reads workflow YAML; it
  does not execute workflows, observe actual runtimes or spend, or
  verify that a declared timeout or concurrency group is well chosen.
  It checks that `timeout-minutes` and `max-parallel` are present,
  not that their values are sensible.
- **Presence-based path filtering.** Rule 5 passes if either trigger
  declares `paths` or `paths-ignore`, whatever the patterns are. It
  does not judge whether the filters are correct.
- **Filename heuristics.** Tier inference and the release exemption
  are substring matches on the workflow file name. Names that do not
  contain any of the known substrings fall back to the `event` tier,
  and an unusual name can misclassify a workflow until it is declared
  in `.github/ci-policy.yml`.
- **String-form `concurrency` is not inspected.** If `concurrency`
  is a plain string (a group name), rule 6 cannot see a
  `cancel-in-progress` value and does not fire.
- **Job-level scope.** Reusable-workflow jobs (`uses:`) are skipped,
  and the checker does not follow them into the called workflow.
  Matrix detection only looks at `strategy.matrix` and
  `strategy.max-parallel` at the job level.
- **Annotations are the only report.** There is no machine-readable
  report file; consumers that need structured results must parse the
  log lines or run the script themselves.
- **Runner assumption.** The reusable workflow runs on
  `ubuntu-latest` and uses `actions/checkout@v4`. The composite action
  requires Ruby with the `psych` standard library on the runner, as
  provided by the GitHub-hosted Ubuntu images. The policy job itself
  is capped at 5 minutes.
- **`@main` reference.** The documented caller pins the reusable
  workflow to `@main`, matching this repository's own action
  reference. Callers get policy changes as soon as they land on
  `main`; there are no versioned tags or releases to pin to in this
  repository today.

## Development

The checker is a single Ruby script with no dependencies beyond the
`psych` standard library. There is no Gemfile, no test suite, and no
build step in this repository.

To run the same check locally that the reusable workflow runs in CI,
install Ruby, clone this repository alongside (or copy the script
into) the repository you want to scan, and from that repository's
root run:

```bash
ruby /path/to/ci-standards/scripts/check-actions-policy.rb
```

The script scans `.github/workflows/` relative to the current working
directory, so the working directory must be the root of the repository
under test. For example, to check this repository itself:

```bash
git clone https://github.com/faratech/ci-standards
cd ci-standards
ruby scripts/check-actions-policy.rb
```

Report-first is the default. To reproduce strict mode locally:

```bash
POLICY_STRICT=true ruby scripts/check-actions-policy.rb
echo $?   # non-zero when findings or parse errors are present
```

Note that this repository's own reusable workflow file,
`.github/workflows/actions-policy.yml`, legitimately has no top-level
`concurrency` block and is excluded from scans by name; a local run
against a caller repository is the meaningful check.

To change the policy, edit
[`scripts/check-actions-policy.rb`](scripts/check-actions-policy.rb),
and keep the three layers consistent: the reusable workflow's
`policy_strict` input
([`.github/workflows/actions-policy.yml`](.github/workflows/actions-policy.yml)),
the composite action's `strict` input and `POLICY_STRICT` mapping
([`.github/actions/policy/action.yml`](.github/actions/policy/action.yml)),
and this README's [Policy reference](#policy-reference). Test the
script by running it against a scratch repository with workflow files
that trigger each rule, in both the default and strict modes.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`.github/workflows/actions-policy.yml`](.github/workflows/actions-policy.yml) | Reusable (`workflow_call`) workflow; the caller-facing entry point. |
| [`.github/actions/policy/action.yml`](.github/actions/policy/action.yml) | Composite action that maps `strict` to `POLICY_STRICT` and runs the checker. |
| [`scripts/check-actions-policy.rb`](scripts/check-actions-policy.rb) | The policy checker: scanning, tier resolution, rules, reporting, strict-mode exit. |
| `README.md` | This document. |

## License

No `LICENSE` file is present in this repository, and none was detected
in the tree at the time of writing. That means no license terms have
been published for this code: reuse, copying, and redistribution are
not granted by a license here, and the default position — all rights
reserved by the copyright holder — applies. Contact the repository
owner before reusing this code outside the `faratech` organisation's
own repositories. (This section records the absence of a license; it
does not itself grant one, and no license file is added by this
documentation change.)
