#!/usr/bin/env python3
"""Render every Argo CD Application this repository produces for one
deployment, offline, and fail on any error.

It emulates what Argo CD does on a hub, without a cluster: bootstrap.sh's
fill-in of the root ApplicationSet, the root's token replacement, kustomize
patches in Application specs, nested ApplicationSets (clusters, list,
matrix, clusterDecisionResource and git directory generators, the last evaluated against
the Placements the render itself produces), and every helm, kustomize and
directory source, recursively. It is an emulation: a clean render means the
manifests are consistent, not that a cluster accepts them.

Remote sources (other repositories at a revision) are fetched once into a
cache. The deployment and catalog repositories are local directories.

It also fails when two Applications manage the same object on one cluster,
when an object lacks apiVersion, kind or name, and when an Application in an
AppProject other than default renders a kind or namespace the project
doesn't admit.

usage: render.py --clusters FILE [--deployment DIR] [--path deployment]
                 [--catalog DIR] [--dump DIR] [--skip-schema]
CLUSTERS FILE: JSON list of {"name": ..., "labels": {...}}, the ManagedClusters.
"""
import argparse, fnmatch, glob, hashlib, json, os, re, shutil, subprocess, sys, tempfile
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
T = os.path.dirname(os.path.dirname(HERE))  # this repository
CACHE = os.environ.get("RENDER_CACHE", os.path.join(T, ".cache", "render"))
GEN = os.environ.get("RENDER_GEN", os.path.join(CACHE, "appsetgen"))
DEPLOY_URL = "https://deployment.invalid/deployment.git"   # stands in for DEPLOYMENT_REPO_URL
CATALOG_URL = "https://catalog.invalid/catalog.git"         # stands in for CATALOG_REPO_URL

ap = argparse.ArgumentParser()
ap.add_argument("--clusters", required=True)
ap.add_argument("--deployment", default=T)
ap.add_argument("--path", default="deployment")
ap.add_argument("--catalog")
ap.add_argument("--dump")
ap.add_argument("--skip-schema", action="store_true",
                help="skip Helm values schemas (the pinned odh-gitops branch rejects its own values)")
A = ap.parse_args()
D, DPATH, DUMP, CATALOG = A.deployment, A.path, A.dump, A.catalog
CLUSTERS = json.load(open(A.clusters))
if A.skip_schema: os.environ["SKIP_SCHEMA"] = "1"
errors, apps_seen = [], []
_root = yaml.safe_load(open(os.path.join(T, "bootstrap", "applicationset.yaml")).read().replace("${", "$_{"))
TEMPLATE_URL = _root["spec"]["generators"][0]["git"]["repoURL"]

FETCHED = set()

def remote(url, rev):
    """A shallow checkout of url at rev, cached. A commit is fetched once; a
    branch or tag is fetched again on each run, as Argo CD follows it."""
    d = os.path.join(CACHE, hashlib.sha256(f"{url}@{rev}".encode()).hexdigest()[:16])
    done = os.path.join(d, ".render-complete")
    pinned = re.fullmatch(r"[0-9a-f]{40}", rev or "") is not None
    if (url, rev) in FETCHED or (pinned and os.path.exists(done)):
        return d
    os.makedirs(d, exist_ok=True)
    if os.path.exists(done): os.remove(done)
    if not os.path.isdir(os.path.join(d, ".git")):
        subprocess.run(["git", "init", "-q"], cwd=d, check=True)
    for cmd in (["git", "fetch", "-q", "--depth", "1", url, rev], ["git", "checkout", "-q", "--force", "FETCH_HEAD"]):
        subprocess.run(cmd, cwd=d, check=True)
    open(done, "w").close()
    FETCHED.add((url, rev))
    return d

def fail(msg):
    errors.append(msg)
    print("FAIL", msg)

def _ensure_gen():
    src = os.path.join(HERE, "main.go")
    if not os.path.exists(GEN) or os.path.getmtime(GEN) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(GEN), exist_ok=True)
        subprocess.run(["go", "build", "-o", GEN, "."], cwd=HERE, check=True)
_ensure_gen()

def gen(spec, params):
    r = subprocess.run([GEN], input=json.dumps({"spec": spec, "params": params}), capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return json.loads(r.stdout) or []

def repo_dir(url, rev):
    if url == TEMPLATE_URL: return T
    if url == DEPLOY_URL: return D
    if url == CATALOG_URL: return CATALOG
    if url and rev and url.startswith("https://"): return remote(url, rev)
    return None

def load_all(text):
    return [d for d in yaml.safe_load_all(text) if d]

# What Argo CD on an OpenShift hub with ACM reports to Helm (.Capabilities).
API_VERSIONS = ["route.openshift.io/v1", "security.openshift.io/v1", "monitoring.coreos.com/v1",
                "operators.coreos.com/v1alpha1", "operators.coreos.com/v1", "cert-manager.io/v1",
                "policy.open-cluster-management.io/v1", "cluster.open-cluster-management.io/v1beta1",
                "config.openshift.io/v1", "gateway.networking.k8s.io/v1"]

def render_source(app, src, refs, ns):
    url, rev = src.get("repoURL"), src.get("targetRevision")
    if "chart" in src:  # helm repository chart
        out = subprocess.run(["helm", "template", src.get("helm", {}).get("releaseName", app), src["chart"],
                              "--repo", url, "--version", rev], capture_output=True, text=True)
        if out.returncode: fail(f"{app}: helm repo chart {src['chart']}: {out.stderr.strip()[:300]}"); return []
        return load_all(out.stdout)
    base = repo_dir(url, rev)
    if base is None: fail(f"{app}: unknown repo {url}@{rev}"); return []
    if "path" not in src: return []  # ref-only source
    path = os.path.join(base, src["path"])
    if not os.path.isdir(path): fail(f"{app}: path does not exist: {url} {src['path']}"); return []
    if "helm" in src or os.path.exists(os.path.join(path, "Chart.yaml")):
        h = src.get("helm", {})
        args = ["helm", "template", h.get("releaseName", app), path, "--namespace", ns or "default"]
        args += [a for v in API_VERSIONS for a in ("--api-versions", v)]
        if os.environ.get("SKIP_SCHEMA"): args.append("--skip-schema-validation")
        for vf in h.get("valueFiles", []):
            m = re.match(r"\$(\w+)/(.*)", vf)
            f = os.path.join(refs[m.group(1)], m.group(2)) if m else os.path.join(path, vf)
            if not os.path.exists(f):
                if h.get("ignoreMissingValueFiles"): continue
                fail(f"{app}: missing value file {vf}"); return []
            args += ["-f", f]
        if h.get("valuesObject") is not None:
            vf = tempfile.NamedTemporaryFile("w", suffix=".yaml", dir=CACHE, delete=False)
            yaml.safe_dump(h["valuesObject"], vf); vf.close()
            args += ["-f", vf.name]
        for p in h.get("parameters", []):
            args += ["--set-string" if p.get("forceString") else "--set", f"{p['name']}={p['value']}"]
        out = subprocess.run(args, capture_output=True, text=True)
        if out.returncode: fail(f"{app}: helm template {src['path']}: {out.stderr.strip()[:400]}"); return []
        return load_all(out.stdout)
    # An explicit directory source is a plain directory even with a kustomization in it, as in Argo CD.
    if os.path.exists(os.path.join(path, "kustomization.yaml")) and "directory" not in src:
        k = src.get("kustomize", {})
        os.makedirs(CACHE, exist_ok=True)
        tmp = os.path.realpath(tempfile.mkdtemp(dir=CACHE))
        imgs = []
        for i in k.get("images", []):
            n, rest = i.split("=", 1)
            ref, _, dig = rest.partition("@")
            imgs.append({"name": n, "newName": ref, **({"digest": dig} if dig else {})})
        kz = {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization", "resources": [os.path.relpath(os.path.realpath(path), tmp)],
              "patches": k.get("patches", []), "images": imgs}
        open(os.path.join(tmp, "kustomization.yaml"), "w").write(yaml.safe_dump(kz))
        out = subprocess.run(["kustomize", "build", tmp], capture_output=True, text=True)
        shutil.rmtree(tmp)
        if out.returncode: fail(f"{app}: kustomize build {src['path']}: {out.stderr.strip()[:400]}"); return []
        return load_all(out.stdout)
    d = src.get("directory", {})
    objs = []
    files = sorted(glob.glob(os.path.join(path, "**", "*") if d.get("recurse") else os.path.join(path, "*"), recursive=True))
    files = [f for f in files if re.search(r"\.(ya?ml|json)$", f)]
    for f in files:
        rel = os.path.relpath(f, path)
        if d.get("include") and not any(fnmatch.fnmatch(rel, g) for g in re.split(r"[{},]", d["include"]) if g): continue
        if d.get("exclude") and any(fnmatch.fnmatch(rel, g) for g in re.split(r"[{},]", d["exclude"]) if g): continue
        try: objs += load_all(open(f).read())
        except yaml.YAMLError as e: fail(f"{app}: {rel}: {e}")
    return objs

PLACEMENTS = {}   # (namespace, name) -> Placement spec, from every rendered object
APPSETS = []      # nested ApplicationSets, expanded once all Placements are known

def selects(sel, labels):
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v: return False
    for e in sel.get("matchExpressions") or []:
        val, op, vals = labels.get(e["key"]), e["operator"], e.get("values") or []
        if op == "In" and val not in vals: return False
        if op == "NotIn" and val in vals: return False
        if op == "Exists" and val is None: return False
        if op == "DoesNotExist" and val is not None: return False
    return True

def placement_clusters(ns, name):
    spec = PLACEMENTS.get((ns, name))
    if spec is None: fail(f"no Placement {ns}/{name}"); return []
    preds = spec.get("predicates") or [{}]
    return [c["name"] for c in CLUSTERS
            if any(selects(((p.get("requiredClusterSelector") or {}).get("labelSelector") or {}), {"name": c["name"], **c.get("labels", {})}) for p in preds)]

def cluster_params(gen_clusters):
    sel = (gen_clusters.get("selector") or {})
    out = []
    for c in CLUSTERS:
        labels = {"name": c["name"], **c.get("labels", {})}
        if not selects(sel, labels): continue
        out.append({"name": c["name"], "nameNormalized": c["name"], "server": f"https://{c['name']}.invalid",
                    "metadata": {"labels": dict(c.get("labels", {})), "annotations": {}}, "values": gen_clusters.get("values") or {}})
    return out

PROJECTS = {}   # AppProject name -> spec
OWNERS = {}     # (cluster, group, kind, namespace, name) -> Application

def check_objects(app, spec, objs):
    dest = spec.get("destination") or {}
    cluster = dest.get("server") or dest.get("name")
    proj = PROJECTS.get(spec.get("project", "default"))
    for o in objs:
        md = o.get("metadata") or {}
        if not o.get("apiVersion") or not o.get("kind") or not (md.get("name") or md.get("generateName")):
            fail(f"{app}: object without apiVersion, kind or name: {str(o)[:120]}"); continue
        if o["kind"] == "AppProject": PROJECTS[md["name"]] = o.get("spec") or {}
        group = o["apiVersion"].split("/")[0] if "/" in o["apiVersion"] else ""
        ns = md.get("namespace") or dest.get("namespace")
        hook = "argocd.argoproj.io/hook" in (md.get("annotations") or {}) or "helm.sh/hook" in (md.get("annotations") or {})
        key = (cluster, group, o["kind"], ns if o["kind"] != "Namespace" else None, md.get("name"))
        if not hook and md.get("name"):
            if key in OWNERS and OWNERS[key] != app:
                fail(f"{app}: {o['kind']} {ns}/{md['name']} is also managed by {OWNERS[key]}")
            OWNERS[key] = app
        if proj is not None:
            allowed = proj.get("namespaceResourceWhitelist")
            cluster_scoped = o["kind"] in ("Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition")
            if cluster_scoped and proj.get("clusterResourceWhitelist") == []:
                fail(f"{app}: project {spec.get('project')} admits no cluster-scoped {o['kind']}")
            elif allowed is not None and not any(w.get("kind") == o["kind"] and w.get("group", "") == group for w in allowed):
                fail(f"{app}: project {spec.get('project')} doesn't admit {group}/{o['kind']}")
            dests = [x.get("namespace") for x in proj.get("destinations", [])]
            if ns and dests and "*" not in dests and ns not in dests:
                fail(f"{app}: project {spec.get('project')} doesn't admit namespace {ns}")

def render_app(name, spec, depth):
    apps_seen.append(name)
    blob = json.dumps(spec)
    left = re.findall(r"@(?:deployment|catalog|template)\w+@", blob)
    if left: fail(f"{name}: leftover tokens {sorted(set(left))}")
    sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
    refs = {}
    for s in sources:
        if "ref" in s:
            b = repo_dir(s.get("repoURL"), s.get("targetRevision"))
            if b is None: fail(f"{name}: unknown ref repo {s.get('repoURL')}")
            refs[s["ref"]] = b or ""
    objs = []
    dest = spec.get("destination") or {}
    for s in sources: objs += render_source(name, s, refs, dest.get("namespace"))
    check_objects(name, spec, objs)
    kinds = {}
    for o in objs: kinds[o.get("kind")] = kinds.get(o.get("kind"), 0) + 1
    print("  " * depth + f"{name}: {sum(kinds.values())} objects")
    if DUMP:
        os.makedirs(DUMP, exist_ok=True)
        open(os.path.join(DUMP, name + ".yaml"), "w").write(yaml.safe_dump_all(objs))
    for o in objs:
        if o.get("kind") == "Placement":
            PLACEMENTS[(o["metadata"].get("namespace"), o["metadata"]["name"])] = o.get("spec") or {}
    for o in objs:
        if o.get("kind") == "ApplicationSet": APPSETS.append((o, depth + 1))
        if o.get("kind") == "Application" and o.get("apiVersion", "").startswith("argoproj.io"):
            render_app(o["metadata"]["name"], o["spec"], depth + 1)

def gen_params(g, ns):
    if "clusters" in g: return cluster_params(g["clusters"])
    if "list" in g: return g["list"].get("elements", [])
    if "git" in g and "directories" in g["git"]:
        base = repo_dir(g["git"]["repoURL"], g["git"].get("revision"))
        if base is None: fail(f"git generator: unknown repo {g['git']['repoURL']}"); return []
        out = []
        for d in g["git"]["directories"]:
            for p in sorted(glob.glob(os.path.join(base, d["path"]))):
                if not os.path.isdir(p): continue
                rel = os.path.relpath(p, base)
                if d.get("exclude"): out = [o for o in out if o["path"]["path"] != rel]; continue
                segs = rel.split("/")
                out.append({"path": {"path": rel, "basename": segs[-1], "basenameNormalized": segs[-1],
                                     "filename": "", "segments": segs}})
        return out
    if "clusterDecisionResource" in g:
        c = g["clusterDecisionResource"]
        name = c["labelSelector"]["matchLabels"]["cluster.open-cluster-management.io/placement"]
        # Argo CD matches each decision to its cluster Secret: name, server, clusterName.
        return [{"clusterName": n, "name": n, "nameNormalized": n, "server": f"https://{n}.invalid"}
                for n in placement_clusters(ns, name)]
    if "matrix" in g:
        a, b = g["matrix"]["generators"]
        out = []
        for p1 in gen_params(a, ns):
            b2 = json.loads(json.dumps(b))
            # child 2 may template on child 1's params (only string values in selectors)
            try: b2 = gen({"template": b2}, [p1])[0]
            except RuntimeError as e: fail(f"matrix generator: {e}"); continue
            for p2 in gen_params(b2, ns):
                out.append({**p1, **p2})
        return out
    fail(f"generator {list(g)} not emulated"); return []

def render_appset(o, depth):
    spec = o["spec"]
    params = []
    for g in spec.get("generators", []):
        params += gen_params(g, o["metadata"].get("namespace", "openshift-gitops"))
    try: rendered = gen(spec, params)
    except RuntimeError as e: fail(f"appset {o['metadata']['name']}: {e}"); return
    for a in rendered:
        render_app(a["metadata"]["name"], a["spec"], depth)

# Root: bootstrap.sh's fill-in, then one Application per application.yaml.
root = open(os.path.join(T, "bootstrap", "applicationset.yaml")).read()
for k, v in {"DEPLOYMENT_REPO_URL": DEPLOY_URL, "DEPLOYMENT_REVISION": "HEAD", "DEPLOYMENT_PATH": DPATH,
             "CATALOG_REPO_URL": CATALOG_URL if CATALOG else "", "CATALOG_REVISION": "HEAD"}.items():
    root = root.replace("${%s}" % k, v)
root = yaml.safe_load(root)
params = []
for g in root["spec"]["generators"]:
    base = repo_dir(g["git"]["repoURL"], g["git"].get("revision"))
    for f in g["git"]["files"]:
        for p in sorted(glob.glob(os.path.join(base, f["path"]))):
            doc = yaml.safe_load(open(p))
            doc["path"] = {"path": os.path.dirname(os.path.relpath(p, base))}
            params.append(doc)
for a in gen(root["spec"], params):
    render_app(a["metadata"]["name"], a["spec"], 0)

while APPSETS:
    o, d = APPSETS.pop(0)
    render_appset(o, d)
print(f"{len(apps_seen)} applications, {len(errors)} errors")
sys.exit(1 if errors else 0)
