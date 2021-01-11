An AMQP RPC server that converts DNS zone files to JSON.

## Setup
1. Install `librabbitmq` and `libldns`.
2. Download [zamqp](https://github.com/skunkwerks/zamqp) and [zdns](https://github.com/skunkwerks/zdns). Put them in the same directory as zone2json.
3. `zig build`

Alternatively, you can specify paths to static libraries with
```
zig build -Dstatic-ldns=... -Dstatic-rabbitmq=... -Dstatic-ssl=... -Dstatic-crypto=...
```
