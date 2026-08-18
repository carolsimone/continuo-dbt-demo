# The first python node in the demo estate, built the way the runtime
# repository's template prescribes: the engine-matched runtime base plus this
# service's contracts and scripts. One image serves every node this service
# declares — the harness selects between them from NODE_ID at run time.
FROM ghcr.io/carolsimone/continuo-python-runtime:v0.2.1-postgres
COPY contracts/ /app/contracts/
COPY scripts/ /app/scripts/
# The runtime base declares no non-root user, so the executor leaves the user to
# the image (its pod spec drops capabilities and forbids privilege escalation
# but sets no uid). This picks an unprivileged one: the harness only reads its
# baked contracts/scripts and writes solely to the warehouse, so no ownership
# changes are needed.
USER 65532:65532
