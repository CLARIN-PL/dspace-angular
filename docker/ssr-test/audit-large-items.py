#!/usr/bin/env python3
"""Measure large public items with a fresh, separate local SSR process per item."""
import argparse
import csv
import json
import pathlib
import subprocess
import time

CONTAINER = 'clarin-ssr-budget-audit'
FRONTEND = 'clarin-ssr-test-frontend-1'


def docker(*args, timeout=35):
    return subprocess.run(['docker', *args], check=True, capture_output=True,
                          text=True, timeout=timeout).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--handles', nargs='*')
    args = parser.parse_args()
    source = json.loads(docker('inspect', FRONTEND))[0]
    environment = [value for value in source['Config']['Env']
                   if value.startswith(('DSPACE_', 'NODE_ENV=', 'NODE_OPTIONS='))]
    network = next(name for name in source['NetworkSettings']['Networks']
                   if name.startswith('clarin-ssr-test_') and name.endswith('isolated'))
    config = next(mount for mount in source['Mounts']
                  if mount['Destination'] == '/app/config/ssr-test.yml')
    if docker('ps', '-aq', '--filter', 'name=^/' + CONTAINER + '$'):
        raise SystemExit('Audit container already exists; inspect it before continuing.')
    with args.inventory.open() as stream:
        records = list(csv.DictReader(stream))
    results = []
    for record in records:
        if args.handles and record['handle'] not in args.handles:
            continue
        if record['anonymous_files'] != record['files']:
            results.append({**record, 'result': 'skipped: restricted files'})
            continue
        command = ['run', '-d', '--name', CONTAINER, '--network', network,
                   '--cpus', '1', '--memory', '3g', '--mount',
                   f"type=bind,src={config['Source']},dst={config['Destination']},readonly"]
        for value in environment:
            command.extend(['--env', value])
        command.append(source['Image'])
        result = {**record}
        try:
            docker(*command)
            ready = False
            for _ in range(20):
                try:
                    docker('exec', CONTAINER, 'node', '-e',
                           "fetch('http://127.0.0.1:4000/app/live',{signal:AbortSignal.timeout(1000)})"
                           ".then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))", timeout=4)
                    ready = True
                    break
                except (subprocess.SubprocessError, OSError):
                    time.sleep(0.5)
            if not ready:
                raise RuntimeError('Audit frontend did not become ready')
            path = '/dspace/items/' + record['uuid']
            js = """const started=performance.now();
fetch('http://127.0.0.1:4000'+process.argv[1],{
 headers:{'User-Agent':'CLARIN-local-budget-audit/1.0','Cookie':'dsLanguage=en'},
 signal:AbortSignal.timeout(15000)})
 .then(async r=>{const b=await r.text();console.log(JSON.stringify({
   status:r.status,seconds:(performance.now()-started)/1000,html_bytes:Buffer.byteLength(b)}))})
 .catch(e=>console.log(JSON.stringify({status:0,seconds:(performance.now()-started)/1000,error:e.name})));"""
            result.update(json.loads(docker('exec', CONTAINER, 'node', '-e', js, path, timeout=20)))
            logs = docker('logs', CONTAINER)
            result['rxjs_stream_errors'] = logs.count('where a stream was expected')
            result['result'] = 'ok' if result['status'] == 200 and result['seconds'] < 10 else 'over-budget-or-error'
        except (subprocess.SubprocessError, OSError, ValueError, RuntimeError) as error:
            result['result'] = 'audit-error'
            result['error'] = type(error).__name__
        finally:
            # This fixed name is created solely by this script; the interactive UI stays up.
            subprocess.run(['docker', 'rm', '-f', CONTAINER], capture_output=True, timeout=30)
        results.append(result)
        args.output.write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')
        print(record['handle'], result.get('status'), result.get('seconds'), result['result'], flush=True)


if __name__ == '__main__':
    main()
