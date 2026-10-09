#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

renovate_run_dir="$(mktemp --directory)"
readonly renovate_run_dir

cleanup() {
  rm --force --recursive --one-file-system --preserve-root=all -- \
    "$renovate_run_dir"
}
trap cleanup EXIT

silent_policy="$(
  node <<'NODE'
const { randomUUID } = require('node:crypto');

// A fresh title prevents an old dashboard from supplying PR approvals
process.stdout.write(JSON.stringify({
  mode: 'silent',
  onboarding: false,
  configMigration: false,
  dependencyDashboard: false,
  dependencyDashboardApproval: false,
  dependencyDashboardTitle: `Unused Renovate approvals ${randomUUID()}`,
  prCreation: 'approval',
  suppressNotifications: ['configErrorIssue', 'missingCredentialsError'],
  vulnerabilityAlerts: { enabled: false },
  osvVulnerabilityAlerts: false,
}));
NODE
)"

discovery_policy="$(node --eval '
const policy = JSON.parse(process.argv[1]);
policy.mode = "full";
process.stdout.write(JSON.stringify(policy));
' "$silent_policy")"

# Discover eligible branches without writes; dry-run commits return no-work
RENOVATE_FORCE="$discovery_policy" renovate \
  --dry-run=full \
  --report-type=file \
  --report-path="$renovate_run_dir/report.json"

checked_branches="$(
  node - "$renovate_run_dir/report.json" <<'NODE'
const { readFileSync } = require('node:fs');
const report = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const repositories = Object.values(report.repositories);
if (repositories.length !== 1) {
  throw new Error('Expected a branch report for exactly one repository');
}
const eligibleResults = new Set(['no-work', 'needs-pr-approval', 'done']);
const branches = repositories[0].branches
  .filter((branch) => !branch.prNo && eligibleResults.has(branch.result))
  .map((branch) => branch.branchName);
process.stdout.write(JSON.stringify(branches));
NODE
)"

# checkedBranches permits branch creation without granting PR approval
RENOVATE_FORCE="$silent_policy" \
  RENOVATE_CHECKED_BRANCHES="$checked_branches" renovate
