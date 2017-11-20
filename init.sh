#!/bin/bash
# First run initialization script
# Run this script with: sudo nems-init
# It's already in the path via a symlink

ver=$(/usr/local/share/nems/nems-scripts/info.sh nemsver) 

echo ""
echo Welcome to NEMS initialization script.
echo ""
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root" 2>&1
  exit 1
else

  # Perform any fixes that have been released since NEMS was built
  /usr/local/share/nems/nems-scripts/fixes.sh

  if [[ -d /home/pi ]]; then
    # Must continue to support NEMS 1.1 and 1.2.x
    echo "First, let's change the password of the pi Linux user..."
    echo "REMEMBER: This will be the password you'll use for SSH/Local Login and Webmin."
    echo "If you do not want to change it, simply enter the existing password."
    while true; do
      read -s -p "New Password for pi user: " pipassword
      echo
      read -s -p "New Password for pi user (again): " pipassword2
      echo
      [ "$pipassword" = "raspberry" ] && pipassword="-" && echo "You are not allowed to use that password."
      [ "$pipassword" = "" ] && pipassword="-" && echo "You can't leave the password blank."
      [ "$pipassword" = "$pipassword2" ] && break
      echo "Please try again"
    done
    echo -e "$pipassword\n$pipassword" | passwd pi >/tmp/init 2>&1

    echo "Your new password has been set for the Linux pi user."
    echo "Use that password to access NEMS over SSH or when logging in to Webmin."
  fi

  echo ""

  isValidUsername() {
    local re='^[[:lower:]_][[:lower:][:digit:]_-]{2,15}$'
    (( ${#1} > 16 )) && return 1
    [[ $1 =~ $re ]]
  }
  while true; do
  read -p "What would you like your NEMS Username to be? " username
    if [[ ${username,,} == $username ]]; then
      if isValidUsername "$username"; then
        echo Username accepted.
        break
      else
        echo Username is invalid. Please try again.
      fi
    else 
      echo Username must be all lowercase. Please try again.
    fi
  done

  while true; do
    read -s -p "Password: " password
    echo
    read -s -p "Password (again): " password2
    echo
    [ "$password" = "nemsadmin" ] && password="-" && echo "You are not allowed to use that password."
    [ "$password" = "raspberry" ] && password="-" && echo "You are not allowed to use that password."
    [ "$password" = "" ] && password="-" && echo "You can't leave the password blank."
    [ "$password" = "$password2" ] && break
    echo "Please try again"
  done

  # In case this is a re-initialization, clear the init file (remove old login), then add this user
  echo "">/var/www/htpasswd && echo $password | /usr/bin/htpasswd -B -c -i /var/www/htpasswd $username

  # Create the Linux user
  adduser --disabled-password --gecos "" $username
  # Giving you files
  cp /home/nemsadmin/* /home/$username/
  # Allow user to become super-user
  usermod -aG sudo $username
  # Allow user to login to monit web interface
  usermod -aG monit $username
  # Set the user password
  echo -e "$password\n$password" | passwd $username >/tmp/init 2>&1

  # Reset the RPi-Monitor user
  cp /root/nems/nems-migrator/data/rpimonitor/daemon.conf /etc/rpimonitor

  # Configure RPi-Monitor to run as the new user
  /bin/sed -i -- 's/nemsadmin/'"$username"'/g' /etc/rpimonitor/daemon.conf

  # Samba config
    # Create Samba User
    echo -e "$password\n$password" | smbpasswd -s -a $username
    # Reset Samba users
    cp /root/nems/nems-migrator/data/samba/smb.conf /etc/samba
    # Configure new samba user
    /bin/sed -i -- 's/nemsadmin/'"$username"'/g' /etc/samba/smb.conf
    systemctl restart smbd

  # Delete the initial admin account
  if [[ -d /home/$username ]] && [[ -d /home/nemsadmin ]]; then
    # echo "Deleting nemsadmin user. Remember you must now login as $username"
    # userdel -r nemsadmin

    # nemsadmin user will be deleted automatically now that you're initialized, but this stuff is just to protect users in case for some reason the nemsuser user remains.
    echo "Disabling nemsadmin access. Remember you must now login as $username"
    deluser nemsadmin sudo # Remove super user access from nemsadmin account
    rndpass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
    echo -e "$rndpass\n$rndpass" | passwd nemsadmin >/tmp/init 2>&1 # set a random password on the account so no longer can login
  fi

echo Initializing new Nagios user
systemctl stop nagios3

# Reininitialize Nagios3 user account
  echo "define contactgroup {
                contactgroup_name                     admins
                alias                                 Nagios Administrators
                members                               $username
}
" > /etc/nagios3/global/contactgroups.cfg
  echo "define contact {
                contact_name                          $username
                alias                                 Nagios Admin
                host_notification_options             d,u,r,f,s
                service_notification_options          w,u,c,r,f,s
                email                                 nagios@localhost
                host_notification_period              24x7
                service_notification_period           24x7
                host_notification_commands            notify-host-by-email
                service_notification_commands         notify-service-by-email
}
" > /etc/nagios3/global/contacts.cfg

# Replace the database with Sample database
service mysql stop
rm -rf /var/lib/mysql/
cp -R /root/nems/nems-migrator/data/mysql/NEMS-Sample /var/lib
chown -R mysql:mysql /var/lib/NEMS-Sample
mv /var/lib/NEMS-Sample /var/lib/mysql
service mysql start

# Replace the Nagios3 cgi.cfg file with the sample and add username
cp -f /root/nems/nems-migrator/data/nagios/conf/cgi.cfg /etc/nagios3/
/bin/sed -i -- 's/nagiosadmin/'"$username"'/g' /etc/nagios3/cgi.cfg

# Replace the Check_MK users.mk file with the sample and add username
cp -f /root/nems/nems-migrator/data/check_mk/users.mk /etc/check_mk/multisite.d/wato/users.mk
/bin/sed -i -- 's/nagiosadmin/'"$username"'/g' /etc/check_mk/multisite.d/wato/users.mk
chown www-data:www-data /etc/check_mk/multisite.d/wato/users.mk

# Remove nconf history, should it exist
mysql -u nconf -pnagiosadmin nconf -e "TRUNCATE History"

# Import new configuration into NConf
echo "  Importing: contact" && /var/www/nconf/bin/add_items_from_nagios.pl -c contact -f /etc/nagios3/global/contacts.cfg 2>&1 | grep -E "ERROR"
echo "  Importing: contactgroup" && /var/www/nconf/bin/add_items_from_nagios.pl -c contactgroup -f /etc/nagios3/global/contactgroups.cfg 2>&1 | grep -E "ERROR"
  
systemctl start nagios3

# Localization

  # Configure timezone
  dpkg-reconfigure tzdata

  # Forcibly restart cron to prevent tasks running at wrong times after timezone update
  service cron stop && service cron start

  # Configure the keyboard locale
#  echo ""
#  echo "Let's configure your keyboard."
#  echo "NOTE: If you do not have a keyboard plugged into your NEMS server, this will be skipped."
#  echo ""
#  read -n 1 -s -p "Press any key to continue"
#  dpkg-reconfigure keyboard-configuration && service keyboard-setup restart

# /Localization

if (( $(awk 'BEGIN {print ("'$ver'" >= "'1.3'")}') )); then

  # Configure NagVis user
  if [ -f /etc/nagvis/etc/auth.db ]; then
    rm /etc/nagvis/etc/auth.db
  fi
  cp /root/nems/nems-migrator/data/nagvis/auth.db /etc/nagvis/etc/
  chown www-data:www-data /etc/nagvis/etc/auth.db
  # Note, this is being added as specifically userId 1 as this user is users2role 1, administrator
  # NagVis hashes its SHA1 passwords with the long string, which is duplicated in the nagvis ini file - /etc/nagvis/etc/nagvis.ini.php
  sqlite3 /etc/nagvis/etc/auth.db "INSERT INTO users (userId,name,password) VALUES (1,'$username','$(echo -n '29d58ead6a65f5c00342ae03cdc6d26565e20954'$password | sha1sum | awk '{print $1}')');"


  # Setup SSL Certificates
  /usr/local/bin/nems-cert

fi

  echo ""

  echo "Now we will resize your root partition to give you access to all the space"

  /usr/bin/raspi-config --expand-rootfs > /dev/null 2>&1
  echo "Done."

  echo ""
  echo "NOTICE: When you reboot, you must login as $username"
  echo ""
  read -n 1 -s -p "Press any key to reboot (required)"

  reboot

fi
