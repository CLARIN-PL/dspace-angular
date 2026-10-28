#!/usr/bin/env python3
"""Small, repeatable integration/load check restricted to the isolated local port."""
import argparse
import collections
import concurrent.futures
import json
import time
import urllib.error
import urllib.request

ORIGIN = 'http://127.0.0.1:4400'
PATHS = [
    '/dspace/home',
    '/dspace/items/5dee01a7-1622-4ec2-a2d3-dcfc0d319511',
    '/dspace/items/5cc89772-4b30-4728-93de-d9cc1f3d7b4d/full',
    '/dspace/static/terms-of-service',
    '/dspace/browse?type=author&rpp=100',
    '/dspace/.git/HEAD',
    '/server/api',
    '/app/live',
]


def request(index):
    path = PATHS[index % len(PATHS)]
    language = 'en' if (index // len(PATHS)) % 2 else 'pl'
    req = urllib.request.Request(ORIGIN + path, headers={
        'User-Agent': 'CLARIN-local-SSR-check/1.0',
        'Cookie': 'dsLanguage=' + language,
    })
    started = time.monotonic()
    try:
        response = urllib.request.urlopen(req, timeout=13)
    except urllib.error.HTTPError as error:
        response = error
    except (OSError, TimeoutError) as error:
        return {'path': path, 'status': 'network-error', 'seconds': time.monotonic() - started,
                'error': type(error).__name__}
    with response:
        body = response.read()
        status = response.code
    expected = 404 if '/.git/' in path else 200
    return {'path': path, 'status': status, 'expected': expected,
            'seconds': time.monotonic() - started, 'bytes': len(body)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--workers', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.workers <= 16 or not 1 <= args.seconds <= 7200:
        parser.error('workers must be 1..16; seconds must be 1..7200')
    started = time.monotonic()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        while time.monotonic() - started < args.seconds:
            batch = list(pool.map(request, range(len(results), len(results) + args.workers)))
            results.extend(batch)
            # Bounded traffic; this is not an unlimited request-rate benchmark.
            time.sleep(0.1)
    grouped = collections.defaultdict(list)
    for result in results:
        grouped[result['path']].append(result)
    report = {}
    for path, records in grouped.items():
        timings = sorted(record['seconds'] for record in records)
        report[path] = {
            'requests': len(records),
            'statuses': dict(collections.Counter(str(record['status']) for record in records)),
            'p95_seconds': round(timings[min(len(timings) - 1, int(len(timings) * 0.95))], 3),
            'max_seconds': round(timings[-1], 3),
        }
    print(json.dumps({'duration_seconds': round(time.monotonic() - started, 2),
                      'workers': args.workers, 'paths': report}, indent=2))
    # Controlled overload responses are reported but do not count as a hung gateway.
    failures = [r for r in results if r['status'] not in (r.get('expected'), 429, 503)]
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
