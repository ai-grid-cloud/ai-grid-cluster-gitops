#!/usr/bin/env python3
"""Checks that the library holds no deployment's values and that a deployment
supplies every input.

A deployment sets each input once, in the root ApplicationSet's generator
values; the library refers to it as @<name>@. The root's templatePatch replaces
those tokens in every generated Application. Directories that hold nested
ApplicationSets or input-dependent manifests are kustomizations with a
local-config ConfigMap library-inputs (values REQUIRED-<name>) and
replacements, which the owning application.yaml patches with the same tokens.

Checks, each reported as ok or FAIL:
  static-revision  no upstream URL and no HEAD revision under apps/, bootstrap/,
                   cluster-config/ (Markdown, tests and upstream's lab entry
                   points excepted)
  components       each apps/*/application.yaml and cluster-config/application.yaml,
                   with sample-inputs.yaml substituted the way the root does it,
                   resolves: no @token@ or REQUIRED- left, every git source is the
                   library, the deployment, the catalog or a known external
                   repository at the matching revision, and every kustomization
                   it reads builds with the Application's own patches
  bare-inputs      each directory with an inputs.yaml builds without patches and
                   shows its inputs as REQUIRED-<name>

Run: bash tests/library/inputs-test.sh   (needs python3 with PyYAML, kustomize)
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SAMPLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample-inputs.yaml")

STATIC_DIRS = ("apps", "bootstrap", "cluster-config")
# Upstream's lab entry points, which a fork points at itself with
# scripts/set-tenant-repo.sh: the two self-syncing roots, the dedicated root's
# own Application and the ACM foundation Application. They name this
# repository directly and set every input to the lab's value.
LEGACY_ROOTS = {
    "bootstrap/applicationset.yaml",
    "bootstrap/dedicated-hub/applicationset.yaml",
    "bootstrap/dedicated-hub/application.yaml",
    "bootstrap/foundation-acm-application.yaml",
}
REVISION_PATTERNS = [
    re.compile(r"ai-grid-cloud/ai-grid-cluster-gitops"),
    re.compile(r"\b(target)?[rR]evision:\s*['\"]?HEAD\b"),
]
# Repositories a component may read that no deployment chooses: products and
# charts the library pins itself.
EXTERNAL_PREFIXES = (
    "https://github.com/opendatahub-io/",
    "https://github.com/ai-grid-cloud/ai-grid-provider-console",
    "oci://",
    # The lab's catalog, until the catalog repository is an input.
    "https://github.com/ai-grid-cloud/ai-grid-shared-catalog.git",
)
TOKEN = re.compile(r"@[a-zA-Z]+@")

failures = []
results = []


def check(name):
    def wrap(fn):
        def run(*args):
            before = len(failures)
            fn(*args)
            new = failures[before:]
            results.append((name, not new))
            print(("   ok   " if not new else "   FAIL ") + name)
            for item in new:
                print("          - " + item)
        return run
    return wrap


def fail(message):
    failures.append(message)


def rel(path):
    return os.path.relpath(path, ROOT)


def library_files(dirs):
    for top in dirs:
        for base, subdirs, files in os.walk(os.path.join(ROOT, top)):
            subdirs[:] = [d for d in subdirs if d not in (".git", "tests")]
            for name in sorted(files):
                yield os.path.join(base, name)


def load_inputs():
    with open(SAMPLE) as handle:
        return yaml.safe_load(handle)


def substitute(text, inputs):
    for key, value in inputs.items():
        text = text.replace("@%s@" % key, str(value))
    return text


def grep(patterns, label):
    for path in library_files(STATIC_DIRS):
        relative = rel(path)
        if relative.endswith(".md") or relative in LEGACY_ROOTS:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                lines = handle.readlines()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(lines, 1):
            if any(p.search(line) for p in patterns):
                fail("%s:%d: %s: %s" % (relative, number, label, line.strip()))


@check("static-revision")
def static_revision():
    grep(REVISION_PATTERNS, "upstream self-reference")


def classify(repo, inputs):
    for kind in ("library", "deployment", "catalog"):
        if kind + "RepoURL" in inputs and repo == inputs[kind + "RepoURL"]:
            return kind, inputs[kind + "Revision"]
    if repo.startswith(EXTERNAL_PREFIXES):
        return "external", None
    return None, None


def check_repo(where, repo, revision, inputs):
    kind, expected = classify(repo, inputs)
    if kind is None:
        fail("%s: repository %s is not an input or a known external repository" % (where, repo))
    elif expected is not None and revision != expected:
        fail("%s: %s repository at revision %r, not the %s input" % (where, kind, revision, kind + "Revision"))
    return kind


def sources_of(spec):
    if "source" in spec:
        return [spec["source"]]
    return spec.get("sources") or []


def walk_generators(generators):
    for generator in generators or []:
        for kind, body in generator.items():
            if not isinstance(body, dict):
                continue
            if kind == "git":
                yield body
            if kind in ("matrix", "merge"):
                yield from walk_generators(body.get("generators"))


def check_nested(where, documents, inputs):
    """Repositories that nested ApplicationSets and Applications name."""
    for doc in documents:
        if not isinstance(doc, dict) or doc.get("apiVersion", "").split("/")[0] != "argoproj.io":
            continue
        name = "%s %s/%s" % (where, doc.get("kind"), doc.get("metadata", {}).get("name"))
        if doc.get("kind") == "ApplicationSet":
            for git in walk_generators(doc.get("spec", {}).get("generators")):
                check_repo(name + " git generator", git.get("repoURL", ""), git.get("revision"), inputs)
            spec = doc.get("spec", {}).get("template", {}).get("spec", {})
        elif doc.get("kind") == "Application":
            spec = doc.get("spec", {})
        else:
            continue
        for source in sources_of(spec):
            kind = check_repo(name + " source", source.get("repoURL", ""), source.get("targetRevision"), inputs)
            path = source.get("path")
            if kind == "library" and path and "{{" not in path and not os.path.isdir(os.path.join(ROOT, path)):
                fail("%s: library path %s does not exist" % (name, path))


def scan_text(where, text):
    for token in sorted(set(TOKEN.findall(text))):
        fail("%s: input %s left unresolved" % (where, token))
    if "REQUIRED-" in text:
        names = sorted(set(re.findall(r"REQUIRED-[A-Za-z]+", text)))
        fail("%s: input not supplied: %s" % (where, ", ".join(names)))


def kustomize_build(directory, patches=None):
    """Builds directory as Argo CD does: Application patches appended to the
    kustomization's own patches, in a copy of the tree."""
    work = tempfile.mkdtemp(prefix="inputs-test-")
    try:
        copy = os.path.join(work, "tree")
        shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".git", ".worktrees"))
        target = os.path.join(copy, rel(directory))
        kfile = os.path.join(target, "kustomization.yaml")
        if patches:
            with open(kfile) as handle:
                kustomization = yaml.safe_load(handle)
            kustomization["patches"] = (kustomization.get("patches") or []) + patches
            with open(kfile, "w") as handle:
                yaml.safe_dump(kustomization, handle, sort_keys=False)
        result = subprocess.run(["kustomize", "build", target], capture_output=True, text=True)
        if result.returncode != 0:
            return None, result.stderr.strip()
        return result.stdout, None
    finally:
        shutil.rmtree(work, ignore_errors=True)


def read_directory(directory, recurse):
    texts = []
    for base, subdirs, files in os.walk(directory):
        if not recurse:
            subdirs[:] = []
        for name in sorted(files):
            if name.endswith((".yaml", ".yml", ".json")):
                with open(os.path.join(base, name)) as handle:
                    texts.append(handle.read())
    return "\n---\n".join(texts)


def component_files():
    paths = sorted(
        os.path.join("apps", name, "application.yaml")
        for name in os.listdir(os.path.join(ROOT, "apps"))
        if os.path.isfile(os.path.join(ROOT, "apps", name, "application.yaml"))
    )
    # Components one level deeper, such as apps/object-storage/<option>.
    for name in sorted(os.listdir(os.path.join(ROOT, "apps"))):
        group = os.path.join(ROOT, "apps", name)
        if os.path.isdir(group) and not os.path.isfile(os.path.join(group, "application.yaml")):
            for option in sorted(os.listdir(group)):
                if os.path.isfile(os.path.join(group, option, "application.yaml")):
                    paths.append(os.path.join("apps", name, option, "application.yaml"))
    paths.append(os.path.join("cluster-config", "application.yaml"))
    return paths


@check("components")
def components(inputs):
    for path in component_files():
        with open(os.path.join(ROOT, path)) as handle:
            text = substitute(handle.read(), inputs)
        scan_text(path, text)
        app = yaml.safe_load(text)
        for index, source in enumerate(sources_of(app.get("spec", {}))):
            where = "%s source %d" % (path, index)
            kind = check_repo(where, source.get("repoURL", ""), source.get("targetRevision"), inputs)
            if kind != "library" or not source.get("path"):
                continue
            directory = os.path.join(ROOT, source["path"])
            if not os.path.isdir(directory):
                fail("%s: library path %s does not exist" % (where, source["path"]))
                continue
            if os.path.isfile(os.path.join(directory, "Chart.yaml")):
                continue
            kustomize = source.get("kustomize")
            if os.path.isfile(os.path.join(directory, "kustomization.yaml")):
                if "directory" in source:
                    fail("%s: a kustomize source can't use directory include or exclude" % where)
                output, error = kustomize_build(directory, (kustomize or {}).get("patches"))
                if error:
                    fail("%s: kustomize build %s failed: %s" % (where, source["path"], error.splitlines()[-1]))
                    continue
            else:
                if kustomize:
                    fail("%s: kustomize options on %s, which has no kustomization.yaml" % (where, source["path"]))
                output = read_directory(directory, (source.get("directory") or {}).get("recurse", False))
            scan_text("%s (%s)" % (where, source["path"]), output)
            check_nested("%s (%s)" % (where, source["path"]), list(yaml.safe_load_all(output)), inputs)


@check("bare-inputs")
def bare_inputs():
    found = 0
    for path in library_files(STATIC_DIRS):
        if os.path.basename(path) != "inputs.yaml":
            continue
        found += 1
        directory = os.path.dirname(path)
        output, error = kustomize_build(directory)
        if error:
            fail("%s: kustomize build failed: %s" % (rel(directory), error.splitlines()[-1]))
        elif "REQUIRED-" not in output:
            fail("%s: a bare build shows no REQUIRED- input" % rel(directory))
    if not found:
        fail("no directory declares its inputs (inputs.yaml)")


def main():
    inputs = load_inputs()
    static_revision()
    components(inputs)
    bare_inputs()
    failed = sum(1 for _, ok in results if not ok)
    print("inputs tests: %d ok, %d failed" % (len(results) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
