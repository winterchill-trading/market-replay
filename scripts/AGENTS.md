# scripts: market-replay end-to-end check

`e2e-replay.sh` records the three simulators with `market-recorder`, checks that `/replay` serves every
recorded line, then points a second recorder at the server through custom endpoints and checks every
recorded data frame arrives and normalizes without parse errors.

Rules:

- The script starts processes on local ports. Check the ports are free first and stop the processes it
  started.
- Shellcheck the script after editing it.
