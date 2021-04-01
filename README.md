An AMQP RPC server that converts DNS zone files to JSON.

`zone2json` receives standard RFC1035-style zonefiles and generates JSON
format equivalents. This is available as either a standard command-line
utility, or an AMQP-based RPC daemon.

```
$ dig +tcp @xfr01.nsone.net zone.com axfr \
  | zone2json | jq .

$ export AMQP_URI='amqps://user:password@host/vhost\
  ?heartbeat=43\
  &verify=verify_peer&cacertfile=/usr/local/share/certs/ca-root-nss.crt\
  &fail_if_no_peer_cert=true'
$ zone2json-server --queue rpc.zdns $AMQP_URI
```

## Build from Source

1. Install `librabbitmq` and `libldns`.
2. Download [zamqp](https://github.com/skunkwerks/zamqp) and
   [zdns](https://github.com/skunkwerks/zdns). Put them in the same
   directory as zone2json.
3. `zig build`

Alternatively, you can specify paths to static libraries with:

```
zig build -Dstatic-ldns=... \
    -Dstatic-rabbitmq=... \
    -Dstatic-ssl=... \
    -Dstatic-crypto=...
```

Tested on FreeBSD 12+ and Linux.

