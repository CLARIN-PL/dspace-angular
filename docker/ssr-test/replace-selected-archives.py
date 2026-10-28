#!/usr/bin/env python3
"""Apply verified archives to the isolated local test container only."""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / 'deployment-artifacts/20261028-zip-trial'
CONTAINER = 'clarin-ssr-test-dspace-1'


def main():
    results = []
    for resource in json.loads((ARTIFACTS/'results.json').read_text())['resources']:
        handle = resource['handle']
        if handle == '11321/222':
            continue  # already converted and verified separately
        name = handle.replace('/', '-') + '.zip'
        log = ARTIFACTS / (handle.replace('/', '-') + '-replacement.log')
        subprocess.run(['docker', 'cp', str(ARTIFACTS/name), CONTAINER+':/tmp/'+name], check=True)
        with log.open('w') as out:
            run = subprocess.run(['docker','exec',CONTAINER,'java','-Ddspace.dir=/dspace',
                '-cp','/tmp:/dspace/lib/*:/dspace/config','ReplaceOriginalsWithZip',handle,
                '/tmp/'+name,'LOCAL-TRIAL'], stdout=out, stderr=subprocess.STDOUT)
        success = run.returncode == 0 and ('CONVERTED '+handle+' ') in log.read_text()
        results.append({'handle':handle,'success':success,'log':log.name})
        (ARTIFACTS/'replacement-results.json').write_text(json.dumps(results,indent=2)+'\n')
        print(handle, 'converted' if success else 'FAILED: '+log.name, flush=True)
        if not success:
            raise SystemExit('Stopped on validation failure; inspect log before continuing')


if __name__ == '__main__':
    main()
