# Handle prefix 11321: native HTTPS cutover

Status on 2026-10-08: the production Handle 9.3.2 server is healthy on the
private host `10.45.126.11:443`. The public proxy is **not yet corrected**;
`https://hdl.handle.net/11321/931` still returns 500. The Handle.Net Registry
already installed site serial 3, which advertises only HTTPS at
`156.17.1.83:443`. Do not send another site bundle or rotate the Handle key
just to fix the proxy.

## Why the previous HTTP reverse proxy fails

The published Apache vhost terminated TLS and forwarded to
`http://10.45.126.11:8000`. A native Handle request then arrived at the
Handle servlet as HTTP, while the registered interface is HTTPS, producing
`Received query request on non-query interface`. The edge also closes TLS
connections without SNI. Finally, its public TLS certificate uses a different
public key from the registered Handle server key. Native Handle clients check
that key, so merely re-encrypting from the edge to the Handle server is still
insufficient. A successful `curl /api/site` does **not** prove native resolution.
On 2026-10-08 the edge certificate's SPKI SHA-256 was
`7852719110cf1ded148cffdf3e5518845ee4609bdf3c5763fa548ff64a698e86`,
while the working Handle certificate's was
`beda7412d03f9fe2e51713e14cdf3d58a87adf03f2d10beff6e9e8f18b5542e0`.
After cutover, both SNI and no-SNI connections for Handle must present the
latter key.

## Prepared backend

- `config.dct` keeps `hdl_http` on 8000 and adds `hdl_http_https` on 8001 with
  `"https" = "yes"`; both names are in `interfaces`. Do not put `"https"` on
  the existing 8000 connector.
- Compose maps only the private address `10.45.126.11:443` to container
  `8001/tcp`. Ports 2641 and 8000 remain private; no new public port is needed.
- The server-generated certificate now uses the registered Handle server key.
  The older, mismatched certificate and its private-key file were preserved in
  the production backup, not placed in Git.
- The DSpace gateway has no Handle vhost. It must not proxy native Handle
  traffic through HTTP.
- Production backup: `/root/handle-https-backup-20261008-xNQ0ah` (mode 700).
  The live Handle directory is the persistent volume
  `/var/lib/docker/volumes/clarin-pl-dspace_dspace_handle/_data`.
  The backup also has the post-fix `config.dct.after-https-8001` and public
  `serverCertificate.pem.after-key-repair` for recovery.

If rebuilding that volume, preserve the server keys and `siteinfo.bin` and add
this connector to `config.dct`:

```text
"hdl_http_https_config" = {
"bind_address" = "0.0.0.0"
"bind_port" = "8001"
"https" = "yes"
"log_accesses" = "yes"
}
```

Add `"hdl_http_https"` to `interfaces` without removing `"hdl_http"`.
Recreating the container does not recreate the persistent configuration
volume. Never regenerate `privkey.bin` or `siteinfo.bin` without coordinating
the corresponding registry update.

## Required change on the public TLS proxy

Route **raw TCP/TLS** on `156.17.1.83:443` to `10.45.126.11:443` for both
SNI `handle.clarin-pl.eu` and clients with **no SNI**. Keep all other SNI
hostnames on the existing website HTTPS stack. The public listener must not
terminate TLS for Handle, replace its certificate, or forward Handle requests
to port 80/8000. Allow the private 443 connection only from the perimeter
proxy in the host/network firewall.

Illustrative HAProxy routing logic (adapt the listener/backend names and the
existing HTTPS stack to the **actual** edge configuration before deployment):

```haproxy
frontend public_tls_mux
    bind 156.17.1.83:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    acl handle_sni req.ssl_sni -i handle.clarin-pl.eu
    acl any_sni req.ssl_sni -m found
    use_backend handle_tls if handle_sni
    use_backend existing_web_tls if any_sni
    default_backend handle_tls

backend handle_tls
    mode tcp
    server handle 10.45.126.11:443 check

backend existing_web_tls
    mode tcp
    server web 127.0.0.1:8443 check
```

The current HTTPS terminator would have to move off the public 443 listener
to the internal target represented by `127.0.0.1:8443`. Preserve the original
client address for the web stack (for example, PROXY protocol on both sides
if supported). Do not apply this template verbatim without checking the live
HAProxy topology. If routing no-SNI to Handle is unacceptable for other
services, assign Handle a **dedicated public IP** instead; SNI-only routing
cannot serve older Handle clients.

## Acceptance checks

Before changing the edge, from the production host:

```bash
curl -kfsS https://10.45.126.11:443/api/site
docker cp scripts/HandleHttpsProbe.java clarin-pl-dspace-handle-server-1:/tmp/
docker exec clarin-pl-dspace-handle-server-1 javac -cp '/dspace/lib/*' -d /tmp /tmp/HandleHttpsProbe.java
docker exec clarin-pl-dspace-handle-server-1 java -cp '/tmp:/dspace/lib/*' net.handle.hdllib.HandleHttpsProbe 10.45.126.11 443 11321/931
```

The last command must print `certified native HTTPS responseCode=1`. After
the edge cutover, repeat it using `156.17.1.83` as host, then test both TLS
handshakes and the global resolver:

```bash
curl -kfsS -H 'Host: handle.clarin-pl.eu' https://156.17.1.83/api/site
curl -kfsS https://handle.clarin-pl.eu/api/site
curl -IL https://hdl.handle.net/11321/931
```

The first curl intentionally omits SNI. The last request must redirect to
`https://clarin-pl.eu/dspace/handle/11321/931`; allow time for registry and
resolver caches. Ask the Handle.Net administrator to repeat their older and
newer client tests.

The current Handle certificate is self-signed (`CN=anonymous`), so browsers
and ordinary `curl` will not trust the direct Handle hostname after TLS
passthrough. To restore browser-trusted REST access, obtain a CA-signed
certificate **for the existing Handle server key** and install that
certificate/chain on the Handle server. Do not replace the key with an ACME
client's new key or put the Handle private key on the proxy. Native Handle
resolution can be tested independently of browser trust.

Rollback: restore the edge's prior 443 listener if the new TCP multiplexer
breaks the main site. That restores the website, but does **not** repair global
Handle resolution. The backend's existing HTTP 8000 and DSpace gateway need
not be changed during edge rollback.
