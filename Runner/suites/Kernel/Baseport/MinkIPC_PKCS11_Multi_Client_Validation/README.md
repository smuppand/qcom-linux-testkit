# MinkIPC QTEE PKCS#11 Multi-Client Validation

This suite starts multiple `xtest_qtee` processes concurrently to validate
MinkIPC and QTEE PKCS#11 multi-client handling. Each process runs only the
non-mutating cases:

- 1000: initialize and close the Cryptoki library.
- 1001: enumerate slots, token information, and mechanisms.
- 1002: open, inspect, and close sessions.

Token initialization and object-mutating cases are intentionally excluded so
the concurrent clients do not race while changing shared persistent state.

QTEE serializes part of the TA session-open path. When simultaneous processes
race that path, one process may receive `TEEC_ERROR_BUSY` (`0xffff000d`). The
runner treats only that exact open-session response as transient and retries
the affected client with a short bounded backoff. Any other command or result
failure is reported immediately. Every client must eventually pass all three
cases and leave no relevant QCOMTEE or RPMB kernel errors.

Run two clients with defaults:

```sh
./run.sh
```

Run four clients against a selected TEE:

```sh
./run.sh --clients 4 --tee 1
```

Change the number of retries allowed after a QTEE busy response:

```sh
./run.sh --busy-retries 3
```

The default is five retries after the initial attempt. Set
`--busy-retries 0` to require every concurrent client to pass on its first
attempt.
