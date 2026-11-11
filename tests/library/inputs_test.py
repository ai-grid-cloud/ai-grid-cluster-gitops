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
  static-catalog   no lab catalog repository under those directories
  components       each apps/*/application.yaml and cluster-config/application.yaml,
                   with sample-inputs.yaml substituted the way the root does it,
                   resolves: no @token@ or REQUIRED- left, every git source is the
                   library, the deployment, the catalog or a known external
                   repository at the matching revision, and every kustomization
                   it reads builds with the Application's own patches
  bare-inputs      each directory with an inputs.yaml builds without patches and
                   shows its inputs as REQUIRED-<name>
  root             bootstrap/hub/applicationset.yaml lists every component and
                   marks its repository, revision and every input REQUIRED-
  root-render      each listed component through the root's templatePatch,
                   rendered as the ApplicationSet controller does
                   (tests/library/templatepatch, needs Go), passes the
                   components checks; an input left out or left REQUIRED- fails
                   with "missing input: <name>", an empty one or one with
                   ", ', \\ or @ with "invalid input: <name>"
  deployment-values  per-cluster rhoai values and the grid's values (its CA
                   mode) come from the deployment repository, not the library
  admins           no user names in cluster-config/ or apps/gitops-config/;
                   cluster admins come from the deployment's values
  object-storage   ACM renders no bucket; apps/object-storage offers ODF and S4,
                   each its own component, S4's credentials from Password
                   generators, never literal Secrets
  idp              the tenant Policy reads the IdP inputs (issuer, client,
                   client-secret Secret, CA ConfigMap), no manifest outside
                   apps/keycloak names the library's Keycloak, and the Policy's
                   ServiceAccount can read both inputs, by name only
  keycloak-separable  nothing outside apps/keycloak* installs or includes
                   Keycloak (the lab entry points excepted)
  samples          no model, MaaS object or subscription outside the selectable
                   apps/acm-models-samples component
  move-guards      objects moved between Applications carry Prune=false
  lab-roots        each Application upstream's lab roots generate, through
                   their own templatePatch, resolves every input to the lab's
                   value and passes the components checks (needs Go)

Run: bash tests/library/inputs-test.sh   (needs python3 with PyYAML, kustomize)
"""

import fnmatch
import glob
import json
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
CATALOG_PATTERNS = [re.compile(r"ai-grid-shared-catalog")]
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


@check("static-catalog")
def static_catalog():
    grep(CATALOG_PATTERNS, "lab catalog")


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


def glob_match(name, pattern):
    """Argo CD's directory include and exclude: a glob, or {a,b} of globs."""
    if pattern.startswith("{") and pattern.endswith("}"):
        return any(fnmatch.fnmatchcase(name, item) for item in pattern[1:-1].split(","))
    return fnmatch.fnmatchcase(name, pattern)


def read_directory(directory, recurse, include=None, exclude=None):
    texts = []
    for base, subdirs, files in os.walk(directory):
        if not recurse:
            subdirs[:] = []
        for name in sorted(files):
            relative = os.path.relpath(os.path.join(base, name), directory)
            if include and not glob_match(relative, include):
                continue
            if exclude and glob_match(relative, exclude):
                continue
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


def check_application(where, app, inputs):
    """One Application's sources, and what each library source renders.
    Returns the rendered objects of its library sources."""
    rendered = []
    scan_text(where, yaml.safe_dump(app))
    for index, source in enumerate(sources_of(app.get("spec", {}))):
        source_where = "%s source %d" % (where, index)
        kind = check_repo(source_where, source.get("repoURL", ""), source.get("targetRevision"), inputs)
        if kind != "library" or not source.get("path"):
            continue
        directory = os.path.join(ROOT, source["path"])
        if not os.path.isdir(directory):
            fail("%s: library path %s does not exist" % (source_where, source["path"]))
            continue
        if os.path.isfile(os.path.join(directory, "Chart.yaml")):
            continue
        kustomize = source.get("kustomize")
        if os.path.isfile(os.path.join(directory, "kustomization.yaml")):
            if "directory" in source:
                fail("%s: a kustomize source can't use directory include or exclude" % source_where)
            output, error = kustomize_build(directory, (kustomize or {}).get("patches"))
            if error:
                fail("%s: kustomize build %s failed: %s" % (source_where, source["path"], error.splitlines()[-1]))
                continue
        else:
            if kustomize:
                fail("%s: kustomize options on %s, which has no kustomization.yaml" % (source_where, source["path"]))
            options = source.get("directory") or {}
            output = read_directory(directory, options.get("recurse", False),
                                    options.get("include"), options.get("exclude"))
        # Scan the objects, not the files' comments.
        output = yaml.safe_dump_all([doc for doc in yaml.safe_load_all(output) if doc])
        scan_text("%s (%s)" % (source_where, source["path"]), output)
        documents = [doc for doc in yaml.safe_load_all(output) if isinstance(doc, dict)]
        check_nested("%s (%s)" % (source_where, source["path"]), documents, inputs)
        rendered.extend(documents)
    return rendered


@check("components")
def components(inputs):
    for path in component_files():
        with open(os.path.join(ROOT, path)) as handle:
            text = substitute(handle.read(), inputs)
        check_application(path, yaml.safe_load(text), inputs)


ROOT_APPSET = os.path.join("bootstrap", "hub", "applicationset.yaml")
ODF = os.path.join("apps", "odf", "application.yaml")


def load(path):
    with open(os.path.join(ROOT, path)) as handle:
        return yaml.safe_load(handle)


def load_root():
    with open(os.path.join(ROOT, ROOT_APPSET)) as handle:
        return yaml.safe_load(handle)


def check_generator(where, git, inputs):
    if git.get("repoURL") != "REQUIRED-libraryRepoURL" or git.get("revision") != "REQUIRED-libraryRevision":
        fail("%s: repoURL and revision must be REQUIRED-libraryRepoURL and REQUIRED-libraryRevision" % where)
    values = git.get("values") or {}
    if set(values) != set(inputs):
        fail("%s: values keys %s, not the inputs %s" % (where, sorted(values), sorted(inputs)))
    for key, value in values.items():
        if value != "REQUIRED-" + key:
            fail("%s: values.%s is %r, not REQUIRED-%s" % (where, key, value, key))


@check("root")
def root(inputs):
    if not os.path.isfile(os.path.join(ROOT, ROOT_APPSET)):
        fail("%s is missing" % ROOT_APPSET)
        return
    with open(os.path.join(ROOT, "bootstrap", "hub", "kustomization.yaml")) as handle:
        if "applicationset.yaml" not in (yaml.safe_load(handle).get("resources") or []):
            fail("bootstrap/hub/kustomization.yaml does not list applicationset.yaml")
    generators = load_root()["spec"]["generators"]
    first = generators[0]["git"]
    check_generator("generator 0", first, inputs)
    listed = {item["path"] for item in first.get("files", [])}
    expected = set(component_files()) - {ODF}
    if listed != expected:
        fail("generator 0 files: missing %s, extra %s" % (sorted(expected - listed), sorted(listed - expected)))
    odf = generators[1]["matrix"]["generators"][0]["git"]
    check_generator("generator 1 (ODF)", odf, inputs)
    if [item["path"] for item in odf.get("files", [])] != [ODF]:
        fail("generator 1 must list only %s" % ODF)


def template_patch_renderer():
    """Builds tests/library/templatepatch, which renders a templatePatch as the
    ApplicationSet controller does. None if Go isn't installed."""
    if not shutil.which("go"):
        return None
    out = os.path.join(tempfile.mkdtemp(prefix="templatepatch-"), "templatepatch")
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templatepatch")
    env = dict(os.environ, GOFLAGS="-mod=mod")
    result = subprocess.run(["go", "build", "-o", out, "."], cwd=source, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        fail("go build tests/library/templatepatch: %s" % result.stderr.strip())
        return None
    return out


def render_patch(renderer, appset, params):
    request = {"templatePatch": appset["spec"]["templatePatch"],
               "options": appset["spec"].get("goTemplateOptions", []), "params": params}
    result = subprocess.run([renderer], input=json.dumps(request), capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr.strip()
    return yaml.safe_load(result.stdout), None


def root_params(path, values):
    with open(os.path.join(ROOT, path)) as handle:
        params = yaml.safe_load(handle)
    if path == ODF:
        # The matrix's clusters generator adds the hub's labels.
        params["metadata"]["labels"] = {"openshiftVersion-major-minor": "4.21"}
    params["path"] = {"path": os.path.dirname(path), "filename": os.path.basename(path)}
    params["values"] = dict(values)
    return params


@check("root-render")
def root_render(inputs):
    if not os.path.isfile(os.path.join(ROOT, ROOT_APPSET)):
        fail("%s is missing" % ROOT_APPSET)
        return
    renderer = template_patch_renderer()
    if renderer is None:
        if not failures or "go build" not in failures[-1]:
            print("          (skipped: go is not installed)")
        return
    appset = load_root()
    first = appset["spec"]["generators"][0]["git"]
    paths = [item["path"] for item in first["files"]] + [ODF]
    bindings = []
    for path in paths:
        patch, error = render_patch(renderer, appset, root_params(path, inputs))
        if error:
            fail("%s: templatePatch failed: %s" % (path, error))
            continue
        for doc in check_application("%s through the root" % path, {"spec": patch["spec"]}, inputs):
            meta = doc.get("metadata", {})
            if (doc.get("kind"), meta.get("namespace"), meta.get("name")) == \
                    ("ManagedClusterSetBinding", "redhat-ai-grid", "global"):
                bindings.append(path)
    # The grid-enrollment invite Placements select through the global cluster
    # set bound into redhat-ai-grid. The root deletes rhoai's binding, so the
    # grid-enrollment chart (an external chart) must render it, from the
    # library's own grid values.
    grid = load("apps/grid-bootstrap/values.yaml").get("managedClusters", {})
    if grid.get("createClusterSetBinding") is True:
        bindings.append("apps/grid-bootstrap (managedClusters.createClusterSetBinding)")
    if len(bindings) != 1:
        fail("exactly one component must bind global into redhat-ai-grid, found %s" % (bindings or "none"))
    # A deployment that leaves out an input, or leaves its REQUIRED- default,
    # gets an error naming it and no Application.
    for name, values in (("left out", {k: v for k, v in inputs.items() if k != "libraryRevision"}),
                         ("not set", dict(inputs, libraryRevision="REQUIRED-libraryRevision"))):
        _, error = render_patch(renderer, appset, root_params("apps/acm/application.yaml", values))
        if not error or "missing input: libraryRevision" not in error:
            fail("an input %s must fail with 'missing input: libraryRevision', got %r" % (name, error))
    # A value that's empty, or that would break the JSON or YAML it's replaced
    # into, fails naming the input, for every component.
    for label, value in (("empty", ""), ("a double quote", 'a"b'), ("a single quote", "a'b"),
                         ("a backslash", "a\\b"), ("an at sign", "a@b")):
        _, error = render_patch(renderer, appset,
                                root_params("apps/acm/application.yaml", dict(inputs, libraryRevision=value)))
        if not error or "invalid input: libraryRevision" not in error:
            fail("an input with %s must fail with 'invalid input: libraryRevision', got %r" % (label, error))


LAB_ROOTS = (os.path.join("bootstrap", "applicationset.yaml"),
             os.path.join("bootstrap", "dedicated-hub", "applicationset.yaml"))


def lab_files(git):
    """The component files a lab root's git files generator selects."""
    selected = set()
    for item in git.get("files", []):
        matches = {rel(p) for p in glob.glob(os.path.join(ROOT, item["path"]))}
        if item.get("exclude"):
            selected -= matches
        else:
            selected |= matches
    return sorted(selected)


@check("lab-roots")
def lab_roots():
    """Upstream's lab roots (and a fork's, after scripts/set-tenant-repo.sh)
    set every input themselves: repoURL and targetRevision in each generator's
    values are this repository, which is also their deployment repository."""
    renderer = template_patch_renderer()
    if renderer is None:
        if not failures or "go build" not in failures[-1]:
            print("          (skipped: go is not installed)")
        return
    for root_path in LAB_ROOTS:
        appset = load(root_path)
        # The templatePatch reads the values of whichever generator produced
        # the Application, so every generator carries the same ones.
        all_values = [(generator.get("git") or generator["matrix"]["generators"][0]["git"]).get("values")
                      for generator in appset["spec"]["generators"]]
        if any(values != all_values[0] for values in all_values):
            fail("%s: the generators' values differ" % root_path)
        for index, generator in enumerate(appset["spec"]["generators"]):
            git = generator.get("git") or generator["matrix"]["generators"][0]["git"]
            values = git.get("values") or {}
            if values.get("repoURL") != git.get("repoURL") or values.get("targetRevision") != git.get("revision"):
                fail("%s generator %d: values repoURL and targetRevision must equal the generator's" % (root_path, index))
                continue
            lab = {key: value for key, value in values.items() if key not in ("repoURL", "targetRevision")}
            for kind in ("library", "deployment"):
                lab[kind + "RepoURL"], lab[kind + "Revision"] = values["repoURL"], values["targetRevision"]
            for path in lab_files(git):
                params = root_params(path, values)
                if "matrix" in generator:
                    params["metadata"]["labels"] = {"openshiftVersion-major-minor": "4.21"}
                patch, error = render_patch(renderer, appset, params)
                if error:
                    fail("%s: %s: templatePatch failed: %s" % (root_path, path, error))
                    continue
                where = "%s through %s" % (path, root_path)
                if path in LEGACY_ROOTS:
                    # The dedicated root's own Application: it syncs the root,
                    # whose templatePatch names the tokens it replaces.
                    scan_text(where, yaml.safe_dump(patch["spec"]))
                    continue
                check_application(where, {"spec": patch["spec"]}, lab)


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


def helm_source(sources, predicate):
    return next((source for source in sources if predicate(source)), None)


@check("deployment-values")
def deployment_values():
    """Per-cluster and grid values come from the deployment repository."""
    appset = load("apps/rhoai/hub/01-applicationset.yaml")
    sources = appset["spec"]["template"]["spec"]["sources"]
    if not any(source.get("ref") == "deployment" for source in sources):
        fail("apps/rhoai/hub/01-applicationset.yaml: no source with ref deployment")
    site_file = "$deployment/values/clusters/{{ .name }}/rhoai.yaml"
    for label, predicate in (("rhai-on-openshift", lambda s: (s.get("helm") or {}).get("releaseName") == "rhai-on-openshift"),
                             ("gateway-hostname", lambda s: s.get("path") == "apps/rhoai/gateway-hostname")):
        source = helm_source(sources, predicate)
        helm = (source or {}).get("helm") or {}
        files = helm.get("valueFiles") or []
        if not files or files[-1] != site_file:
            fail("rhoai %s: the last value file must be %s, got %s" % (label, site_file, files))
        if any("values-{{" in item for item in files):
            fail("rhoai %s: still reads per-cluster values from the library: %s" % (label, files))
        if not helm.get("ignoreMissingValueFiles"):
            fail("rhoai %s: an inference site has no per-cluster file; set ignoreMissingValueFiles" % label)
    stray = [name for name in os.listdir(os.path.join(ROOT, "apps", "rhoai")) if re.match(r"values-.+\.yaml$", name)]
    if stray:
        fail("apps/rhoai holds per-cluster values: %s" % stray)

    app = load("apps/grid-bootstrap/application.yaml")
    sources = app["spec"]["sources"]
    if not any(source.get("ref") == "deployment" for source in sources):
        fail("apps/grid-bootstrap/application.yaml: no source with ref deployment")
    chart = helm_source(sources, lambda s: "helm" in s)
    files = (chart or {}).get("helm", {}).get("valueFiles") or []
    if files != ["$values/apps/grid-bootstrap/values.yaml", "$deployment/values/grid-bootstrap.yaml"]:
        fail("grid-bootstrap value files are %s" % files)
    if (chart or {}).get("helm", {}).get("ignoreMissingValueFiles"):
        fail("grid-bootstrap: the deployment's grid values are required, not optional")
    ca = (load("apps/grid-bootstrap/values.yaml").get("external") or {}).get("certManager", {}).get("ca") or {}
    if "mode" in ca or "secretName" in ca:
        fail("apps/grid-bootstrap/values.yaml chooses the grid CA mode; the deployment states it")
    if os.path.isfile(os.path.join(ROOT, ROOT_APPSET)) and "external.certManager.ca.mode" in load(ROOT_APPSET)["spec"]["templatePatch"]:
        fail("the root's templatePatch sets the grid CA mode; the deployment states it")


@check("admins")
def admins():
    """Who administers a cluster is the deployment's choice."""
    if os.path.exists(os.path.join(ROOT, "cluster-config", "cluster-admins.yaml")):
        fail("cluster-config/cluster-admins.yaml lists a deployment's admins")
    for path in library_files(("cluster-config", os.path.join("apps", "gitops-config"))):
        if not path.endswith((".yaml", ".yml")) or "/templates/" in path:
            continue
        with open(path) as handle:
            for doc in yaml.safe_load_all(handle):
                if isinstance(doc, dict) and doc.get("kind") == "Group" and doc.get("users"):
                    fail("%s: Group %s lists users" % (rel(path), doc["metadata"]["name"]))
                if isinstance(doc, dict) and doc.get("cluster_admins"):
                    fail("%s: cluster_admins lists users" % rel(path))
    appset = load("cluster-config/hub/00-applicationset.yaml")
    sources = appset["spec"]["template"]["spec"]["sources"]
    if not any(source.get("ref") == "deployment" for source in sources):
        fail("cluster-config/hub/00-applicationset.yaml: no source with ref deployment")
    chart = helm_source(sources, lambda s: "helm" in s)
    files = (chart or {}).get("helm", {}).get("valueFiles") or []
    if files != ["$values/cluster-config/values.yaml", "$deployment/values/cluster-admins.yaml"]:
        fail("cluster-config value files are %s" % files)
    # Required: a missing or misspelled file would render no binding and prune
    # every cluster-admin. A deployment that wants none ships cluster_admins: [].
    if (chart or {}).get("helm", {}).get("ignoreMissingValueFiles"):
        fail("cluster-config: values/cluster-admins.yaml must be required, not ignoreMissingValueFiles")


OBJECT_STORAGE = os.path.join("apps", "object-storage")
# Loki's bucket: ai-grid-o11y has no object-storage input yet (a known gap).
OBC_ALLOWED = (os.path.join(OBJECT_STORAGE, "odf") + os.sep, os.path.join("apps", "ai-grid-o11y") + os.sep)


@check("object-storage")
def object_storage(inputs):
    """Object storage is a contract (Secret thanos-object-storage, key
    thanos.yaml) that a selectable option or the deployment fulfils."""
    with open(os.path.join(ROOT, "apps", "acm", "application.yaml")) as handle:
        app = yaml.safe_load(substitute(handle.read(), inputs))
    output, error = kustomize_build(os.path.join(ROOT, "apps", "acm", "manifests"),
                                    app["spec"]["source"]["kustomize"]["patches"])
    if error:
        fail("apps/acm/manifests: kustomize build failed: %s" % error.splitlines()[-1])
    else:
        kinds = {(doc["kind"], doc["metadata"]["name"]) for doc in yaml.safe_load_all(output) if doc}
        for kind, name in sorted(kinds):
            if kind == "ObjectBucketClaim" or name == "mco-thanos-bridge":
                fail("apps/acm/manifests renders %s %s: object storage is a separate option" % (kind, name))
    for path in library_files(("apps",)):
        relative = rel(path)
        if relative.startswith(OBC_ALLOWED) or not relative.endswith(".yaml") or "/templates/" in relative:
            continue
        with open(path) as handle:
            if re.search(r"^kind: ObjectBucketClaim", handle.read(), re.M):
                fail("%s: an ObjectBucketClaim outside the ODF object-storage option" % relative)
    for option in ("odf", "s4"):
        if not os.path.isfile(os.path.join(ROOT, OBJECT_STORAGE, option, "application.yaml")):
            fail("%s/%s/application.yaml is missing" % (OBJECT_STORAGE, option))
    if not os.path.isfile(os.path.join(ROOT, OBJECT_STORAGE, "README.md")):
        fail("%s/README.md (the contract) is missing" % OBJECT_STORAGE)
    s4 = os.path.join(ROOT, OBJECT_STORAGE, "s4", "manifests")
    if not os.path.isdir(s4):
        return
    documents = [doc for doc in yaml.safe_load_all(read_directory(s4, False)) if doc]
    for doc in documents:
        if doc["kind"] == "Secret" and (doc.get("data") or doc.get("stringData")):
            fail("s4: Secret %s holds literal data in git" % doc["metadata"]["name"])
    contract = [doc for doc in documents if doc["kind"] == "ExternalSecret"
                and doc["spec"]["target"]["name"] == "thanos-object-storage"]
    if not contract:
        fail("s4: no ExternalSecret writes Secret thanos-object-storage")
    for doc in contract:
        if "thanos.yaml" not in ((doc["spec"]["target"].get("template") or {}).get("data") or {}):
            fail("s4: ExternalSecret %s doesn't render key thanos.yaml" % doc["metadata"]["name"])
        generators = [item["sourceRef"]["generatorRef"]["kind"] for item in doc["spec"].get("dataFrom", [])
                      if "generatorRef" in item.get("sourceRef", {})]
        if not generators or set(generators) != {"Password"}:
            fail("s4: credentials must come from Password generators, got %s" % generators)


# The library Keycloak's namespace, Secret, realm and client. "tenant-demo" is
# also the start of the spoke Secret's name, tenant-demo-oidc-client, kept so
# existing sites don't see it renamed.
IDP_FORBIDDEN = ('"maas-db"', "keycloak-secrets", "realms/saas", re.compile(r"tenant-demo(?!-oidc-client)"))


def names(text, word):
    if isinstance(word, str):
        return word in text
    return bool(word.search(text))


def strings(node):
    if isinstance(node, dict):
        for value in node.values():
            yield from strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)
    elif isinstance(node, str):
        yield node


def rendered_rhoai_hub(inputs):
    with open(os.path.join(ROOT, "apps", "rhoai", "application.yaml")) as handle:
        app = yaml.safe_load(substitute(handle.read(), inputs))
    output, error = kustomize_build(os.path.join(ROOT, "apps", "rhoai", "hub"),
                                    app["spec"]["source"]["kustomize"]["patches"])
    if error:
        fail("apps/rhoai/hub: kustomize build failed: %s" % error.splitlines()[-1])
        return []
    return [doc for doc in yaml.safe_load_all(output) if doc]


@check("idp")
def idp(inputs):
    """The tenant IdP is an input: the tenant Policy names no Keycloak."""
    for path in library_files((os.path.join("apps", "rhoai"),)):
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for word in IDP_FORBIDDEN:
            if names(text, word):
                fail("%s names %s, the library's Keycloak" % (rel(path), getattr(word, "pattern", word)))
    # Outside apps/keycloak, no manifest may reach the library's Keycloak by
    # its Route, Secret, realm or client ("maas-db" alone is also the
    # database's namespace, so it's checked only in apps/rhoai).
    keycloak = os.path.join("apps", "keycloak") + os.sep
    for path in library_files(("apps",)):
        relative = rel(path)
        if relative.startswith(keycloak) or not relative.endswith((".yaml", ".json")):
            continue
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for word in IDP_FORBIDDEN[1:] + ('"Route" "maas-db" "keycloak"',):
            if names(text, word) and not relative.startswith(os.path.join("apps", "rhoai") + os.sep):
                fail("%s names %s, the library's Keycloak; that belongs in apps/keycloak"
                     % (relative, getattr(word, "pattern", word)))
    documents = rendered_rhoai_hub(inputs)
    policy = next((doc for doc in documents if doc["kind"] == "Policy"
                   and doc["metadata"]["name"] == "rhoai-ingress-clusters"), None)
    if not policy:
        fail("apps/rhoai/hub renders no Policy rhoai-ingress-clusters")
        return
    text = "\n".join(strings(policy))
    for key in ("idpIssuerURL", "idpClientID"):
        if inputs[key] not in text:
            fail("the tenant Policy doesn't carry %s (%s)" % (key, inputs[key]))
    secret_template = 'fromSecret "%s" "%s" "%s"' % (inputs["idpClientSecretNamespace"],
                                                   inputs["idpClientSecretName"], inputs["idpClientSecretKey"])
    if secret_template not in text:
        fail("the tenant Policy doesn't read the client secret input: %s" % secret_template)
    ca_template = 'fromConfigMap "%s" "%s" "%s"' % (inputs["idpCANamespace"], inputs["idpCAName"], inputs["idpCAKey"])
    if ca_template not in text:
        fail("the tenant Policy doesn't read the CA input: %s" % ca_template)
    # Hub templates resolve as the Policy's ServiceAccount, which must be able
    # to read the input Secret and ConfigMap where they are.
    account = policy["spec"]["hubTemplateOptions"]["serviceAccountName"]
    bound = {doc["metadata"]["namespace"]: doc["roleRef"]["name"] for doc in documents
             if doc["kind"] == "RoleBinding"
             and {"kind": "ServiceAccount", "name": account, "namespace": "redhat-ai-grid"} in doc.get("subjects", [])}
    roles = {(doc["metadata"]["namespace"], doc["metadata"]["name"]): doc for doc in documents if doc["kind"] == "Role"}
    for namespace, resource, name in ((inputs["idpClientSecretNamespace"], "secrets", inputs["idpClientSecretName"]),
                                      (inputs["idpCANamespace"], "configmaps", inputs["idpCAName"])):
        role = roles.get((namespace, bound.get(namespace)))
        rules = (role or {}).get("rules", [])
        if not any(resource in rule.get("resources", []) and "get" in rule.get("verbs", [])
                   and name in rule.get("resourceNames", [name]) for rule in rules):
            fail("ServiceAccount %s can't get %s %s in namespace %s" % (account, resource, name, namespace))
        # ACM's dependency watcher lists and watches a named object with a
        # metadata.name field selector, which RBAC authorizes by resourceNames,
        # so no rule needs the whole namespace (the input namespace may hold
        # other Secrets, such as an IdP's admin credentials).
        for rule in rules:
            if rule.get("resourceNames") != [name]:
                fail("Role %s/%s: rule %s isn't limited to resourceNames [%s]"
                     % (namespace, role["metadata"]["name"], rule, name))


KEYCLOAK_REFERENCE = re.compile(r"(apps/keycloak\b|\.\./keycloak\b|external-services/keycloak\b)")


@check("keycloak-separable")
def keycloak_separable():
    """Keycloak is installed only by components named apps/keycloak*:
    selecting another component (external-services) brings no Keycloak."""
    for path in library_files(("apps", "bootstrap", "cluster-config")):
        relative = rel(path)
        if relative.startswith("apps/keycloak") or relative in LEGACY_ROOTS \
                or not relative.endswith((".yaml", ".yml", ".json")):
            continue
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
                if KEYCLOAK_REFERENCE.search(code) and "application.yaml" not in code:
                    fail("%s:%d references the Keycloak component: %s" % (relative, number, line.strip()))


SAMPLES = os.path.join("apps", "acm-models-samples") + os.sep
CATALOG_KINDS = ("MaaSSubscription", "MaaSAuthPolicy", "LLMInferenceService", "ExternalModel", "MaaSModelRef")


@check("samples")
def samples():
    """Models and subscriptions are the catalog's. The library's own samples
    (and the lab's subscriptions) are one component a deployment selects."""
    if not os.path.isfile(os.path.join(ROOT, SAMPLES, "application.yaml")):
        fail("%sapplication.yaml is missing" % SAMPLES)
    for path in library_files(("apps",)):
        relative = rel(path)
        if relative.startswith(SAMPLES) or not relative.endswith(".yaml") or "/templates/" in relative:
            continue
        with open(path) as handle:
            text = handle.read()
        for kind in CATALOG_KINDS:
            if re.search(r"^kind: %s$" % kind, text, re.M):
                fail("%s: a %s outside %s" % (relative, kind, SAMPLES))


MOVED = (
    ("apps/object-storage/odf/manifests/obc.yaml", "ObjectBucketClaim", "acm-observability-thanos"),
    ("apps/acm-models-samples/hub/facebook-opt-125m-03-applicationset.yaml", "ApplicationSet", "acm-models-facebook-opt-125m"),
    ("apps/acm-models-samples/hub/maas-03-applicationset.yaml", "ApplicationSet", "acm-models-maas"),
    ("apps/acm-models-samples/hub/smollm2-135m-instruct-03-applicationset.yaml", "ApplicationSet", "acm-models-smollm2-135m-instruct"),
)


@check("move-guards")
def move_guards():
    """Objects a deployment's Applications own under other names than the lab
    roots' carry Prune=false, so when a hub moves from a lab root to a
    deployment repository the old owner's prune can't delete them (and what
    they created) before the new owner adopts them."""
    for path, kind, name in MOVED:
        with open(os.path.join(ROOT, path)) as handle:
            doc = next(d for d in yaml.safe_load_all(handle) if d and d["kind"] == kind)
        options = doc["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-options", "")
        if doc["metadata"]["name"] != name or "Prune=false" not in options.split(","):
            fail("%s: %s %s has no argocd.argoproj.io/sync-options Prune=false" % (path, kind, name))


def main():
    inputs = load_inputs()
    static_revision()
    static_catalog()
    components(inputs)
    bare_inputs()
    root(inputs)
    root_render(inputs)
    lab_roots()
    deployment_values()
    admins()
    object_storage(inputs)
    idp(inputs)
    keycloak_separable()
    samples()
    move_guards()
    failed = sum(1 for _, ok in results if not ok)
    print("inputs tests: %d ok, %d failed" % (len(results) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
