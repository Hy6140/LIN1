#!/usr/bin/bash
# ==============================================================================================================
# Title         -   SRV02_LIN1_SCRIPT-02.sh
# Author        -   Nuno Ribeiro Pereira (nuno.ribeiro@eduvaud.ch)
# Creation      -   11.11.24
# Last Update   -   05.11.24 by Nuno Ribeiro Pereira
#
# Description   -   This script automates the installation and a part of the configuration of nextcloud.
#                   All the packages necessary are installed by the script.
#                   
# Prerequisites -   Debian with a compatible version
#                   Admin privilieges
#                   Network configured by 'SRV02_LIN1_SCRIPT-02.sh'
#
# Valid Systems -   Debian 12.6.4 | Debian 11.2.0
# Version       -   V2.0
# ==============================================================================================================

#region variables
NextCloud_Version="latest"
NextCloud_Dir="/var/www/html/nextcloud"
NextCloudDbName="nextcloud"
NextCloudDbUser="admin"
NextCloudDbPassword="Password"

Ldap_Domain_Name="lin1.local"

Hostname_SRV2="SRV-LIN1-02"
#endregion

#region Functions

# Check if the specified package is installed
function InstallIfNeeded {
    if ! dpkg -l | grep -q "$1"; then
        echo -e "\e[33mInstalling $1\e[0m"
        apt-get -y install "$1"  >/dev/null 2>&1 
    else
        echo -e "\e[32m$1: Already installed\e[0m"
    fi
}

# Installs Nextcloud
function InstallNextCloud {
    echo -e "\e[33mDownloading NextCloud\e[0m"
    wget https://download.nextcloud.com/server/releases/$NextCloud_Version.zip -P /tmp >/dev/null 2>&1 
    
    if [ ! -d "/var/www/html" ]; then
        mkdir -p /var/www/html >/dev/null 2>&1 
    fi
    echo -e "\e[33mExtracting NextCloud zip\e[0m"
    unzip /tmp/$NextCloud_Version.zip -d /var/www/html/ >/dev/null 2>&1 
    
    echo -e "\e[33mConfiguring permissions\e[0m"
    chown -R www-data:www-data $NextCloud_Dir >/dev/null 2>&1 
    chmod -R 755 $NextCloud_Dir >/dev/null 2>&1 
    systemctl restart apache2 
}

# Configures MariaDB for Nextcloud
function ConfigureMariaDB {
    echo -e "\e[33mConfiguring MariaDB\e[0m"
    mysql --user=root --password="$NextCloudDbPassword" <<EOF
CREATE DATABASE IF NOT EXISTS \`$NextCloudDbName\`;
CREATE USER IF NOT EXISTS '$NextCloudDbUser'@'localhost' IDENTIFIED BY '$NextCloudDbPassword';
GRANT ALL PRIVILEGES ON \`$NextCloudDbName\`.* TO '$NextCloudDbUser'@'localhost';
FLUSH PRIVILEGES;
EOF
}

# Configures Apache for the site to be avalaible
function ConfigureApache {
    echo -e "\e[33mConfiguring Apache\e[0m"
    cat <<EOF > /etc/apache2/sites-available/nextcloud.conf
<VirtualHost *:80>
    DocumentRoot /var/www/html/nextcloud
    ServerName srv-lin1-02.lin1.local

    <Directory /var/www/html/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

    echo -e "\e[33mActivating apache modules\e[0m"
    a2ensite nextcloud.conf >/dev/null 2>&1 
    a2enmod rewrite headers env dir mime setenvif ssl >/dev/null 2>&1 

    systemctl reload apache2 >/dev/null 2>&1 
}

# Configures SSL, creates folder, sub-folders and sets permissions for NextCloud
function ConfigureNextCloud {
    echo -e "\e[33mGenerating SSL Certificate\e[0m"
    mkdir -p /etc/ssl/private /etc/ssl/certs >/dev/null 2>&1 

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/selfsigned.key -out /etc/ssl/certs/selfsigned.crt >/dev/null 2>&1 <<EOF
CH
Vaud
Ste-Croix
CPNV
Tech
10.10.10.22
nuno.ribeiro@eduvaud.ch
EOF

    echo -e "\e[33mConfiguring SSL Parameters\e[0m"
    cat <<EOF >/etc/apache2/conf-available/ssl-params.conf 
SSLCipherSuite EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH
SSLProtocol All -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
SSLHonorCipherOrder On
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
Header always set X-Frame-Options DENY
Header always set X-Content-Type-Options nosniff
SSLCompression off
SSLUseStapling on
SSLStaplingCache "shmcb:logs/stapling-cache(150000)"
SSLSessionTickets Off
EOF

    echo -e "\e[33mUpdating Apache SSL Configuration\e[0m"
    cat <<EOF >/etc/apache2/sites-available/default-ssl.conf  
<IfModule mod_ssl.c>
    <VirtualHost _default_:443>
        ServerAdmin nuno.ribeiro@eduvaud.ch
        ServerName 10.10.10.22
        DocumentRoot /var/www/html/nextcloud

        ErrorLog \${APACHE_LOG_DIR}/error.log
        CustomLog \${APACHE_LOG_DIR}/access.log combined

        SSLEngine on
        SSLCertificateFile /etc/ssl/certs/selfsigned.crt
        SSLCertificateKeyFile /etc/ssl/private/selfsigned.key

        <FilesMatch "\\.(cgi|shtml|phtml|php)$">
            SSLOptions +StdEnvVars
        </FilesMatch>
        <Directory /usr/lib/cgi-bin>
            SSLOptions +StdEnvVars
        </Directory>
    </VirtualHost>
</IfModule>
EOF

    echo -e "\e[33mEnabling SSL Modules and Configuration\e[0m"
    a2enmod ssl headers >/dev/null 2>&1 
    a2ensite default-ssl >/dev/null 2>&1 
    a2enconf ssl-params >/dev/null 2>&1 

    echo -e "\e[33mReloading Apache with SSL Configuration\e[0m"
    systemctl reload apache2 

    echo -e "\e[33mCreating mount point and sub-folders\e[0m"
    mkdir -p /mnt/share >/dev/null 2>&1 
    mkdir -p /mnt/share/Perso >/dev/null 2>&1 
    mkdir -p /mnt/share/Clients >/dev/null 2>&1 
    mkdir -p /mnt/share/Softwares >/dev/null 2>&1 
    mkdir -p /mnt/share/Commun >/dev/null 2>&1 

    echo -e "\e[33mSetting permissions for NextCloud\e[0m"
    chown www-data:www-data /mnt/share >/dev/null 2>&1 
    chown www-data:www-data /mnt/share/Perso >/dev/null 2>&1 

    echo -e "\e[33mDeleting the files template of NextCloud\e[0m"
    rm -r /var/www/html/nextcloud/core/skeleton/* >/dev/null 2>&1 
}
#endregion

#region Main

# Update package list and upgrade system
echo -e "\e[36m===Packages installations===\e[0m"
InstallIfNeeded net-tools
InstallIfNeeded apache2
InstallIfNeeded apache2-utils
InstallIfNeeded mariadb-server
InstallIfNeeded libapache2-mod-php
InstallIfNeeded php
InstallIfNeeded php-zip
InstallIfNeeded php-mbstring
InstallIfNeeded php-xml
InstallIfNeeded php-gd
InstallIfNeeded php-curl
InstallIfNeeded php-mysql
InstallIfNeeded php-ldap
InstallIfNeeded wget
InstallIfNeeded unzip
InstallIfNeeded nfs-common
InstallIfNeeded certbot
InstallIfNeeded python3-certbot-apache

# NextCloud installation
echo -e "\e[36m===Installing NextCloud===\e[0m"
InstallNextCloud
echo ""

echo -e "\e[36m===Configuring MariaDB for NextCloud===\e[0m"
ConfigureMariaDB
echo ""

echo -e "\e[36m===Configuring Apache for NextCloud===\e[0m"
ConfigureApache
echo ""

echo -e "\e[36m===Configuring NextCloud===\e[0m"
ConfigureNextCloud
echo ""
#endregion
