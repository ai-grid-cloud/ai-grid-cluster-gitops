#!/usr/bin/env python3
"""Check that the ai-grid-o11y Application prunes in the background and never prunes or deletes RHOAI's monitoring namespace."""

import os

import yaml


ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
APPSET = os.path.join(ROOT, "bootstrap", "applicationset.yaml")
NAMESPACE = os.path.join(ROOT, "charts", "ai-grid-o11y", "templates", "00-namespace.yaml")


def options(entries):
    return {option.strip() for entry in entries or [] for option in entry.split(",") if option.strip()}


def o11y_element():
    with open(APPSET) as stream:
        appset = yaml.safe_load(stream)
    for generator in appset["spec"]["generators"]:
        for element in generator.get("list", {}).get("elements", []):
            if element.get("metadata", {}).get("name") == "ai-grid-o11y":
                return element
    raise AssertionError("no ai-grid-o11y element in bootstrap/applicationset.yaml")


def main():
    policy = o11y_element()["spec"]["syncPolicy"]
    sync = options(policy.get("syncOptions"))
    assert "PrunePropagationPolicy=background" in sync, "ai-grid-o11y must prune in the background"
    assert "CreateNamespace=true" in sync, "ai-grid-o11y must still create its destination namespace"
    assert policy["automated"]["prune"] is True, "automatic pruning must stay enabled"

    with open(NAMESPACE) as stream:
        namespace = yaml.safe_load(stream)
    assert namespace["kind"] == "Namespace" and namespace["metadata"]["name"] == "redhat-ods-monitoring"
    ns_options = options([namespace["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-options", "")])
    assert {"Prune=false", "Delete=false"} <= ns_options, "the shared namespace must carry Prune=false,Delete=false"
    print("ok: background pruning; RHOAI's monitoring namespace is never pruned or deleted")


if __name__ == "__main__":
    main()
