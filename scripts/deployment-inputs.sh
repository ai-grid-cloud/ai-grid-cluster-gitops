# Sourced by the deployment scripts in this directory. Renders a deployment
# repository's root/ and reads one input from its generator values:
#   deployment_render DIR   sets $DEPLOYMENT_ROOT to the rendered root
#   deployment_input NAME   prints that input's value
deployment_render() {
  DEPLOYMENT_ROOT="$(oc kustomize "$1/root")" || { echo "error: oc kustomize $1/root failed" >&2; return 1; }
}
deployment_input() { printf '%s\n' "$DEPLOYMENT_ROOT" | sed -n "s/^ *$1: *//p" | head -1 | tr -d "'\""; }
