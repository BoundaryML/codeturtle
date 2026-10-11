# Experimental healer — execution disabled

The BAML workflow describes scanning traces, diagnosis, repair, testing, and promotion. Host execution is disabled because generated candidate tests need an isolated runner without host credentials, deployment access, or writable host mounts.

This prototype is not a supported deployment path. Its historical local Studio adapter has not been migrated to Boundary Cloud. No run or resume command can execute a candidate.

The tests use a fake host to verify orchestration and verify that the real host entrypoints refuse execution:

```sh
python3 -m unittest discover -s heal/tests -v
```
