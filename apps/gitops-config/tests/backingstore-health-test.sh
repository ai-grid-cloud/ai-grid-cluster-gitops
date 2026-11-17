#!/usr/bin/env bash
# Runs the NooBaa BackingStore health check (extracted from the ArgoCD CR) under Lua, with only the basics Argo CD's
# sandbox exposes, against status fixtures. Needs lua5.4 (or lua/luajit) and PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LUA=$(command -v lua5.4 || command -v lua || command -v luajit) || { echo "no Lua interpreter" >&2; exit 1; }
python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for h in d["spec"]["resourceHealthChecks"]:
    if h.get("group") == "noobaa.io" and h.get("kind") == "BackingStore": open(sys.argv[2], "w").write(h["check"]); break
else: raise SystemExit("no BackingStore health check")' "$HERE/../manifests/argocd.yaml" "$T/check.lua"
cat > "$T/fixtures.lua" <<'END_LUA'
local function bs(phase, degraded, mode)
  local conds = nil
  if degraded ~= nil then
    conds = {{type="Available", status="True"}, {type="Progressing", status="False"}, {type="Degraded", status=degraded, message="pool unhealthy"}}
  end
  return {status={phase=phase, conditions=conds, mode=mode and {modeCode=mode} or nil}}
end
F = {
  {"no-status", {metadata={}}, "Progressing"},
  {"creating", bs("Creating", "False"), "Progressing"},
  {"connecting", bs("Connecting", nil), "Progressing"},
  {"ready", bs("Ready", "False", "OPTIMAL"), "Healthy"},
  {"ready-with-storage-issues-mode", bs("Ready", "False", "MANY_STORAGE_ISSUES"), "Healthy"},
  {"ready-but-degraded-condition", bs("Ready", "True", "ALL_NODES_OFFLINE"), "Degraded"},
  {"rejected", bs("Rejected", "False", "INITIALIZING"), "Degraded"},
}
END_LUA
cat > "$T/run.lua" <<'END_LUA'
dofile(arg[1])
local src = assert(io.open(arg[2])):read("a")
local function sandboxed(o)
  local env = {ipairs = ipairs, pairs = pairs, type = type, tostring = tostring, tonumber = tonumber, next = next, select = select, error = error, obj = o}
  return assert(load(src, "check", "t", env))
end
local fails, total = 0, 0
for _, f in ipairs(F) do
  total = total + 1
  local ok, hs = pcall(sandboxed(f[2]))
  local got = ok and hs and hs.status or ("error: " .. tostring(hs))
  if got == f[3] then print(string.format("   ok   %-32s %s", f[1], got))
  else print(string.format("   FAIL %-32s got %s wanted %s", f[1], got, f[3])); fails = fails + 1 end
end
print(string.format("backingstore-health tests: %d ok, %d failed", total - fails, fails))
os.exit(fails)
END_LUA
"$LUA" "$T/run.lua" "$T/fixtures.lua" "$T/check.lua"
