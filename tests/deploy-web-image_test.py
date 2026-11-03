"""Runs scripts/deploy/deploy-web-image.sh end to end against fake SSH and Docker.

For every web_runtime next product it checks that a release replaces only the
Web container (Server image kept), that a failed public check restores the
previous Web container, and that a host without a running Server is refused.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/deploy/deploy-web-image.sh'
REMOTE_ALIAS = '/opt/fake-remote'
DIGEST = 'sha256:' + 'b' * 64

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
state_file = os.environ['FAKE_DOCKER_STATE']
state = json.load(open(state_file))
args = sys.argv[1:]
with open(os.environ['FAKE_DOCKER_LOG'], 'a') as log:
    log.write(' '.join(args) + '\n')
if args[0] == 'compose':
    if '--images' in args:
        print(os.environ['DOCKER_IMAGE'])
        print(os.environ['WEB_DOCKER_IMAGE'])
    elif 'up' in args:
        if os.environ['SERVICE'] in args:
            sys.exit('the Server service must not be touched')
        state['web'] = os.environ['WEB_DOCKER_IMAGE']
        json.dump(state, open(state_file, 'w'))
elif args[0] == 'inspect':
    key = 'web' if args[-1] == os.environ['WEB_CONTAINER'] else 'server'
    if not state.get(key):
        sys.exit(1)
    print(state[key])
elif args[0] == 'port':
    if args[1] != os.environ['WEB_CONTAINER'] or args[2] != os.environ['WEB_PORT'] + '/tcp':
        sys.exit(1)
    print('127.0.0.1:32769')
elif args[0] != 'logs':
    sys.exit('unexpected docker command: ' + ' '.join(args))
'''

FAKES = {
    'ssh': '#!/usr/bin/env python3\nimport os,sys\n'
           "os.execvp('bash',['bash','-c',' '.join(sys.argv[2:]).replace(os.environ['REMOTE_ALIAS'],os.environ['FAKE_REMOTE'])])\n",
    'docker': FAKE_DOCKER,
    'curl': '#!/bin/sh\ncase "$*" in *"$PUBLIC_URL"*) [ "$FAIL_PUBLIC" != 1 ] || exit 22 ;; esac\nexit 0\n',
    'flock': '#!/bin/sh\nexit 0\n',
    'sleep': '#!/bin/sh\nexit 0\n',
}


def load_product(key):
    fields = 'TITLE IMAGE SERVICE PUBLIC_URL WEB_RUNTIME WEB_IMAGE WEB_CONTAINER WEB_PORT'.split()
    program = 'source scripts/lib/product.sh; load_product "$1"; ' + '; '.join(
        f'printf "%s\\n" "$PRODUCT_{field}"' for field in fields)
    output = subprocess.run(['bash', '-c', program, '-', key], cwd=ROOT, check=True,
                            text=True, capture_output=True).stdout.splitlines()
    return dict(zip(fields, output))


def run(key, product, tmp, fail_public=False, server_running=True):
    bin_dir = tmp / 'bin'
    bin_dir.mkdir()
    for name, body in FAKES.items():
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)
    remote = tmp / 'remote'
    remote.mkdir()
    (remote / '.env').write_text('')
    (remote / 'docker-compose.yml').write_text('compose\n')
    server = f"{product['IMAGE']}:1.0.0@{DIGEST}"
    previous = f"{product['WEB_IMAGE']}:1.0.0@{DIGEST}"
    image = f"{product['WEB_IMAGE']}:2.0.0@{DIGEST}"
    state = tmp / 'state.json'
    state.write_text(json.dumps({'server': server if server_running else None, 'web': previous}))
    env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', FAKE_DOCKER_STATE=str(state),
               FAKE_DOCKER_LOG=str(tmp / 'docker.log'), PUBLIC_URL=product['PUBLIC_URL'],
               FAIL_PUBLIC='1' if fail_public else '0', REMOTE_ALIAS=REMOTE_ALIAS,
               FAKE_REMOTE=str(remote), PRODUCT=key, SSH_HOST='fake-deploy', REMOTE_DIR=REMOTE_ALIAS,
               WEB_DOCKER_IMAGE=image, SERVICE=product['SERVICE'],
               WEB_CONTAINER=product['WEB_CONTAINER'], WEB_PORT=product['WEB_PORT'])
    result = subprocess.run(['bash', str(SCRIPT)], text=True, capture_output=True, env=env, cwd=tmp)
    final = json.loads(state.read_text())
    context = (key, fail_public, server_running, result.returncode, result.stdout, result.stderr)
    assert final['server'] == (server if server_running else None), context
    if not server_running:
        assert result.returncode != 0 and 'Deploy' in result.stderr, context
        assert final['web'] == previous, context
    elif fail_public:
        assert result.returncode != 0 and 'Web deployment failed' in result.stderr, context
        assert final['web'] == previous, context
    else:
        assert result.returncode == 0 and 'Server container was not changed' in result.stdout, context
        assert final['web'] == image, context


def main():
    keys = sys.argv[1:] or sorted(json.loads((ROOT / 'products.json').read_text()))
    for key in keys:
        product = load_product(key)
        if product['WEB_RUNTIME'] != 'next':
            continue
        for options in ({}, {'fail_public': True}, {'server_running': False}):
            with tempfile.TemporaryDirectory() as tmp:
                run(key, product, Path(tmp), **options)
        print(f'PASS: {product["TITLE"]} Web image deploy keeps the Server and rolls back on failure')


main()
