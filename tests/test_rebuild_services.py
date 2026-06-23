"""Unit tests for scripts/rebuild_services_from_base.sh.

The fan-out re-bakes every service image under the tag continuo's prod pointers
already reference: the short SHA of the last commit that touched that service's
directory. These tests pin that tag-derivation (the logic whose absence let a
dbt-base change reject releases at `validating`) by running the script in DRY_RUN
mode against throwaway git repos — no docker, no registry.
"""
import os
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "rebuild_services_from_base.sh"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "t@example.com")
    _git(repo, "config", "user.name", "t")
    _git(repo, "config", "commit.gpgsign", "false")
    return repo


def _add_service(repo: Path, name: str, body: str) -> None:
    svc = repo / "services" / name
    svc.mkdir(parents=True, exist_ok=True)
    (svc / "Dockerfile").write_text("FROM scratch\n")
    (svc / "model.sql").write_text(body)


def _commit(repo: Path, message: str) -> str:
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", message)
    return _git(repo, "rev-parse", "--short", "HEAD")


def _plan(repo: Path) -> dict[str, str]:
    env = {**os.environ, "DRY_RUN": "1"}
    out = subprocess.run(
        ["bash", str(SCRIPT)],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
        env=env,
    ).stdout.strip()
    plan = {}
    for line in out.splitlines():
        svc, tag = line.split()
        plan[svc] = tag
    return plan


def test_plan_tags_each_service_with_its_last_touching_commit(tmp_path):
    repo = _init_repo(tmp_path)

    _add_service(repo, "service-a", "select 1")
    sha_a = _commit(repo, "add service-a")

    _add_service(repo, "service-b", "select 2")
    sha_b = _commit(repo, "add service-b")

    plan = _plan(repo)

    assert plan == {"service-a": sha_a, "service-b": sha_b}


def test_unchanged_service_keeps_its_old_tag_after_another_service_changes(tmp_path):
    # The core regression: when only one service changes, every OTHER service's
    # prod tag (and thus the image we must re-bake) stays pinned to its own last
    # commit — never the latest HEAD. Re-baking under HEAD would orphan the tag
    # continuo's service_prod pointer references.
    repo = _init_repo(tmp_path)

    _add_service(repo, "service-a", "select 1")
    sha_a = _commit(repo, "add service-a")

    _add_service(repo, "service-b", "select 2")
    _commit(repo, "add service-b")

    # A later, unrelated change to service-b must not move service-a's tag.
    _add_service(repo, "service-b", "select 2 -- edited")
    sha_b2 = _commit(repo, "edit service-b")

    plan = _plan(repo)

    assert plan["service-a"] == sha_a, "unchanged service keeps its original prod tag"
    assert plan["service-b"] == sha_b2, "edited service advances to its newest commit"


def test_changed_service_in_head_commit_uses_head_tag(tmp_path):
    # When the service IS changed in the HEAD commit (the base+service push), its
    # derived tag is the HEAD short SHA — matching the new tag the release step
    # assigns, so the two builds agree.
    repo = _init_repo(tmp_path)

    _add_service(repo, "service-a", "select 1")
    _commit(repo, "add service-a")

    _add_service(repo, "service-a", "select 1 -- v2")
    head = _commit(repo, "edit service-a")

    plan = _plan(repo)

    assert plan["service-a"] == head


def test_directories_without_a_dockerfile_are_ignored(tmp_path):
    repo = _init_repo(tmp_path)

    _add_service(repo, "service-a", "select 1")
    _commit(repo, "add service-a")

    # A non-service directory (no Dockerfile) under services/ must not appear.
    (repo / "services" / "_shared").mkdir(parents=True)
    (repo / "services" / "_shared" / "notes.md").write_text("not a service")
    _commit(repo, "add a non-service dir")

    plan = _plan(repo)

    assert set(plan) == {"service-a"}


def test_errors_when_no_services_present(tmp_path):
    repo = _init_repo(tmp_path)
    (repo / "services").mkdir()
    (repo / "README.md").write_text("no services yet")
    _commit(repo, "init")

    result = subprocess.run(
        ["bash", str(SCRIPT)],
        cwd=repo,
        capture_output=True,
        text=True,
        env={**os.environ, "DRY_RUN": "1"},
    )

    assert result.returncode != 0
    assert "no services with a Dockerfile" in result.stderr
