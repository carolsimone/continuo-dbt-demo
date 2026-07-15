#!/usr/bin/env python3
"""wise-dbt — team 'wise' front-end over dbt-core.

Exposes a custom verb set and translates each into a dbt-core invocation via its
programmatic runner. continuo drives this binary through the per-service
dbt-commands.yaml dialect. Exit codes mirror dbt success/failure so executor's
Job status stays correct.

Verbs: run-model -> dbt run, load-seed -> dbt seed, capture-snapshot ->
dbt snapshot, test-model -> dbt test, build-model -> dbt build,
compile-project -> dbt compile.
"""
import sys

PROJECT_DIR = "/project"

# Each single-node verb maps to a dbt subcommand; they all take exactly one
# positional argument (the node) and select it with --select.
_SELECT_VERBS = {
    "run-model": "run",
    "load-seed": "seed",
    "capture-snapshot": "snapshot",
    "test-model": "test",
    "build-model": "build",
}


def translate(argv):
    """Map a wise-dbt verb line to a dbt argv, or None for a bad invocation."""
    if not argv:
        return None
    verb, rest = argv[0], argv[1:]
    if verb in _SELECT_VERBS and len(rest) == 1:
        return [_SELECT_VERBS[verb], "--select", rest[0], "--profiles-dir", PROJECT_DIR]
    if verb == "compile-project" and not rest:
        return ["compile", "--profiles-dir", PROJECT_DIR]
    return None


def main(argv):
    dbt_args = translate(argv)
    if dbt_args is None:
        print(f"wise-dbt: bad invocation {argv!r}", file=sys.stderr)
        return 64
    print(f"WISE-DBT WRAPPER v1 -> dbt {' '.join(dbt_args)}", file=sys.stderr, flush=True)
    # Lazy import so translate() is testable without dbt installed.
    from dbt.cli.main import dbtRunner

    res = dbtRunner().invoke(dbt_args)
    return 0 if res.success else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
