#!/bin/bash
# Runs as root. Prepares the environment for Unraid, then drops to the
# "coder" user and execs "coder server". Any arguments are passed through.
set -euo pipefail

log() { echo "[coder-unraid] $*"; }

APP_USER=coder
APP_HOME=/home/coder
PUID="${PUID:-99}"
PGID="${PGID:-100}"

# 1. Drop blank CODER_* variables. The Unraid form sends every field, and
#    Coder treats an empty variable as an explicit value, which breaks
#    numeric and boolean flags and overrides defaults.
while IFS='=' read -r name value; do
  if [[ "$name" == CODER_* && -z "$value" ]]; then
    unset "$name"
  fi
done < <(env)

# 2. Align the coder user with PUID/PGID.
cur_uid=$(id -u "$APP_USER")
cur_gid=$(id -g "$APP_USER")
# Edit the account files directly. usermod -u would walk and chown the whole
# home directory (including Postgres data) on every start.
if [[ "$cur_gid" != "$PGID" ]]; then
  sed -i "s/^\($APP_USER:[^:]*:\)$cur_gid:/\1$PGID:/" /etc/group
  sed -i "s/^\($APP_USER:[^:]*:[^:]*:\)$cur_gid:/\1$PGID:/" /etc/passwd
fi
if [[ "$cur_uid" != "$PUID" ]]; then
  sed -i "s/^\($APP_USER:[^:]*:\)$cur_uid:/\1$PUID:/" /etc/passwd
fi
log "running as uid=$PUID gid=$PGID"

# 3. Grant access to the docker socket if one is mounted.
sock=/var/run/docker.sock
if [[ "${DOCKER_HOST:-}" == unix://* ]]; then
  sock="${DOCKER_HOST#unix://}"
fi
if [[ -S "$sock" ]]; then
  sock_gid=$(stat -c %g "$sock")
  if [[ "$sock_gid" == "$PGID" ]]; then
    log "docker socket $sock is already owned by gid $PGID"
  else
    grp=$(getent group "$sock_gid" | cut -d: -f1 || true)
    if [[ -z "$grp" ]]; then
      grp=dockersock
      addgroup -g "$sock_gid" "$grp"
    fi
    usermod -aG "$grp" "$APP_USER"
    log "docker socket $sock has gid $sock_gid, added $APP_USER to group $grp"
  fi
  if ! su-exec "$APP_USER" test -w "$sock"; then
    log "WARNING: $sock is not writable by $APP_USER. Docker workspaces will not provision."
  fi
else
  log "no docker socket at $sock. Docker-based workspace templates will not work."
fi

# 4. Make sure the data directories exist and are owned by the app user.
#    Only recurse when the top level is wrong so the Postgres data dir is not
#    re-walked on every start.
mkdir -p "$APP_HOME/.config" "$APP_HOME/.cache"
for dir in "$APP_HOME" "$APP_HOME/.config" "$APP_HOME/.cache"; do
  if [[ "$(stat -c %u:%g "$dir")" != "$PUID:$PGID" ]]; then
    log "fixing ownership of $dir"
    chown -R "$PUID:$PGID" "$dir"
  fi
done

# 5. Run the bootstrap in the background, then hand over to Coder.
#    Double fork so the job is reparented to tini (PID 1) and reaped there,
#    instead of lingering as a zombie child of the coder process.
( su-exec "$APP_USER" /usr/local/bin/coder-bootstrap.sh & )

export HOME="$APP_HOME"
exec su-exec "$APP_USER" /opt/coder server "$@"
