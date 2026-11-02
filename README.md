# ci-bench

Benchmark a Linux VPS as a GitHub Actions / CI host.

`ci-bench` installs the tools, runs one pass of four existing benchmarks (sysbench, fio, hyperfine, Docker), and records one JSON document per run. Each machine gets one GitHub issue: a summary table in the issue body and a comment with the full result for every run. `benchmark:compare` prints two or more result files side by side.

The benchmarks themselves stay upstream. This repo only installs them, runs them the same way every time, and keeps the numbers.

## What you need

- Debian or Ubuntu. Other distros stop with an error; this is the v1 limit. Node 18 or newer is required, so Ubuntu 22.04 and Debian 11 (whose own `nodejs` is older) are not supported.
- A user with `sudo`. The installer asks for the password once, up front, and keeps that sudo credential alive for the rest of the install. Later steps fail instead of prompting again.
- A GitHub account that can open issues in the repository that will hold the results.
- A quiet machine. Stop other work on the host before you run.

## Quick start

```bash
# 1. Install the commands, Node, the GitHub CLI and the Octokit client.
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Performant-Labs/ci-bench/main/install.sh)"

# 2. Log in to GitHub. ci-bench reads the token from `gh auth token`; it is never stored in an issue.
gh auth login

# 3. Check what can be checked before the tools exist (gh login, the repo, host tools).
benchmark:preflight --for init

# 4. Install sysbench, fio, build-essential, Docker, hyperfine, and the pinned source tarball.
benchmark:install

# 5. Say what this machine is (optional, but it makes results comparable).
export CI_BENCH_PROVIDER=Contabo
export CI_BENCH_PLAN=Core

# 6. Open the issue for this machine. It prints the issue number and URL, then the exact
#    `benchmark:run --issue <n>` command to run next.
benchmark:init-run

# 7. Run the benchmarks and add the result to that issue.
benchmark:run --issue 12
```

`benchmark:run` without `--issue` asks `Create a new issue?`. Only `y` or `yes` creates one; pressing Enter does not, and the command exits before running anything. With no terminal attached it never asks and exits with the same message. Pass `--issue <n>` (or the issue URL) to add a run to an existing host issue.

Both `benchmark:init-run` and `benchmark:run` run preflight first and stop before any benchmark or issue write if a check fails. It prints every failure in one pass.

## Commands

| Command | What it does |
|---|---|
| `benchmark:preflight [--for init] [--issue n]` | Check `gh` login and every other dependency. `--for init` checks only what `benchmark:init-run` needs. Exit 1 if anything fails. |
| `benchmark:install` | Install the benchmark tools and cache the pinned source tarball. Safe to run again. |
| `benchmark:init-run` | Open the GitHub issue for this machine. No benchmarks run. |
| `benchmark:run [--issue n] [-o file]` | Run the benchmarks. JSON goes to stdout, a short summary to stderr, `-o` also writes the JSON to a file. Exit 1 if any probe failed. |
| `benchmark:compare a.json b.json [...]` | Print a side-by-side table of two or more result files. |

Host issues go to this repository (`Performant-Labs/ci-bench`) by default, and **this repository is public**: a host issue shows the hostname, kernel, CPU and the full run JSON to anyone. To keep results private, create a private repository with issues enabled and set `CI_BENCH_REPO=owner/name` before `benchmark:init-run`.

## What the numbers mean

- **sysbench events/sec** (`sysbench cpu`, prime limit 20000, once with one thread and once with every core): CPU speed. Higher is better.
- **fio, YABS profile**: random read/write at 4k, 64k, 512k and 1m with the same flags as YABS, so the numbers can be set next to published YABS results. IOPS and bandwidth; higher is better. Latency is not recorded for this profile, because YABS turns it off.
- **fio, CI profile**: 16k random I/O, 70% reads, four jobs, 60 seconds. It is closer to what a CI job does to a disk. Includes mean and p99 latency.
- **compile median**: seconds to build the pinned source (Redis 7.4.2) with `make -j$(nproc)`, from a fresh unpack each time. Lower is better.
- **Docker cold**: median seconds to build the same source in a container with no cache, including pulling the base image and installing packages. Lower is better.
- **Docker cached**: seconds to rebuild straight afterwards with everything cached. This measures Docker overhead, not your hardware, so do not rank hosts by it.
- **steal**: the share of CPU time the hypervisor took away during the run. **Read it before you trust a ranking.** A high steal percent means a noisy neighbour, and the CPU, compile and Docker numbers are lower than the plan can deliver.

A probe that fails records an error, leaves its numbers empty (`—` in tables), and the rest of the run continues.

## Time and disk

- A full run takes roughly 15 to 30 minutes on a 4-core VPS, most of it the compile and the three cold Docker builds. (On an 8-core KVM test machine with a fast disk it took about 8 minutes.)
- The fio probes write one test file, 2 GiB (512 MiB off x86_64), under `/var/tmp/ci-bench/fio`. Preflight wants that file size plus 4 GiB free for the Docker image build, and refuses a directory on tmpfs (it would measure RAM). Set `CI_BENCH_FIO_DIR` to use another disk.
- `benchmark:run` clears Docker's build cache (`docker builder prune -af`) before each cold build, so any other Docker builds on the host lose their cache. All Docker commands run as `sudo docker`.

## Compare hosts

```bash
benchmark:run --issue 12 -o contabo-core.json
benchmark:run --issue 31 -o other-host.json     # on the other machine
benchmark:compare contabo-core.json other-host.json
```

Columns are hosts, headed by `provider / plan` (or hostname when those are unset). A missing number prints `—`. The same JSON is in every run comment on the host issue, so you can also copy it from there.
