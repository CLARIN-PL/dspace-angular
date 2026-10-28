#!/usr/bin/env python3
"""Verify local ORIGINAL bundles, downloaded archives and both item views."""
import csv
import hashlib
import json
import pathlib
import time
import urllib.request
import urllib.parse
import argparse

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT/'deployment-artifacts/20261028-zip-trial'
BASE = 'http://127.0.0.1:4400'
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def digest(stream):
    result = hashlib.sha256()
    while chunk := stream.read(1024*1024):
        result.update(chunk)
    return result.hexdigest()


def main():
    global BASE
    parser = argparse.ArgumentParser()
    parser.add_argument('--production', action='store_true', help='Read-only validation of public production endpoints')
    args = parser.parse_args()
    if args.production:
        BASE = 'https://clarin-pl.eu'
    inventory_name = 'production-inventory.csv' if args.production else 'local-inventory.csv'
    result_path = ROOT/'deployment-artifacts/20261028-production/validation.json' if args.production else OUT/'final-validation.json'
    inventory = {r['handle']:r for r in csv.DictReader((ROOT/'deployment-artifacts/20261027-large-resources'/inventory_name).open())}
    results = []
    for source in json.loads((OUT/'results.json').read_text())['resources']:
        handle = source['handle']
        result = {'handle':handle}
        try:
            url = BASE+'/server/api/core/metadatabitstreams/search/byHandle?'+urllib.parse.urlencode({'handle':handle,'fileGrpType':'ORIGINAL','size':10})
            with HTTP.open(url, timeout=30) as response:
                data = json.load(response)
            files = data['_embedded']['metadatabitstreams']
            assert data['page']['totalElements'] == 1 and len(files) == 1
            file = files[0]
            assert file['name'] == handle.replace('/','-')+'.zip'
            assert file['fileSize'] == source['zip_bytes']
            with HTTP.open(BASE+'/server/api/core/bitstreams/'+file['id']+'/content',timeout=120) as response:
                downloaded = digest(response)
            with (OUT/file['name']).open('rb') as stream:
                assert digest(stream) == downloaded
            result.update(zip_id=file['id'],sha256=downloaded,zip_verified=True,views=[])
            for suffix in ('','/full'):
                url = BASE+'/dspace/items/'+inventory[handle]['uuid']+suffix
                start = time.monotonic()
                with HTTP.open(url,timeout=20) as response:
                    html = response.read().decode()
                    assert response.status == 200 and file['name'] in html
                result['views'].append({'url':url,'seconds':round(time.monotonic()-start,3),'status':200})
            result['passed'] = True
        except Exception as error:
            result.update(passed=False,error=str(error))
        results.append(result)
        result_path.write_text(json.dumps(results,indent=2)+'\n')
        print(handle,result['passed'],result.get('error',''),flush=True)
    if not all(r['passed'] for r in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
