#!/bin/bash
# Nextcloud borgbackups
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# More at https://ownyourbits.com/2017/02/13/nextcloud-ready-raspberry-pi-image/
#

configure()
{
  [[ $ACTIVE != "yes" ]] && {
    rm -f /etc/cron.d/ncp-borgbackup-auto
    service cron restart
    echo "automatic borgbackups disabled"
    return 0
  }

  # password validation
  if [[ -n "$PASSWORD" ]] && [[ "$PASSWORD" != "$CONFIRM" ]]; then
    echo "passwords do not match"
    return 1
  fi

  cat > /usr/local/bin/ncp-borgbackup-auto <<EOF
#!/bin/bash
/usr/local/bin/ncp-borgbackup "$REPODIR" "$REPONAME" "$PASSWORD" "$CHECKREPO" || failed=true
[[ "\$failed" == "true" ]] && \
 /usr/local/bin/ncc notification:generate "$NOTIFYUSER" "Auto-borgbackup failed" -l "Your automatic borgbackup failed"
EOF
  chmod +x /usr/local/bin/ncp-borgbackup-auto

  echo "0  3  */${BACKUPDAYS}  *  *  root  /usr/local/bin/ncp-borgbackup-auto" > /etc/cron.d/ncp-borgbackup-auto
  chmod 644 /etc/cron.d/ncp-borgbackup-auto
  service cron restart

  echo "automatic borgbackups enabled"
}

install() { :; }

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

