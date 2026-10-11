"""Runs the remote half of scripts/deploy/deploy-server.sh against fake Docker.

For every products.json product it checks a successful release (new image
running, bundled Web activated, Compose file promoted) and a failed public
health check (previous image and Web restored, Compose file untouched).
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'scripts/deploy/deploy-server.sh').read_text()
REMOTE = SCRIPT.split("<<'REMOTE_DEPLOY'\n", 1)[1].rsplit('\nREMOTE_DEPLOY', 1)[0]
DIGEST = 'sha256:' + 'a' * 64

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, shutil, sys
state_file = os.environ['FAKE_DOCKER_STATE']
state = json.load(open(state_file))
args = sys.argv[1:]
with open(os.environ['FAKE_DOCKER_LOG'], 'a') as log:
    log.write(' '.join(args) + '\n')
def save():
    json.dump(state, open(state_file, 'w'))
if args[0] == 'compose':
    if 'config' in args:
        if '--images' in args:
            print(os.environ['DOCKER_IMAGE'])
        sys.exit(0)
    if 'pull' in args:
        sys.exit(0)
    if 'up' in args:
        state['running'] = os.environ['DOCKER_IMAGE']
        save()
        sys.exit(0)
elif args[0] == 'inspect':
    if not state.get('running'):
        sys.exit(1)
    print(state['running'])
elif args[0] == 'create':
    print('extract-container')
elif args[0] == 'cp':
    source, target = args[1], args[2]
    if source != 'extract-container:' + os.environ['EXPECTED_WEB_DIST'] + '/.':
        sys.exit('unexpected Web dist path: ' + source)
    shutil.copytree(os.environ['FAKE_WEB_DIST'], target, dirs_exist_ok=True)
elif args[0] == 'port':
    if args[2] != os.environ['EXPECTED_PORT'] + '/tcp':
        sys.exit(1)
    print('127.0.0.1:32768')
elif args[0] in ('rm', 'logs'):
    pass
else:
    sys.exit('unexpected docker command: ' + ' '.join(args))
'''

FAKE_CURL = r'''#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
case "$*" in
  *"$PUBLIC_URL"*) [ "$FAIL_PUBLIC" != 1 ] || exit 22 ;;
esac
exit 0
'''

FAKES = {
    'docker': FAKE_DOCKER,
    'curl': FAKE_CURL,
    'flock': '#!/bin/sh\nexit 0\n',
    'sleep': '#!/bin/sh\nexit 0\n',
    # GNU `mv -T` is not available on macOS; this keeps the atomic rename.
    'mv': '#!/usr/bin/env python3\nimport os,sys\nos.replace(sys.argv[-2],sys.argv[-1])\n',
}


def load_product(key):
    fields = ('TITLE IMAGE CONTAINER SERVICE NAME WEB_DIST SERVICE_PORT READY_PATH PUBLIC_URL').split()
    program = 'source scripts/lib/product.sh; load_product "$1"; ' + '; '.join(
        f'printf "%s\\n" "$PRODUCT_{field}"' for field in fields)
    output = subprocess.run(['bash', '-c', program, '-', key], cwd=ROOT, check=True,
                            text=True, capture_output=True).stdout.splitlines()
    return dict(zip(fields, output))


def run(key, product, tmp, fail_public):
    bin_dir = tmp / 'bin'
    bin_dir.mkdir()
    for name, body in FAKES.items():
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)

    remote = tmp / 'remote'
    old_web = remote / 'web/releases/old'
    old_web.mkdir(parents=True)
    (old_web / 'index.html').write_text('old')
    (remote / 'web/current').symlink_to('releases/old')
    (remote / 'docker-compose.yml').write_text('current compose\n')
    (remote / 'docker-compose.yml.next').write_text('next compose\n')
    dist = tmp / 'dist'
    dist.mkdir()
    (dist / 'index.html').write_text('new')

    previous = f"{product['IMAGE']}:1.0.0@{DIGEST}"
    image = f"{product['IMAGE']}:2.0.0@{DIGEST}"
    state = tmp / 'state.json'
    state.write_text(json.dumps({'running': previous}))
    env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', FAKE_DOCKER_STATE=str(state),
               FAKE_DOCKER_LOG=str(tmp / 'docker.log'), FAKE_CURL_LOG=str(tmp / 'curl.log'),
               FAKE_WEB_DIST=str(dist), EXPECTED_WEB_DIST=product['WEB_DIST'],
               EXPECTED_PORT=product['SERVICE_PORT'], PUBLIC_URL=product['PUBLIC_URL'],
               FAIL_PUBLIC='1' if fail_public else '0')
    args = [str(remote), image, product['PUBLIC_URL'], product['TITLE'], product['IMAGE'],
            product['CONTAINER'], product['SERVICE'], product['NAME'], product['WEB_DIST'],
            product['SERVICE_PORT'], product['READY_PATH']]
    result = subprocess.run(['bash', '-s', '--', *args], input=REMOTE, text=True,
                            capture_output=True, env=env, cwd=tmp)
    running = json.loads(state.read_text())['running']
    web = (remote / 'web/current/index.html').read_text()
    compose = (remote / 'docker-compose.yml').read_text()
    docker_log = (tmp / 'docker.log').read_text()
    curl_log = (tmp / 'curl.log').read_text()
    context = (key, fail_public, result.returncode, result.stdout, result.stderr)

    assert f"--project-name {product['NAME']}" in docker_log, context
    assert f"http://127.0.0.1:32768{product['READY_PATH']}" in curl_log, context
    if fail_public:
        assert result.returncode != 0, context
        assert running == previous, (running, context)
        assert web == 'old', context
        assert compose == 'current compose\n', context
        assert not (remote / 'docker-compose.yml.next').exists(), context
    else:
        assert result.returncode == 0, context
        assert running == image, (running, context)
        assert web == 'new', context
        assert compose == 'next compose\n', context
        assert f"{product['PUBLIC_URL']}{product['READY_PATH']}" in curl_log, context


def main():
    keys = sys.argv[1:] or sorted(json.loads((ROOT / 'products.json').read_text()))
    for key in keys:
        product = load_product(key)
        for fail_public in (False, True):
            with tempfile.TemporaryDirectory() as tmp:
                run(key, product, Path(tmp), fail_public)
        print(f'PASS: {product["TITLE"]} Server deploy activates the new image and rolls back on failure')


main()
