#!/usr/bin/env python3
"""Render the actual root template patches; needs Helm and PyYAML, no cluster."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile

import yaml

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rhoai-chart-values', type=Path,
                    help='Compare operator settings with values.yaml from the pinned RHOAI chart')
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
application = yaml.safe_load((root / 'apps/ai-grid-o11y/application.yaml').read_text())


def render_root(path, params):
    config = yaml.safe_load((root / path).read_text())
    with tempfile.TemporaryDirectory(prefix='loki-root-test-') as directory:
        chart = Path(directory)
        (chart / 'templates').mkdir()
        (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: root-test\nversion: 0.1.0\n')
        (chart / 'templates/patch.yaml').write_text(
            '{{- with .Values.params }}\n' + config['spec']['templatePatch'] + '\n{{- end }}\n')
        (chart / 'values.json').write_text(json.dumps({'params': params}))
        rendered = subprocess.check_output(
            ['helm', 'template', 'test', str(chart), '-f', str(chart / 'values.json')], text=True)
        return yaml.safe_load(rendered)['spec']


dedicated = 'bootstrap/dedicated-hub/applicationset.yaml'
combined = 'bootstrap/applicationset.yaml'
actual = render_root(dedicated, application)
assert 'sources' in actual and 'source' not in actual, (
    'dedicated hub must render operator and observability sources together')
assert actual['sources'][1] == application['spec']['source']
operator_source = actual['sources'][0]
assert operator_source == {
    'repoURL': application['spec']['source']['repoURL'],
    'targetRevision': application['spec']['source']['targetRevision'],
    'path': 'apps/ai-grid-o11y/loki-operator',
}
assert {key: value for key, value in actual.items() if key != 'sources'} == {
    key: value for key, value in application['spec'].items() if key != 'source'}
assert render_root(combined, application) == application['spec'], (
    'combined hub must keep its existing RHOAI-managed operator ownership')

fork = copy.deepcopy(application)
fork['spec']['source'].update(repoURL='https://github.com/example/grid-deployment.git',
                              targetRevision='deployment-branch')
fork_sources = render_root(dedicated, fork)['sources']
for source in fork_sources:
    assert source['repoURL'] == fork['spec']['source']['repoURL']
    assert source['targetRevision'] == fork['spec']['source']['targetRevision']
print('PASS: dedicated hub gets both sources, inherits fork/revision; combined hub unchanged')

operator = []
for path in sorted((root / operator_source['path']).glob('*.yaml')):
    operator.extend(doc for doc in yaml.safe_load_all(path.read_text()) if doc)
assert sorted(doc['kind'] for doc in operator) == ['OperatorGroup', 'Subscription']
group = next(doc for doc in operator if doc['kind'] == 'OperatorGroup')
subscription = next(doc for doc in operator if doc['kind'] == 'Subscription')
assert group['metadata']['namespace'] == subscription['metadata']['namespace'] == 'openshift-operators-redhat'
assert group['metadata']['name'] == 'openshift-operators-redhat'
assert not group.get('spec', {}).get('targetNamespaces'), 'Loki needs AllNamespaces installation'
assert 'Prune=false' in group['metadata']['annotations']['argocd.argoproj.io/sync-options']
assert 'Delete=false' in group['metadata']['annotations']['argocd.argoproj.io/sync-options']
assert subscription['metadata']['name'] == subscription['spec']['name'] == 'loki-operator'
assert subscription['spec']['source'] == 'redhat-operators'
assert subscription['spec']['sourceNamespace'] == 'openshift-marketplace'
assert subscription['spec']['installPlanApproval'] == 'Automatic'
assert 'startingCSV' not in subscription['spec'], 'Match RHOAI channel policy, not a separate CSV pin'


def wave(doc):
    return int(doc.get('metadata', {}).get('annotations', {}).get('argocd.argoproj.io/sync-wave', 0))


assert wave(group) < wave(subscription)
workloads = []
for path in sorted((root / application['spec']['source']['path']).glob('*.yaml')):
    workloads.extend(doc for doc in yaml.safe_load_all(path.read_text()) if doc)
assert wave(subscription) < min(wave(doc) for doc in workloads)
identities = [(doc['kind'], doc['metadata'].get('namespace'), doc['metadata'].get('name'))
              for doc in operator + workloads if 'name' in doc['metadata']]
assert len(identities) == len(set(identities)), 'Duplicate resource ownership between sources'
print('PASS: OLM resources precede workloads, shared namespace not managed, no duplicate resources')

if args.rhoai_chart_values:
    chart = yaml.safe_load(args.rhoai_chart_values.read_text())
    olm = chart['dependencies']['loki']['olm']
    assert subscription['spec']['channel'] == olm['channel']
    assert subscription['spec']['name'] == olm['name']
    assert subscription['metadata']['namespace'] == olm['namespace']
    assert subscription['spec']['source'] == chart['olm']['source']
    assert subscription['spec']['sourceNamespace'] == chart['olm']['sourceNamespace']
    assert 'version' not in olm
    print('PASS: operator version policy matches the supplied RHOAI chart:', olm['channel'])

print('Local rendering checks passed; live OLM/CRD readiness still requires operator validation.')
