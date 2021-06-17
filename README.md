A BSD-licensed AMQP RPC server that converts DNS zone files to JSON.

Tested on FreeBSD 12+ and Linux, using latest [zig] > 0.7.1 and < 0.9.0.

`zone2json` receives standard RFC1035-style zonefiles and generates JSON
format equivalents. This is available as either a standard command-line
utility, or an AMQP-based RPC daemon.

## command-line mode

`zone2json` returns valid JSON output on success, and returns an error
status on failure, with a brief error explanation on stdout.

```
$ dig +tcp @xfr01.nsone.net zone.com axfr \
  | zone2json | jq .
... such JSON ...
$ zone2json < /dev/null
  no SOA record in zone
```

## RPC daemon

In RPC daemon mode, `zone2json-server` produces no stdout, unless `--log
stderr` option is provided. If the AMQP transport layer fails,
exponential back-off occurs until reconnection suceeds. Any other issues
will result in the daemon exiting.


In default syslog mode, the daemon emits occasional debug output:

```
Jun 17 10:19:53 host zone2json-server[55056]: acked full batch (delivery tag: 485)
...
Jun 17 10:19:56 host zone2json-server[55056]: no messages, acked partial batch (delivery tag: 489)
```

### RPC daemon invocation

```
$ export AMQP_URI='amqps://user:password@host/vhost\
  ?heartbeat=43\
  &verify=verify_peer&cacertfile=/usr/local/share/certs/ca-root-nss.crt\
  &fail_if_no_peer_cert=true'
$ zone2json-server --queue rpc.zdns --log stderr $AMQP_URI
[info] connecting to test.rmq.cloudamqp.com:5671
[info] logging into vhost test as zone2json
[info] connection set up
[info] opening channel 1
[info] consuming from queue rpc.zdns
[info] channel set up
[debug] no messages, acked partial batch (delivery tag: 123)
...
```

### RPC request

The RPC request must have `content-type:text/dns`, and obviously is
expected to be an [RFC1035] zonefile, possibly with semantic or syntactic
errors.

```
$ rabbiteer -U $AMQP_URI publish \
    --rpc --rpctimeout 3000 \
    --routing-key rpc.zdns \
    --content-type text/dns \
    --file ./test/zones/example.com.zone
```

### RPC response

The RPC response is `application/json` with either an `{"ok": ...}` key
and the zonefile in JSON as value, or an `{"error": ...}` response,
where the value is the specifics of the line and parsing failure, as
reported via the underlying [ldns] library.

```
{
  "ok": {
    "name": "example.com",
    "records": [
      {
        "data": {
          "expire": 1209600,
          "minimum": 3600,
          "mname": "ns1.example.com",
          "refresh": 14400,
          "retry": 1800,
          "rname": "hostmaster.example.com",
          "serial": 2014012401
        },
...
}
```

An error response, for example, using `./test/zones/bad.zone` where the
unrecognised `EBADCAFE` RR type is rejected:

```json
{
  "error": "parsing zone failed on line 6: Syntax error, could not parse the RR's rdata"
}
```

## Build from Source

1. Install [librabbitmq] and [ldns] from your OS packages.
2. Clone or Download [zamqp](https://github.com/skunkwerks/zamqp) and
   [zdns](https://github.com/skunkwerks/zdns). Put them in the same
   directory as zone2json.
3. `zig build` and use the artefacts in `./zig-out/bin/`.

Alternatively, you can specify paths to static libraries with:

```
zig build -Dstatic-ldns=... \
    -Dstatic-rabbitmq=... \
    -Dstatic-ssl=... \
    -Dstatic-crypto=...
```

### FreeBSD build/test instructions

- yajl is used for JSON validation

```
$ sudo pkg install -r FreeBSD net/rabbitmq-c-devel dns/ldns devel/yajl
$ zig build \
    -Dstatic-ldns=/usr/local/lib/libldns.a \
    -Dstatic-rabbitmq=/usr/local/lib/librabbitmq.a
$ ./zig-out/bin/zone2json \
    < test/zones/example.com.zone \
    | json_verify
JSON is valid
```

[librabbitmq]: https://github.com/alanxz/rabbitmq-c
[ldns]: https://www.nlnetlabs.nl/documentation/ldns
[zig]: https://ziglang.org/
[RFC1035]: https://tools.ietf.org/html/rfc1035
