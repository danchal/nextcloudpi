#!/bin/bash
# Nextcloud restore borgbackup
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# More at https://ownyourbits.com/2017/02/13/nextcloud-ready-raspberry-pi-image/
#

install() { :; }

configure()
{
  set -eE
  
  PHPVER=7.2

  [[ ! -d "$REPODIR" ]] && { echo "repository directory <${REPODIR}> not found"; return 1; }
  [[ -z "$REPONAME" ]] && { echo "Repository name is not set"; return 1; }
  [[ -z "$ARCHIVE" ]] && { echo "Archive name is not set"; return 1; }

  export BORG_PASSPHRASE="${PASSWORD}"

  cleanup(){ local ret=$?; rm -rf "${ARCHDIR}" ; $occ maintenance:mode --off; return $ret; }
  fail(){
    local ret=$?
    echo "Abort..."
    rm -rf "${ARCHDIR}"

    # backup directory exists then reinstate it
    [[ -d "$NCBACKUPDIR" ]] && \
      rm -rf "${basedir}/nextcloud" && \
      mv "${NCBACKUPDIR}" "${basedir}/nextcloud"
    
    $occ maintenance:mode --off
    return $ret
  }

  trap cleanup EXIT
  trap fail INT TERM HUP ERR

  [[ -f /.docker-image ]] && basedir=/data || basedir=/var/www

  occ="sudo -u www-data php /var/www/nextcloud/occ"

  datadir=$( $occ config:system:get datadirectory ) || {
    echo "Error reading data directory. Is NextCloud running and configured?";
    return 1;
  }

  echo "datadir<${datadir}>, basedir<${basedir}>"

  # assumption is that the nextcloud data directory is a subdirectory of the base directory
  [[ "$datadir" != "${basedir}/nextcloud/data" ]] && { echo "Error: nextcloud data directory is NOT a subdirectory of the base directory"; return 1; }

  ncpdir="/usr/local/etc/ncp-config.d"

  ARCHDIR="$( mktemp -d "${basedir}/ncp-restore-borg.XXXXXX" )" || { echo "Failed to create temp dir" >&2; return 1; }
  ARCHDIR="$( cd "$ARCHDIR" &>/dev/null && pwd )" || { echo "$ARCHDIR not found"; return 1; } #abspath
  rm -rf "$ARCHDIR" && mkdir -p "$ARCHDIR"
  
  NCBACKUPDIR="${basedir}/nextcloud-$(date "+%s")"

  ## EXTRACT ARCHIVE
  cd "$ARCHDIR"

  echo "extracting archive ..."
  borg extract \
    "${REPODIR}/${REPONAME}::${ARCHIVE}" \
    || {
          echo "error extracting archive"
          return 1
        }

  ## SANITY CHECKS
  [[ -d "${ARCHDIR}/nextcloud" ]] && [[ -f "$( ls "${ARCHDIR}"/nextcloud-sqlbkp_*.bak 2>/dev/null )" ]] || {
    echo "invalid backup file. Abort"
    return 1
  }

  # get the data directory of the archive
  ARCHDATADIR=$( grep datadirectory "${ARCHDIR}/nextcloud/config/config.php" | awk '{ print $3 }' | grep -oP "[^']*[^']" | head -1 )
  
  # verify that the archive data directory is readable
  [[ -z "$ARCHDATADIR" ]] && { echo "Error reading archive data directory"; return 1; }

  ## BEGIN RESTORE
  # turn on maintenance mode
  $occ maintenance:mode --on

  # rename the original nextcloud directory 
  echo "renameing original nextcloud directory..."
  mv "${basedir}/nextcloud" "${NCBACKUPDIR}" || { echo "Error moving original nextcloud files"; return 1; }
    
  # restoring all files
  echo "restoring nc..."
  mv "${ARCHDIR}/nextcloud" "${basedir}" || { echo "Error restoring old nextcloud files"; return 1; }

  # restoring ncp
  if [[ "$RESTORENCP" == "yes" ]]; then
    echo "restoring ncp..."
    # move original files to tmp directory
    mv "${ncpdir}/*" "${NCBACKUPDIR}/ncp" || { echo "Error moving current ncp files"; return 1; }
    
    # move restored ncp files into base directory
    mv "${ARCHDIR}${ncpdir}/*" "${ncpdir}" || { echo "Error restoring old ncp files"; return 1; }
  fi
  
  # DB
  echo "restoring db..."
  DBADMIN=ncadmin
  DBPASSWD="$( grep password /root/.my.cnf | sed 's|password=||' )"

  # update NC database password to this instance
  sed -i "s|'dbpassword' =>.*|'dbpassword' => '$DBPASSWD',|" /var/www/nextcloud/config/config.php

  # update redis credentials
  REDISPASS="$( grep "^requirepass" /etc/redis/redis.conf | cut -f2 -d' ' )"
  [[ "$REDISPASS" != "" ]] && \
    sed -i "s|'password'.*|'password' => '$REDISPASS',|" /var/www/nextcloud/config/config.php
  service redis-server restart

  ## RE-CREATE DATABASE TABLE
  echo "restore database..."
mysql -u root <<EOFMYSQL
DROP DATABASE IF EXISTS nextcloud;
CREATE DATABASE nextcloud;
GRANT USAGE ON *.* TO '$DBADMIN'@'localhost' IDENTIFIED BY '$DBPASSWD';
DROP USER '$DBADMIN'@'localhost';
CREATE USER '$DBADMIN'@'localhost' IDENTIFIED BY '$DBPASSWD';
GRANT ALL PRIVILEGES ON nextcloud.* TO $DBADMIN@localhost;
EXIT
EOFMYSQL
[ $? -ne 0 ] && { echo "Error configuring nextcloud database"; return 1; }

  mysql -u root nextcloud <  "$ARCHDIR"/nextcloud-sqlbkp_*.bak || { echo "Error restoring nextcloud database"; return 1; }

  # turn off maintenance mode
  $occ maintenance:mode --off

  # rescan files if db and files are not both restored together
  if [[ "$RESTOREDB" != "$RESTOREDATA" ]]; then
    $occ files:scan --all

    # cache needs to be cleaned as of NC 12
    NEED_RESTART=1
  fi

  # Just in case we moved the opcache dir
  sed -i "s|^opcache.file_cache=.*|opcache.file_cache=${datadir}/.opcache|" /etc/php/${PHPVER}/mods-available/opcache.ini

  # tmp upload dir
  mkdir -p "$datadir/tmp" 
  chown www-data:www-data "$datadir/tmp"
  sed -i "s|^;\?upload_tmp_dir =.*$|upload_tmp_dir = $datadir/tmp|" /etc/php/${PHPVER}/cli/php.ini
  sed -i "s|^;\?upload_tmp_dir =.*$|upload_tmp_dir = $datadir/tmp|" /etc/php/${PHPVER}/fpm/php.ini
  sed -i "s|^;\?sys_temp_dir =.*$|sys_temp_dir = $datadir/tmp|"     /etc/php/${PHPVER}/fpm/php.ini

  # update fail2ban logpath
  [[ ! -f /.docker-image ]] && {
    sed -i "s|logpath  =.*|logpath  = $datadir/nextcloud.log|" /etc/fail2ban/jail.conf
    pgrep fail2ban &>/dev/null && service fail2ban restart
  }

  # refresh nextcloud trusted domains
  bash /usr/local/bin/nextcloud-domain.sh

  # update the systems data-fingerprint
  sudo -u www-data php occ maintenance:data-fingerprint

  # refresh thumbnails
  sudo -u www-data php occ files:scan-app-data

  # restart PHP if needed
  [[ "$NEED_RESTART" == "1" ]] && \
    bash -c " sleep 3; service php${PHPVER}-fpm restart" &>/dev/null &
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
