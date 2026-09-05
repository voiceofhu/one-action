from pathlib import Path
import tempfile,os,subprocess,tarfile,hashlib
source=(Path(__file__).resolve().parents[1] / 'scripts/deploy/deploy-browser-web.sh').read_text()
body=source.split("<<'REMOTE_DEPLOY'\n",1)[1].rsplit('\nREMOTE_DEPLOY',1)[0]
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp);binary=p/'bin';binary.mkdir()
 for name,script in {
 'flock':'#!/bin/sh\nexit 0\n',
 'sleep':'#!/bin/sh\nexit 0\n',
 'mv':'#!/usr/bin/env python3\nimport os,sys\nos.replace(sys.argv[-2],sys.argv[-1])\n',
 'curl':'#!/bin/sh\n[ "$FAIL_HEALTH" != 1 ] || exit 22\ncase "$*" in *one-web-revision*) printf "%s" "$TEST_WEB_SHA";; esac\n',
 }.items():
  f=binary/name;f.write_text(script);f.chmod(0o755)
 for fail in ['0','1']:
  remote=p/('remote'+fail);web=remote/'web';old=web/'releases/old';old.mkdir(parents=True);(old/'index.html').write_text('old');(web/'current').symlink_to('releases/old')
  dist=p/('dist'+fail);dist.mkdir();(dist/'index.html').write_text('new');sha='a'*40;(dist/'one-web-revision.txt').write_text(sha+'\n')
  archive=web/(sha+'.tar.gz')
  with tarfile.open(archive,'w:gz') as tar:
   for file in dist.iterdir():tar.add(file,arcname=file.name)
  digest=hashlib.sha256(archive.read_bytes()).hexdigest()
  result=subprocess.run(['bash','-s','--',str(remote),sha,digest,'https://browser.example.com'],input=body,text=True,capture_output=True,env=dict(os.environ,PATH=str(binary)+':'+os.environ['PATH'],FAIL_HEALTH=fail,TEST_WEB_SHA=sha))
  assert (result.returncode==0)==(fail=='0'),(fail,result.returncode,result.stdout,result.stderr)
  assert (web/'current/index.html').read_text()==('new' if fail=='0' else 'old')
print('PASS: remote Web activation and health-failure rollback; previous files retained')
