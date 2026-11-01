# ci-bench

Coordinator for benchmarking a Linux VPS as a GitHub Actions / CI host.

It installs the tools, runs one pass of four existing benchmarks, and writes one JSON document per machine. A second command prints a side-by-side comparison. The benchmarks themselves stay upstream: sysbench, fio, hyperfine, and Docker.

This repository is the spec and the issue tracker. The commands below are the interface. They are not implemented yet.

## Install

Debian and Ubuntu only. The installer asks for sudo immediately and keeps that credential alive for the rest of the session.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Performant-Labs/ci-bench/main/install.sh)"
```

## Commands

| Command | Role |
|---|---|
| `benchmark:install` | Install sysbench, fio, build-essential, Docker, and hyperfine. Start Docker. |
| `benchmark:run` | Record host facts, then run CPU, both fio profiles, a pinned compile, and a Docker build. Print one JSON document. |
| `benchmark:compare` | Read two or more result files and print a side-by-side table. |

`benchmark:run` invokes `sudo docker` so a docker-group membership that is not active in the current shell cannot stall the run.

## Status

Work is tracked in the epic on this repository. Do not treat this README as a second spec.
