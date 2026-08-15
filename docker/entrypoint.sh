#!/bin/bash
set -e

if [ ! -d /app/nopaystation_scripts ]; then
    echo "Seeding /app with nopaystation_scripts..."
    cp -a /opt/nps-seed/nopaystation_scripts /app/nopaystation_scripts
fi

# Keep the running copy up to date on every container start, not just at
# image build time - the image's baked-in git clone is cached by Docker
# and won't pick up new commits on a plain rebuild, so without this a
# container can be stuck running stale code indefinitely. Best-effort:
# don't fail startup over it (offline, diverged history, etc).
if [ -d /app/nopaystation_scripts/.git ]; then
    git -C /app/nopaystation_scripts pull --ff-only \
        || echo "Could not update /app/nopaystation_scripts (offline, local changes, or diverged history?) - continuing with what's there."
fi

# Re-sync symlinks every start too, not just at image build time - a
# script that didn't exist yet when the image was built (or that just
# arrived via the pull above) otherwise has no entry in PATH and fails
# with "command not found" even though the file is right there.
mkdir -p "${HOME}/bin"
chmod +x /app/nopaystation_scripts/nps_*.sh /app/nopaystation_scripts/pyNPU.py 2>/dev/null || true
for f in /app/nopaystation_scripts/nps_*.sh /app/nopaystation_scripts/pyNPU.py
do
    [ -e "${f}" ] || continue
    ln -sf "${f}" "${HOME}/bin/$(basename "${f}")"
done

exec "$@"
