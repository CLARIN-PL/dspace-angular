#!/usr/bin/env python3
"""Offline ZIP trial. Reads selected production files; never changes repository data."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tarfile
import time
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--handles', nargs='+', required=True)
    args = parser.parse_args()
    if any(not h.startswith('11321/') or not h[6:].isdigit() for h in args.handles):
        raise SystemExit('Invalid handle')
    args.output.mkdir(parents=True, exist_ok=True)
    handles = ','.join("'" + h + "'" for h in args.handles)
    sql = """SELECT json_agg(x) FROM (
      SELECT DISTINCT h.handle, bs.internal_id, bs.size_bytes, bs.checksum,
      bs.checksum_algorithm, (SELECT text_value FROM metadatavalue m
      JOIN metadatafieldregistry f USING(metadata_field_id)
      JOIN metadataschemaregistry s USING(metadata_schema_id)
      WHERE m.dspace_object_id=bs.uuid AND s.short_id='dc' AND f.element='title'
      AND f.qualifier IS NULL ORDER BY m.place LIMIT 1) AS name
      FROM handle h JOIN item2bundle ib ON ib.item_id=h.resource_id
      JOIN bundle2bitstream bb ON bb.bundle_id=ib.bundle_id
      JOIN bitstream bs ON bs.uuid=bb.bitstream_id
      WHERE h.handle IN (""" + handles + """) AND NOT bs.deleted
      AND EXISTS(SELECT 1 FROM metadatavalue m JOIN metadatafieldregistry f
      USING(metadata_field_id) JOIN metadataschemaregistry s USING(metadata_schema_id)
      WHERE m.dspace_object_id=ib.bundle_id AND s.short_id='dc' AND f.element='title'
      AND f.qualifier IS NULL AND m.text_value='ORIGINAL')) x"""
    rows = json.loads(subprocess.check_output([
        'docker', 'exec', 'clarin-ssr-test-dspacedb-1', 'psql', '-U', 'dspace',
        '-d', 'dspace', '-Atc', sql], text=True))
    paths = {}
    for row in rows:
        ident = row['internal_id']
        if not ident.isdigit():
            raise ValueError('Unexpected internal ID')
        paths[ident[:2]+'/'+ident[2:4]+'/'+ident[4:6]+'/'+ident] = row
    # Only the listed files are read. No recursive copy of the assetstore.
    listing = args.output / 'selected-paths.txt'
    listing.write_text('\n'.join(paths) + '\n')
    archives = {}
    manifests = {h: [] for h in args.handles}
    start = time.monotonic()
    with listing.open('rb') as source:
        process = subprocess.Popen(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
            'root@10.45.126.11', 'tar -C /home/tnaskret/dspace/dspace-store/assetstore '
            '--verbatim-files-from -cf - -T -'], stdin=source, stdout=subprocess.PIPE)
        try:
            with tarfile.open(fileobj=process.stdout, mode='r|') as stream:
                for member in stream:
                    row = paths.pop(member.name)
                    if not member.isfile() or member.size != row['size_bytes']:
                        raise ValueError('Source size mismatch')
                    handle = row['handle']
                    if handle not in archives:
                        archives[handle] = zipfile.ZipFile(args.output / (handle.replace('/', '-')+'.zip.partial'),
                            'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True)
                    name = pathlib.PurePosixPath((row['name'] or 'file').replace('\\', '/')).name
                    if name in ('', '.', '..'):
                        name = 'file'
                    entry = 'files/%06d/%s' % (len(manifests[handle])+1, name)
                    digest = hashlib.new(row['checksum_algorithm'].lower().replace('-', ''))
                    with stream.extractfile(member) as content, archives[handle].open(entry, 'w', force_zip64=True) as out:
                        while chunk := content.read(1024*1024):
                            digest.update(chunk)
                            out.write(chunk)
                    if digest.hexdigest().lower() != row['checksum'].lower():
                        raise ValueError('Source checksum mismatch: ' + row['internal_id'])
                    manifests[handle].append({**row, 'entry': entry})
            if process.wait() != 0 or paths:
                raise ValueError('Incomplete source transfer')
            for handle, archive in archives.items():
                archive.writestr('manifest.json', json.dumps(manifests[handle], ensure_ascii=False, indent=2))
        finally:
            for archive in archives.values():
                archive.close()
            if process.poll() is None:
                process.terminate()
                process.wait()
    results = []
    for handle in args.handles:
        path = args.output / (handle.replace('/', '-')+'.zip.partial')
        with zipfile.ZipFile(path) as archive:
            for row in manifests[handle]:
                digest = hashlib.new(row['checksum_algorithm'].lower().replace('-', ''))
                with archive.open(row['entry']) as content:
                    while chunk := content.read(1024*1024):
                        digest.update(chunk)
                if digest.hexdigest().lower() != row['checksum'].lower():
                    raise ValueError('ZIP verification failed')
        final = path.with_suffix('')
        path.replace(final)
        results.append({'handle': handle, 'files': len(manifests[handle]),
            'original_bytes': sum(r['size_bytes'] for r in manifests[handle]),
            'zip_bytes': final.stat().st_size, 'verified': True})
    (args.output/'results.json').write_text(json.dumps({'seconds': time.monotonic()-start,
        'resources': results}, indent=2)+'\n')
    print(json.dumps(results, indent=2), flush=True)


if __name__ == '__main__':
    main()
