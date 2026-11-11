#!/usr/bin/env python3
"""Report which AI Grid install prerequisites you have. Never blocks, never changes anything.

Usage: prereqs.py [--deployment DIR] [--hub-context CONTEXT] [--site-context CONTEXT]
                  [--quay-auth-file FILE] [--catalog-token-file FILE]

Each option also reads an environment variable: HUB_CONTEXT, SITE_CONTEXT,
QUAY_AUTH_FILE and CATALOG_TOKEN_FILE. A check whose input you haven't set
prints "skipped". Every line is: status, name, detail. Statuses: ok, MISSING,
OLD, FAIL, skipped. Cluster checks are read-only (get, whoami, auth can-i).
The registry check runs "oc image info" with your auth file; it never prints a
credential. The exit code is always 0.
"""
import argparse
import base64
import json
import os
import re
import shutil
import stat
import subprocess
import sys

LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIN_OPENSHIFT = (4, 21)
OC_TIMEOUT = "--request-timeout=10s"

# name, version command (None: no cheap version), what it's used for
TOOLS = [
    ("oc", ["oc", "version", "--client"], "the OpenShift CLI: every page"),
    ("kubectl", ["kubectl", "version", "--client"], "comes with oc: every page"),
    ("kustomize", ["kustomize", "version"], "renders your deployment repository's root (version 5 or later)"),
    ("git", ["git", "--version"], "clones and pushes your repositories"),
    ("jq", ["jq", "--version"], "used by the setup scripts and in first use"),
    ("curl", ["curl", "--version"], "used by the setup scripts and in first use"),
    ("openssl", ["openssl", "version"], "used by the setup scripts and in first use"),
    ("base64", None, "used by the setup scripts and in first use"),
    ("python3", ["python3", "--version"], "reads cluster state in the setup scripts"),
    ("htpasswd", None, "from httpd-tools: creates the break-glass admin login"),
    ("clusteradm", ["clusteradm", "version"], "imports the site into ACM"),
    ("make", ["make", "--version"], "runs make prereqs"),
]

results = []
secrets = []  # values to scrub from anything printed


def report(status, name, detail=""):
    for s in secrets:
        detail = detail.replace(s, "[redacted]")
    results.append(status)
    print(f"{status:<8} {name:<32} {detail}".rstrip())


def section(title):
    print(f"\n{title}")


def run(cmd, timeout=20):
    """Run cmd; return (rc, stdout, stderr). Never raises; a timeout is rc 124."""
    env = dict(os.environ)
    if cmd[0] in ("clusteradm",):
        env["KUBECONFIG"] = os.devnull  # version only; never reach a cluster
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"
    except OSError as e:
        return 127, "", str(e)


def first_line(text):
    for line in text.splitlines():
        if line.strip():
            return scrub(line.strip())[:160]
    return ""


def scrub(text):
    for s in secrets:
        text = text.replace(s, "[redacted]")
    # Long base64-like runs could be credentials; image digests stay readable.
    return re.sub(r"(?<!sha256:)[A-Za-z0-9+/=_-]{40,}", "[redacted]", text)


def version_of(text):
    m = re.search(r"v?(\d+)\.(\d+)(?:\.(\d+))?", text)
    return m


def check_tools():
    section("Tools")
    for name, cmd, used_for in TOOLS:
        path = shutil.which(name)
        if not path:
            report("MISSING", name, used_for)
            continue
        if not cmd:
            report("ok", name, path)
            continue
        rc, out, err = run(cmd, timeout=5)
        m = version_of(out + err)
        if name == "kustomize" and m and int(m.group(1)) < 5:
            report("OLD", name, f"{m.group(0).lstrip('v')}; version 5 or later needed")
        elif m:
            report("ok", name, m.group(0).lstrip("v"))
        else:
            report("ok", name, path)


def check_library(deployment):
    section("Library checkout")
    if not deployment:
        report("skipped", "library at your pin", "pass --deployment DIR (make prereqs does)")
        return
    k = os.path.join(deployment, "root", "kustomization.yaml")
    try:
        text = open(k).read()
    except OSError:
        report("FAIL", "library at your pin", f"can't read {k}")
        return
    m = re.search(r"^\s*libraryRevision:\s*(\S+)", text, re.M)
    if not m:
        report("FAIL", "library at your pin", f"no libraryRevision in {k}")
        return
    pin = m.group(1)
    rc, out, _ = run(["git", "-C", LIB, "rev-parse", "HEAD"], timeout=5)
    head = out.strip()
    lib = os.path.relpath(LIB)
    if rc == 0 and head == pin:
        report("ok", "library at your pin", pin[:12])
    else:
        report("FAIL", "library at your pin",
               f"{lib} is at {head[:12] or 'unknown'}, not {pin[:12]}: git -C {lib} checkout -q {pin}")


def pinned_catalog_image():
    """quay.io/rhoai/...@sha256:... from apps/rhoai/nightly.yaml, or None."""
    try:
        text = open(os.path.join(LIB, "apps", "rhoai", "nightly.yaml")).read()
    except OSError:
        return None
    vals = {}
    for key in ("registry", "repository", "tag"):
        m = re.search(rf"^\s+{key}:\s*(\S+)", text, re.M)
        if m:
            vals[key] = m.group(1).strip("'\"")
    if not {"registry", "repository", "tag"} <= vals.keys():
        return None
    tag = vals["tag"]
    ref = tag[tag.index("@"):] if "@" in tag else ":" + tag
    return f"{vals['registry']}/{vals['repository']}{ref}"


def check_registry(auth_file):
    section("Registry logins (pre-release builds)")
    names = ["auth file", "quay.io/rhoai login", "registry.stage.redhat.io login", "pull the pinned catalog"]
    if not auth_file:
        report("skipped", "registry logins", "set QUAY_AUTH_FILE to your container auth file (page 3)")
        return
    auth_file = os.path.expanduser(auth_file)
    try:
        auths = json.load(open(auth_file)).get("auths", {})
        if not isinstance(auths, dict):
            raise ValueError("auths isn't an object")
    except (OSError, ValueError, AttributeError) as e:
        report("FAIL" if os.path.exists(auth_file) else "MISSING", "auth file",
               f"{auth_file}: {type(e).__name__}")
        for n in names[1:]:
            report("skipped", n, "no readable auth file")
        return
    for entry in auths.values():
        if isinstance(entry, dict) and isinstance(entry.get("auth"), str) and entry["auth"]:
            secrets.append(entry["auth"])
            try:
                user_pass = base64.b64decode(entry["auth"]).decode()
                secrets.extend(p for p in user_pass.split(":", 1) if len(p) >= 4)
            except Exception:
                pass
    report("ok", "auth file", auth_file)

    def has(key):
        e = auths.get(key) or auths.get("https://" + key)
        return isinstance(e, dict) and bool(e.get("auth"))

    if has("quay.io/rhoai"):
        report("ok", "quay.io/rhoai login", "quay.io/rhoai entry")
    elif has("quay.io"):
        report("ok", "quay.io/rhoai login",
               "general quay.io entry: page 3 needs RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1, "
               "or add a robot token for quay.io/rhoai")
    else:
        report("MISSING", "quay.io/rhoai login", "no quay.io/rhoai or quay.io entry with an auth value")
    if has("registry.stage.redhat.io"):
        report("ok", "registry.stage.redhat.io login", "entry present (model runtime images)")
    else:
        report("MISSING", "registry.stage.redhat.io login", "sites can't pull registry.redhat.io/rhaii* images")

    image = pinned_catalog_image()
    if not image:
        report("skipped", "pull the pinned catalog", "no image in apps/rhoai/nightly.yaml")
        return
    if not shutil.which("oc"):
        report("skipped", "pull the pinned catalog", "needs oc")
        return
    rc, out, err = run(["oc", "image", "info", "--registry-config", auth_file,
                        "--filter-by-os", "linux/amd64", image], timeout=60)
    short = image.split("@")[0]
    if rc == 0:
        report("ok", "pull the pinned catalog", short)
    else:
        report("FAIL", "pull the pinned catalog", f"{short}: {first_line(err or out) or 'oc image info failed'}")


def check_cluster(label, context, site):
    section(f"{label} cluster")
    names = ["reachable", "OpenShift 4.21 or later", "cluster-admin", "default StorageClass"]
    if site:
        names.append("ClusterIssuer")
    env_var = "SITE_CONTEXT" if site else "HUB_CONTEXT"
    if not context:
        report("skipped", f"{label.lower()} checks", f"set {env_var} to the {label.lower()}'s kubeconfig context")
        return
    if not shutil.which("oc"):
        report("skipped", f"{label.lower()} checks", "needs oc")
        return

    def oc(*args):
        return run(["oc", "--context", context, OC_TIMEOUT, *args])

    rc, out, err = oc("whoami", "--show-server")
    if rc != 0:
        report("FAIL", "reachable", f"context {context}: {first_line(err) or 'oc whoami failed'}")
        for n in names[1:]:
            report("skipped", n, "cluster not reachable")
        return
    report("ok", "reachable", f"{context}: {out.strip()}")

    rc, out, err = oc("get", "clusterversion", "version", "-o", "jsonpath={.status.desired.version}")
    m = version_of(out) if rc == 0 else None
    if not m:
        report("FAIL", "OpenShift 4.21 or later", first_line(err) or "no version")
    elif (int(m.group(1)), int(m.group(2))) < MIN_OPENSHIFT:
        report("OLD", "OpenShift 4.21 or later", out.strip())
    else:
        report("ok", "OpenShift 4.21 or later", out.strip())

    rc, out, err = oc("auth", "can-i", "*", "*", "--all-namespaces")
    if out.strip() == "yes":
        report("ok", "cluster-admin", "")
    else:
        report("MISSING", "cluster-admin", first_line(out) or first_line(err) or "no")

    rc, out, err = oc("get", "storageclasses.storage.k8s.io", "-o", "json")
    try:
        items = json.loads(out).get("items", []) if rc == 0 else None
    except ValueError:
        items = None
    if items is None:
        report("FAIL", "default StorageClass", first_line(err) or "can't list StorageClasses")
    else:
        default = [i["metadata"]["name"] for i in items
                   if (i["metadata"].get("annotations") or {}).get(
                       "storageclass.kubernetes.io/is-default-class") == "true"]
        if default:
            report("ok", "default StorageClass", ", ".join(default))
        else:
            report("MISSING", "default StorageClass", "no StorageClass is marked default")

    if not site:
        return
    rc, out, err = oc("get", "clusterissuers.cert-manager.io", "-o", "json")
    try:
        items = json.loads(out).get("items", []) if rc == 0 else None
    except ValueError:
        items = None
    if items is None:
        report("MISSING", "ClusterIssuer", first_line(err) or "can't list ClusterIssuers (is cert-manager installed?)")
    elif not items:
        report("MISSING", "ClusterIssuer", "none; the site needs one that issues by DNS-01")
    else:
        parts = []
        for i in items:
            solvers = (((i.get("spec") or {}).get("acme") or {}).get("solvers")) or []
            dns01 = any(isinstance(s, dict) and s.get("dns01") for s in solvers)
            parts.append(f"{i['metadata']['name']} ({'DNS-01' if dns01 else 'no DNS-01'})")
        status = "ok" if any("(DNS-01)" in p for p in parts) else "MISSING"
        report(status, "ClusterIssuer", ", ".join(parts))


def check_catalog_token(path):
    section("Catalog token")
    if not path:
        report("skipped", "catalog token file", "set CATALOG_TOKEN_FILE (page 2)")
        return
    path = os.path.expanduser(path)
    try:
        st = os.stat(path)
    except OSError:
        report("MISSING", "catalog token file", f"{path} not found")
        return
    mode = stat.S_IMODE(st.st_mode)
    if not stat.S_ISREG(st.st_mode) or st.st_size == 0:
        report("FAIL", "catalog token file", f"{path} is empty or not a file")
    elif mode & 0o077:
        report("FAIL", "catalog token file", f"{path} is mode {mode:o}; run chmod 600 {path}")
    else:
        report("ok", "catalog token file", f"{path} (mode {mode:o}, not empty)")


def main():
    p = argparse.ArgumentParser(
        description="Report which AI Grid install prerequisites you have. Never blocks; always exits 0.")
    p.add_argument("--deployment", help="your deployment repository (checks the library checkout is at its pin)")
    p.add_argument("--hub-context", default=os.environ.get("HUB_CONTEXT"), help="hub kubeconfig context [HUB_CONTEXT]")
    p.add_argument("--site-context", default=os.environ.get("SITE_CONTEXT"), help="site kubeconfig context [SITE_CONTEXT]")
    p.add_argument("--quay-auth-file", default=os.environ.get("QUAY_AUTH_FILE"),
                   help="container auth file with the pre-release registry logins [QUAY_AUTH_FILE]")
    p.add_argument("--catalog-token-file", default=os.environ.get("CATALOG_TOKEN_FILE"),
                   help="file holding the catalog repository token [CATALOG_TOKEN_FILE]")
    a = p.parse_args()

    check_tools()
    check_library(a.deployment)
    check_registry(a.quay_auth_file)
    check_cluster("Hub", a.hub_context, site=False)
    check_cluster("Site", a.site_context, site=True)
    check_catalog_token(a.catalog_token_file)

    counts = {s: results.count(s) for s in ("ok", "MISSING", "OLD", "FAIL", "skipped")}
    print("\n" + ", ".join(f"{n} {s.lower()}" for s, n in counts.items() if n))
    if counts["MISSING"] or counts["OLD"] or counts["FAIL"]:
        print("Nothing was changed; fix these before the page that needs them.")
    return 0


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as e:  # never block the install on a bug in this script
        print(f"FAIL     prereqs.py                       internal error: {type(e).__name__}")
    sys.exit(0)
