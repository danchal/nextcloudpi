#!/bin/bash
# Nextcloud borgbackups
#

install()
{
  echo "running install"

  # get latest stable borgbackup binary direct from borg github
  # debian package version is too old
  wget \
    https://github.com/borgbackup/borg/releases/download/1.1.9/borg-linux64 \
    -O /usr/local/bin/borg

  chown ncp:ncp /usr/local/bin/borg
  chmod +x /usr/local/bin/borg

  cat > /usr/local/bin/ncp-borgbackup <<'EOF'
#!/bin/bash
set -eE

destdir="${1:-/media/USBdrive/ncp-borgbackups}"
repository="${2:-nextcloudpi}"
export BORG_PASSPHRASE="${3}"
checkrepo="${4}"

prunecmd="--keep-daily=7 --keep-weekly=4 --keep-monthly=-1"
archive="{hostname}-{now:%Y-%m-%dT%H:%M:%S}"
dbbackup=nextcloud-sqlbkp_$( date +"%Y%m%d" ).bak
occ="sudo -u www-data php /var/www/nextcloud/occ"
[[ -f /.docker-image ]] && basedir=/data || basedir=/var/www

cleanup(){ local ret=$?;                    rm -f "${dbbackup}" ; $occ maintenance:mode --off; exit $ret; }
fail()   { local ret=$?; echo "Abort..."  ; rm -f "${dbbackup}" ; $occ maintenance:mode --off; exit $ret; }
trap cleanup EXIT
trap fail INT TERM HUP ERR

mkdir -p "$destdir"

# if repository path does not already exist then initialise repository
if [[ ! -d "${destdir}/${repository}" ]]; then
  echo "initialising repository..."
  borg init \
      --encryption=repokey-blake2 \
      "${destdir}/${repository}" \
  || {
        echo "error initialising repository"
        exit 1
      }
fi

# prune older backups
echo "pruning backups..."
borg prune \
  ${prunecmd} \
  "${destdir}/${repository}" \
  || {
        echo "error performing borg prune"
        exit 1
      }

# database
$occ maintenance:mode --on
cd "$basedir" || exit 1
echo "backup database..."
mysqldump -u root --single-transaction nextcloud > "$dbbackup"

# files
echo "creating backup..."
borg create \
  --exclude "nextcloud/data/.opcache" \
  --exclude "nextcloud/data/{access,error,nextcloud}.log" \
  --exclude "nextcloud/data/access.log" \
  --exclude "nextcloud/data/appdata_*/previews/*" \
  --exclude "nextcloud/data/ncp-update-backups/" \
  "${destdir}/${repository}::${archive}" \
  "${basedir}" \
  || {
        echo "error creating borgbackup"
        exit 1
      }

# turn off maintenance mode as repository check could take some time
$occ maintenance:mode --off

# check
if [[ "$checkrepo" == "yes" ]]; then
  echo "verifying repository..."
  borg --info \
    check \
    --verify-data \
    "${destdir}/${repository}" \
  || {
    echo "error verifying repository"
    exit 1
  }
fi

echo "borgbackup ${destdir}::${repository} generated"
EOF
  chmod +x /usr/local/bin/ncp-borgbackup
}

configure()
{
  echo "running configure"
  #echo "<${DESTDIR}>, <${REPOSITORY}>, <${PASSWORD}>, <${CONFIRM}>"

  # password validation
  if [[ -z "$PASSWORD" ]] || [[ "$PASSWORD" != "$CONFIRM" ]]; then
    echo "passwords do not match"
    return 1
  fi

  ncp-borgbackup "$DESTDIR" "$REPOSITORY" "$PASSWORD" "$CHECKREPO"
}

# License
#
# This script is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this script; if not, write to the
# Free Software Foundation, Inc., 59 Temple Place, Suite 330,
# Boston, MA  02111-1307  USA

