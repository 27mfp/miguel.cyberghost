#!/usr/bin/env node
// Run the Omarchy plugin marketplace's own update validation and automated
// security baseline against an exact pushed commit, so a release is known to
// pass before a "[Verify]" request is opened.
//
// Usage:
//   node .github/marketplace/check.mjs --marketplace=<checkout> --plugin-id=<id> \
//     --repo=https://github.com/<owner>/<repo> --commit=<40-char sha> \
//     [--allowed-capabilities=.github/marketplace/allowed-capabilities.json]
//
// <checkout> is a clone of omacom/omarchy-plugin-marketplace with `npm ci`
// done. GITHUB_TOKEN is used for GitHub API reads. Exit codes: 0 pass,
// 1 the commit would not pass the marketplace, 2 the check could not run.
//
// This lives under .github/, which the marketplace baseline does not scan.
import { appendFile, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

function argument(name, { required = true } = {}) {
  const prefix = `--${name}=`;
  const value = process.argv.find((arg) => arg.startsWith(prefix))?.slice(prefix.length);
  if (!value && required) throw new Error(`--${name} is required`);
  return value || "";
}

async function summary(markdown) {
  process.stdout.write(`${markdown}\n`);
  if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, `${markdown}\n`);
}

const marketplace = resolve(argument("marketplace"));
const pluginId = argument("plugin-id");
const repoUrl = argument("repo").replace(/\.git$/, "").replace(/\/$/, "");
const commitSha = argument("commit").toLowerCase();
const allowedPath = argument("allowed-capabilities", { required: false });
if (!/^[a-f0-9]{40}$/.test(commitSha)) throw new Error("--commit must be a full 40-character SHA");

const load = (file) => import(pathToFileURL(resolve(marketplace, "scripts", file)).href);

async function main() {
  const { inspectListedPluginSource } = await load("build-catalog.mjs");
  const { parsePluginUpdateRequest, resolvePluginUpdate, sourceForPluginUpdate } = await load("plugin-update.mjs");
  const { canonicalRepositoryRequest } = await load("verification-subject.mjs");
  const { runSecurityBaseline, buildSecurityBaselineReport } = await load("security-baseline.mjs");

  // 1. Compatibility: the same request the "[Verify]" issue form produces.
  const registry = JSON.parse(await readFile(resolve(marketplace, "registry.json"), "utf8"));
  const body = [
    "### Verification action", "", "Verify and publish a newer upstream commit", "",
    "### Plugin ID", "", pluginId, "",
    "### Repository URL", "", repoUrl, "",
    "### Target commit", "", commitSha, "",
    "### Verification acknowledgment", "",
    "- [x] I understand that only the exact target commit can become a verified marketplace snapshot and that verification is not a security audit.", "",
    "### Standard installation acknowledgment", "", "_No response_", "",
  ].join("\n");
  const request = canonicalRepositoryRequest(registry, parsePluginUpdateRequest(body));
  const source = sourceForPluginUpdate(registry, request);
  let result;
  try {
    // The bot inspects default-branch HEAD; pinning the snapshot lets PRs and
    // tags be checked before they reach the default branch.
    const inspection = await inspectListedPluginSource({ ...source, snapshotCommit: commitSha });
    result = resolvePluginUpdate(registry, request, inspection);
  } catch (error) {
    await summary(`## Marketplace compatibility\n\n❌ \`${error.code || "error"}\`: ${error.message}`);
    return 1;
  }
  await summary(`## Marketplace compatibility\n\n✅ \`${result.pluginIds.join(", ")}\` passed at \`${commitSha.slice(0, 7)}\``);

  // 2. Automated security baseline, with the metadata the bot passes.
  const baseline = await runSecurityBaseline(repoUrl, commitSha, {
    requiredPaths: [...new Set(result.manifests.flatMap((manifest) => manifest.entryPoints || []))].sort(),
    listedPlugins: result.manifests.map((manifest) => ({ pluginId: manifest.id, manifestPathHint: manifest.path })),
  });
  await summary(buildSecurityBaselineReport(baseline, { context: "update" }));

  const findings = (baseline.findings || []).map((finding) => finding.ruleId);
  const capabilities = (baseline.capabilities || []).map((capability) => capability.id || capability.capabilityId || String(capability));
  const allowed = allowedPath ? JSON.parse(await readFile(resolve(allowedPath), "utf8")) : [];
  const unexpected = capabilities.filter((capability) => !allowed.includes(capability));
  const stale = allowed.filter((capability) => !capabilities.includes(capability));

  const problems = [];
  if (findings.length) problems.push(`findings must be fixed: ${[...new Set(findings)].join(", ")}`);
  if (unexpected.length) {
    problems.push(`new capabilities need review, then listing in ${allowedPath || "--allowed-capabilities"}: ${unexpected.join(", ")}`);
  }
  if (stale.length) await summary(`ℹ️ Allowed but no longer detected (can be removed): ${stale.join(", ")}`);
  await summary(`Outcome: \`${baseline.outcome}\`; capabilities: ${capabilities.length ? capabilities.join(", ") : "none"}`);
  if (problems.length) {
    await summary(`### ❌ Would not pass the marketplace\n\n${problems.map((problem) => `- ${problem}`).join("\n")}`);
    return 1;
  }
  await summary("### ✅ Ready for a marketplace verification request");
  return 0;
}

main().then((code) => { process.exitCode = code; }, async (error) => {
  await summary(`## Marketplace check could not run\n\n\`${error.code || error.name}\`: ${error.message}`);
  process.exitCode = 2;
});
