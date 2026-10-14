# .github: market-replay CI

`workflows/ci.yml` runs the ox-setup action with the pins, then `dune build` and `dune test`.

Rules:

- Keep the pins in dependency order and in step with `dune-project`.
- To check a run: `gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.
