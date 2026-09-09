# faratech CI standards

Shared, report-first GitHub Actions governance for faratech repositories.

The policy checks workflow definitions for the patterns that have caused the
largest cost and capacity problems:

- missing job timeouts;
- missing workflow concurrency controls;
- overlapping push and pull-request triggers without path filters;
- uncapped matrices; and
- explicit `cancel-in-progress: false` on non-release workflows.

The reusable workflow is intentionally report-first. It fails on invalid YAML,
but reports policy findings without breaking existing repositories. A caller can
set `POLICY_STRICT: 'true'` once its workflow exceptions are documented.

## Caller

Add a thin workflow to a repository:

```yaml
jobs:
  policy:
    uses: faratech/ci-standards/.github/workflows/actions-policy.yml@main
    permissions:
      contents: read
```

The caller should trigger on workflow/dependabot configuration changes and on a
weekly schedule. The reusable workflow checks out the caller repository and
scans its workflow files.
