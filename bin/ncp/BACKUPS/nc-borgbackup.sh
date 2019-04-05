#!/bin/bash
# Nextcloud borgbackup
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# More at https://ownyourbits.com/2017/02/13/nextcloud-ready-raspberry-pi-image/
#

install()
{
  echo "running borgbackup install"

  # install borgbackup if not installed
  borg -V >/dev/null \
  || {
      # Debian package version is quite old
      # if using x86_64 then get latest stable borgbackup binary direct from borg github

      if [[ $(arch) == "x86_64" ]]; then
        wget \
        https://github.com/borgbackup/borg/releases/download/1.1.9/borg-linux64 \
        -O /usr/local/bin/borg

        chown root:root /usr/local/bin/borg
        chmod 755 /usr/local/bin/borg

      else
        # use older packaged version
        apt-get install borgbackup
      fi
  }

  cat > /usr/local/bin/ncp-borgbackup <<'EOF'
#!/bin/bash
set -eE

echo "Starting ${0}..."

repodir="${1}"
reponame="${2}"
export BORG_PASSPHRASE="${3}"
checkrepo="${4}"

[[ ! -d "$repodir" ]] && { echo "repository directory <${repodir}> not found"; exit 1; }
[[ -z "$reponame" ]] && { echo "Repository name is not set"; exit 1; }

prunecmd="--keep-within=2d --keep-daily=7 --keep-weekly=4 --keep-monthly=-1"
archive="{hostname}-{now:%Y-%m-%dT%H:%M:%S}"
dbbackup=nextcloud-sqlbkp_$( date +"%Y%m%d" ).bak
occ="sudo -u www-data php /var/www/nextcloud/occ"

[[ -f /.docker-image ]] && basedir=/data || basedir=/var/www

datadir=$( $occ config:system:get datadirectory ) || {
  echo "Error reading data directory. Is NextCloud running and configured?";
  exit 1;
}

ncpdir="/usr/local/etc/ncp-config.d"

cleanup(){ local ret=$?;                    rm -f "${dbbackup}" ; $occ maintenance:mode --off; exit $ret; }
fail()   { local ret=$?; echo "Abort..."  ; rm -f "${dbbackup}" ; $occ maintenance:mode --off; exit $ret; }
trap cleanup EXIT
trap fail INT TERM HUP ERR

# assumption is that the nextcloud data directory is a subdirectory of the base directory
[[ "$datadir" != "${basedir}/nextcloud/data" ]] && { echo "Error: nextcloud data directory is NOT a subdirectory of the base directory"; exit 1; }

mkdir -p "$repodir"

# if password is empty then do not encrypt the repository
if [[ -z "$BORG_PASSPHRASE" ]]; then
  encryption=none
else
  encryption=repokey-blake2
fi

# if repository path does not already exist then initialise repository
if [[ ! -d "${repodir}/${reponame}" ]]; then
  echo "initialising repository (encryption=${encryption})..."
  cmd_output=$( \
      /usr/local/bin/borg init \
        --encryption="$encryption" \
        "${repodir}/${reponame}" \
      2>&1 ) \
  || {
        echo "error initialising repository: ${cmd_output}"
        exit 1
      }
fi

# prune older backups
echo "pruning backups..."
cmd_output=$( \
  /usr/local/bin/borg prune \
    ${prunecmd} \
    "${repodir}/${reponame}" \
  2>&1 ) \
|| {
      echo "error performing borg prune: ${cmd_output}"
      exit 1
    }

# database
$occ maintenance:mode --on
cd "$basedir" || exit 1
echo "backup database..."
mysqldump -u root --single-transaction nextcloud > "$dbbackup"

# create archive
cd "$basedir"
echo "creating archive..."
cmd_output=$( \
  /usr/local/bin/borg create \
    --exclude "database" \
    --exclude "nextcloud/data/.opcache" \
    --exclude "nextcloud/data/*.log" \
    --exclude "nextcloud/data/appdata_*/previews/*" \
    --exclude "nextcloud/data/ncp-update-backups/" \
    "${repodir}/${reponame}::${archive}" \
    . \
    "$ncpdir" \
  2>&1 ) \
|| {
      echo "error creating archive: ${cmd_output}"
      exit 1
    }

# turn off maintenance mode as repository check could take some time
$occ maintenance:mode --off

# check
if [[ "$checkrepo" == "yes" ]]; then
  echo "verifying repository..."
  cmd_output=$( \
    /usr/local/bin/borg --info \
      check \
      --verify-data \
      "${repodir}/${reponame}" \
    2>&1 ) \
  || {
    echo "error verifying repository: ${cmd_output}"
    exit 1
  }
fi

echo "borgbackup ${repodir}/${reponame} generated"
EOF
  chmod +x /usr/local/bin/ncp-borgbackup
}

configure()
{
  echo "running borgbackup configure"

  # password validation
  if [[ -n "$PASSWORD" ]] && [[ "$PASSWORD" != "$CONFIRM" ]]; then
    echo "passwords do not match"
    return 1
  fi

  ncp-borgbackup "$REPODIR" "$REPONAME" "$PASSWORD" "$CHECKREPO"
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

