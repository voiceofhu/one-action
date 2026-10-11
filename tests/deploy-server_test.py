"""Runs scripts/deploy/deploy-server.sh end to end against fake SSH and Docker.

The fake ssh joins its arguments into one string and re-parses it with a shell,
exactly like OpenSSH, so argument quoting bugs fail here instead of in CI.

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
SCRIPT = ROOT / 'scripts/deploy/deploy-server.sh'
# deploy-server.sh only accepts /opt paths; the fakes map this one to a temp dir.
REMOTE_ALIAS = '/opt/fake-remote'
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
elif args[0] in ('rm', 'logs', 'info'):
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

FAKE_SSH = r'''#!/usr/bin/env python3
import os, sys
command = ' '.join(sys.argv[2:]).replace(os.environ['REMOTE_ALIAS'], os.environ['FAKE_REMOTE'])
os.execvp('bash', ['bash', '-c', command])
'''

FAKE_SCP = r'''#!/usr/bin/env python3
import os, shutil, sys
source, target = sys.argv[1], sys.argv[2].split(':', 1)[1]
shutil.copyfile(source, target.replace(os.environ['REMOTE_ALIAS'], os.environ['FAKE_REMOTE']))
'''

FAKES = {
    'ssh': FAKE_SSH,
    'scp': FAKE_SCP,
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
    (remote / '.env').write_text('')
    compose_file = tmp / 'docker-compose.yml'
    compose_file.write_text('next compose\n')
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
               FAIL_PUBLIC='1' if fail_public else '0', REMOTE_ALIAS=REMOTE_ALIAS,
               FAKE_REMOTE=str(remote), PRODUCT=key, SSH_HOST='fake-deploy',
               REMOTE_DIR=REMOTE_ALIAS, DOCKER_IMAGE=image, COMPOSE_FILE=str(compose_file))
    result = subprocess.run(['bash', str(SCRIPT)], text=True, capture_output=True, env=env, cwd=tmp)
    running = json.loads(state.read_text())['running']
    web = (remote / 'web/current/index.html').read_text()
    compose = (remote / 'docker-compose.yml').read_text()
    read = lambda name: (tmp / name).read_text() if (tmp / name).exists() else ''
    docker_log, curl_log = read('docker.log'), read('curl.log')
    context = (key, fail_public, result.returncode, result.stdout, result.stderr)

    assert f"--project-name {product['NAME']}" in docker_log, context
    assert f"http://127.0.0.1:32768{product['READY_PATH']}" in curl_log, context
    if fail_public:
        assert result.returncode != 0, context
        assert f"{product['TITLE']} deployment failed" in result.stderr, context
        assert running == previous, (running, context)
        assert web == 'old', context
        assert compose == 'current compose\n', context
        assert not (remote / 'docker-compose.yml.next').exists(), context
    else:
        assert result.returncode == 0, context
        assert f"{product['TITLE']} public endpoint is ready" in result.stdout, context
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
