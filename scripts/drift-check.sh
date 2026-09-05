#!/usr/bin/env bash
# Detects divergence between the repo manifests and the live cluster spec.
#
# WHY THIS EXISTS: neither client-side nor server-side apply will remove a spec
# field that was added imperatively (kubectl patch / kubectl edit). Server-side
# apply keys ownership on (manager, operation); an Apply never prunes fields the
# same manager owns via an Update. So `kubectl apply` can report "unchanged" /
# "serverside-applied" while the live spec still carries a field the repo has
# never heard of -- and Crossplane will faithfully push it to AWS forever.
#
# Crossplane reconciles the CLUSTER against AWS. Nothing reconciles the cluster
# against Git. This script is that missing check.
set -uo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import subprocess, sys, glob, json, yaml

# Written into spec.forProvider by the provider itself (late-initialization and
# ownership tagging). Expected to be present live but absent from the manifests.
PROVIDER_TAGS = {"crossplane-kind", "crossplane-name", "crossplane-providerconfig"}

def live(kind, group, ns, name):
    r = subprocess.run(["kubectl","-n",ns,"get",f"{kind.lower()}.{group}",name,"-o","json"],
                       capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None

def walk(man, obs, path=""):
    """Compare every leaf the MANIFEST declares against the live object.

    Only keys present in the manifest are checked, so provider
    late-initialization (which adds many fields, e.g. a resolved
    originAccessControlId) is not reported as drift."""
    out = []
    for k, v in (man or {}).items():
        p = f"{path}.{k}" if path else k
        if k not in (obs or {}):
            out.append((p, v, "<missing>")); continue
        o = obs[k]
        if isinstance(v, dict) and isinstance(o, dict):
            out += walk(v, o, p)
        elif isinstance(v, list) and isinstance(o, list):
            # element-wise, still only checking manifest-declared keys
            for i, item in enumerate(v):
                if i >= len(o):
                    out.append((f"{p}[{i}]", item, "<missing>")); continue
                if isinstance(item, dict) and isinstance(o[i], dict):
                    out += walk(item, o[i], f"{p}[{i}]")
                elif item != o[i]:
                    out.append((f"{p}[{i}]", item, o[i]))
        elif v != o:
            out.append((p, v, o))
    return out

# The Phase 2 raw layer is deliberately deleted once Phase 4's XR takes over.
# If NONE of its MRs are present, there is nothing to compare -- skip rather than
# reporting 23 phantom "MISSING" findings.
manifests = sorted(glob.glob("phase2-raw-mrs/*.yaml"))
present = 0
for f in manifests:
    for d in yaml.safe_load_all(open(f)):
        if d and "kind" in d and live(d["kind"], d["apiVersion"].split("/")[0],
                                      d["metadata"].get("namespace"), d["metadata"]["name"]):
            present += 1
if present == 0:
    print("SKIP - no phase2-raw-mrs resources deployed (Phase 4 XR is in charge)")
    sys.exit(0)

drift = 0
for f in manifests:
    for d in yaml.safe_load_all(open(f)):
        if not d or "kind" not in d: continue
        kind = d["kind"]; group = d["apiVersion"].split("/")[0]
        ns = d["metadata"].get("namespace"); name = d["metadata"]["name"]
        obj = live(kind, group, ns, name)
        if obj is None:
            print(f"  MISSING   {kind}/{name} declared in {f} but not in cluster"); drift = 1; continue

        mfp = d.get("spec", {}).get("forProvider", {})
        ofp = obj.get("spec", {}).get("forProvider", {})

        for path, want, got in walk(mfp, ofp):
            print(f"  CHANGED   {kind}/{name} spec.forProvider.{path}\n"
                  f"              repo={want!r}\n              live={got!r}")
            drift = 1

        # extra tag keys the repo never declared and the provider did not inject
        mt = set((mfp.get("tags") or {}).keys())
        ot = set((ofp.get("tags") or {}).keys())
        for extra in sorted(ot - mt - PROVIDER_TAGS):
            print(f"  EXTRA     {kind}/{name} spec.forProvider.tags[{extra}] = "
                  f"{ofp['tags'][extra]!r}  (not in repo -- added out-of-band)")
            drift = 1

        # management policies / pause annotations left over from experiments
        pol = obj.get("spec", {}).get("managementPolicies", ["*"])
        if pol != d.get("spec", {}).get("managementPolicies", ["*"]):
            print(f"  POLICY    {kind}/{name} managementPolicies live={pol}"); drift = 1
        if (obj["metadata"].get("annotations") or {}).get("crossplane.io/paused"):
            print(f"  PAUSED    {kind}/{name} still has crossplane.io/paused"); drift = 1

print("DRIFT DETECTED" if drift else "NO DRIFT - cluster spec matches repo")
sys.exit(1 if drift else 0)
PY
