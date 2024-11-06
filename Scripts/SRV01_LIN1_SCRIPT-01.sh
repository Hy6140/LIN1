#!/usr/bin/bash
# ==============================================================================================================
# Title         -   SRV01_LIN1_SCRIPT-01.sh
# Author        -   Nuno Ribeiro Pereira (nuno.ribeiro@eduvaud.ch)
# Creation      -   10.11.24
# Last Update   -   01.11.24 by Nuno Ribeiro Pereira
#
# Description   -   This script automates the installation and configuration of a dns, dhcp, routage and ldap.
#                   All the packages necessary are installed by the script.
#                   
# Prerequisites -   Debian with a compatible version
#                   Admin privilieges
#                   2 interfaces ( Host-Only | NAT )
#
# Valid Systems -   Debian 12.6.4 | Debian 11.2.0
# Version       -   V1.0
# ==============================================================================================================

#region variables
File_NetworkInterfaces="/etc/network/interfaces" 
File_SysCtl="/etc/sysctl.conf"
File_Resolv="/etc/resolv.conf"
File_DnsMasq="/etc/dnsmasq.conf"
File_Dhclient="/etc/dhcp/dhclient.conf"
File_Ldap="/etc/ldap/ldap.conf"
File_Ldap_Ou="./ldap_ou.ldif"
File_Ldap_Users="./ldap_users.ldif"
File_Ldap_Groups="./ldap_groups.ldif"
File_Ldap_Admin="./ldap_admin.ldif"

Ip_SRV1="10.10.10.11"
Ip_SRV2="10.10.10.22"
Ip_NAS1="10.10.10.33"
Ip_Mask="255.255.255.0"
Ip_Gateway=$Ip_SRV1
Ip_DNS1=$Ip_SRV1
Ip_DNS2="8.8.8.8"
Ip_DNS_CPNV="10.229.60.22"
Ip_DHCP_START="10.10.10.100"
Ip_DHCP_END="10.10.10.150"

Int_HostOnly="ens33"
Int_Nat="ens34"

Ldap_Domain_Name="lin1.local"
Ldap_Organization="lin1-labo"
Ldap_Admin_Password="Password"
Ldap_Domain_Controller="dc=lin1,dc=local"
Ldap_Users_Controller="ou=Users,$Ldap_Domain_Controller"
Ldap_Groups_Controller="ou=Groups,$Ldap_Domain_Controller"

Hostname_SRV1="SRV-LIN1-01"
Hostname_SRV2="SRV-LIN1-02"
Hostname_NAS1="NAS-LIN1-01"
#endregion

#region Functions

# Reverse the given ip address
function ReverseIp {
    echo "$1" | awk -F. '{print $4"."$3"."$2"."$1}'
}

# Check if the specified package is installed
function InstallIfNeeded {
    if ! dpkg -l | grep -q "$1"; then
        echo -e "\e[33mInstalling $1\e[0m"

        if [ "$1" == "slapd" ]; then
            echo "slapd slapd/password1 password $Ldap_Admin_Password" | debconf-set-selections 
            echo "slapd slapd/password2 password $Ldap_Admin_Password" | debconf-set-selections 
            echo "slapd slapd/domain string $Ldap_Domain_Name" | debconf-set-selections 
            echo "slapd shared/organization string $Ldap_Organization" | debconf-set-selections 
            echo "slapd slapd/purge_database boolean true" | debconf-set-selections 
            echo "slapd slapd/move_old_database boolean true" | debconf-set-selections 
       
            DEBIAN_FRONTEND=noninteractive dpkg-reconfigure slapd >/dev/null 2>&1 
        fi
        apt-get -y install "$1" >/dev/null 2>&1 
    else
        echo -e "\e[32m$1: Already installed\e[0m"
    fi
}

# Check if iptables-persistent is installed
function InstallIfNeededIptablesPersistent {
    if ! dpkg -l | grep -q "iptables-persistent"; then
        echo -e "\e[33mInstalling iptables-persistent\e[0m"
        echo -e iptables-persistent iptables-persistent/autosave_v4 boolean true  | debconf-set-selections >/dev/null 2>&1
        echo -e iptables-persistent iptables-persistent/autosave_v6 boolean false  | debconf-set-selections >/dev/null 2>&1
        apt-get -y install iptables-persistent >/dev/null 2>&1 
    else
        echo -e "\e[32miptables-persistent: Already installed\e[0m"
    fi
}

# Configure the hostname
function ConfigureHostname {
    current_hostname=$(hostnamectl status --static)
    if [ "$current_hostname" != "$Hostname_SRV1.$Ldap_Domain_Name" ]; then
        echo -e "\e[33mConfiguring hostname\e[0m"
        hostnamectl set-hostname $Hostname_SRV1.$Ldap_Domain_Name
    else
        echo -e "\e[32mHostname already set to $Hostname_SRV1.$Ldap_Domain_Name\e[0m"
    fi
}

# Configure the 2 interfaces (Host-Only | NAT) + the routing in Sysctl and with iptables
function ConfigureRouting {
    if ! grep -q "address $Ip_SRV1/24" $File_NetworkInterfaces; then
        echo -e "\e[33mInterfaces file: Configuring network interfaces\e[0m"
        cat <<EOF > $File_NetworkInterfaces
# The loopback network interface
auto lo
iface lo inet loopback

# Interface $Int_HostOnly (Host-Only)
auto $Int_HostOnly
allow-hotplug $Int_HostOnly
iface $Int_HostOnly inet static
address $Ip_SRV1/24

# Interface $Int_Nat (NAT)
auto $Int_Nat
allow-hotplug $Int_Nat
iface $Int_Nat inet dhcp
EOF
        systemctl restart networking.service
    else
        echo -e "\e[32mInterfaces file: Network interfaces are already configured\e[0m"
    fi

    if ! grep -q "^net.ipv4.ip_forward=1" $File_SysCtl; then
        echo -e "\e[33mSysctl file: Enabling IP forwarding\e[0m"
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' $File_SysCtl >/dev/null 2>&1 

        iptables -t nat -A POSTROUTING -o $Int_Nat -j MASQUERADE >/dev/null 2>&1 

        netfilter-persistent save >/dev/null 2>&1 
        sysctl -p >/dev/null 2>&1
    else
        echo -e "\e[32mSysctl file: IP forwarding is already enabled\e[0m"
    fi
}

# Configure the DNS in dnsmasq file + the resolv.conf file
function ConfigureDns {
    if ! grep -q "address=/$Hostname_SRV1.$Ldap_Domain_Name/$Ip_SRV1" $File_DnsMasq; then
        echo -e "\e[33mDnsmasq file: Applying the local domain names to IP addresses and PTR inverted resolutions\e[0m"
        cat <<EOF > $File_DnsMasq
# Associe les noms de domaine locaux aux adresses IP
address=/$Hostname_SRV1.$Ldap_Domain_Name/$Ip_SRV1
address=/$Hostname_SRV2.$Ldap_Domain_Name/$Ip_SRV2
address=/$Hostname_NAS1.$Ldap_Domain_Name/$Ip_NAS1

# Enregistrements PTR pour la résolution inverse
ptr-record=$(ReverseIp $Ip_SRV1).in-addr.arpa.,$Hostname_SRV1.$Ldap_Domain_Name
ptr-record=$(ReverseIp $Ip_SRV2).in-addr.arpa.,$Hostname_SRV2.$Ldap_Domain_Name
ptr-record=$(ReverseIp $Ip_NAS1).in-addr.arpa.,$Hostname_NAS1.$Ldap_Domain_Name

# Configuration d'un serveur DNS externe
server=$Ip_DNS_CPNV
EOF
    else
        echo -e "\e[32mDnsmasq file: local domain names to IP addresses and PTR inverted resolutions are already applied\e[0m"
    fi

    if ! grep -q "domain $Ldap_Domain_Name" $File_Resolv; then
        echo -e "\e[33mResolv file: Configuring domain and nameservers\e[0m"
        cat <<EOF > $File_Resolv
domain $Ldap_Domain_Name
search $Ldap_Domain_Name
nameserver $Ip_DNS1
nameserver $Ip_DNS2
EOF
    systemctl restart dnsmasq.service
    else
        echo -e "\e[32mResolv file: domain and nameservers are already configured\e[0m"
    fi 
}

# Configure DHCP in dnsmasq file
function ConfigureDhcp {
    if grep -q "domain-name, domain-name-servers, domain-search, host-name" $File_Dhclient; then
        echo -e "\e[33mDhclient file: Deleting line\e[0m"
        sed -i '/domain-name, domain-name-servers, domain-search, host-name/d' $File_Dhclient >/dev/null 2>&1 
    else
        echo -e "\e[32mDhclient file: Line is already deleted\e[0m"
    fi

    if ! grep -q "dhcp-option=option:netmask,$Ip_Mask" $File_DnsMasq; then
        echo -e "\e[33mDnsMasq file: Adding line\e[0m"
        cat <<EOF >> $File_DnsMasq

# Activation du DHCP sur l'interface
interface=$Int_HostOnly

# Définition de la plage d'adresses IP à distribuer
dhcp-range=$Ip_DHCP_START,$Ip_DHCP_END,12h

# Spécification de la passerelle 
dhcp-option=option:router,$Ip_Gateway

# Spécifier les serveurs DNS (local et externe)
dhcp-option=option:dns-server,$Ip_DNS1,$Ip_DNS2

# Définir le nom de domaine local
dhcp-option=option:domain-name,"$Ldap_Domain_Name"

# Définir le masque de sous-réseau
dhcp-option=option:netmask,$Ip_Mask
EOF
        systemctl restart dnsmasq.service
    else
        echo -e "\e[32mDnsMasq file: Line is already present\e[0m"
    fi
}

# Configure LDAP by creating the different necessary ldif files and executing them + sets the passwords for each account
function ConfigureLdap {
    echo -e "\e[33mLDAP file: Setting base and uri\e[0m"
    sed -i 's/#BASE\s*dc=example,dc=com/BASE dc=lin1,dc=local/g' $File_Ldap
    sed -i 's|#URI\s*ldap://ldap\.example\.com\s*ldap://ldap-provider\.example\.com:666|URI ldap://SRV-LIN1-01.lin1.local|g' $File_Ldap
    
    echo -e "\e[33mLDAP Organizational unit file: Creating Organizational unit file\e[0m"
    cat <<EOF >$File_Ldap_Ou
dn: $Ldap_Users_Controller
objectClass: organizationalUnit
ou: Users

dn: $Ldap_Groups_Controller
objectClass: organizationalUnit
ou: Groups
EOF

    echo -e "\e[33mLDAP groups file: Creating groups file\e[0m"
    cat <<EOF >$File_Ldap_Groups
dn: cn=Managers,$Ldap_Groups_Controller
objectClass: top
objectClass: posixGroup
gidNumber: 20000

dn: cn=Ingenieurs,$Ldap_Groups_Controller
objectClass: top
objectClass: posixGroup
gidNumber: 20010

dn: cn=Developpeurs,$Ldap_Groups_Controller
objectClass: top
objectClass: posixGroup
gidNumber: 20020
EOF

    echo -e "\e[33mLDAP users file: Creating users file\e[0m"
    cat <<EOF >$File_Ldap_Users
dn: uid=man1,$Ldap_Users_Controller
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: person
uid: man1
userPassword: {crypt}x
cn: Man 1
givenName: Man
sn: 1
loginShell: /bin/bash
uidNumber: 10000
gidNumber: 20000
displayName: Man 1
homeDirectory: /mnt/Share/Perso/man1
mail: man1@$Ldap_Domain_Name
description: Man 1 account

dn: uid=man2,$Ldap_Users_Controller
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: person
uid: man2
userPassword: {crypt}x
cn: Man 2
givenName: Man
sn: 2
loginShell: /bin/bash
uidNumber: 10001
gidNumber: 20000
displayName: Man 2
homeDirectory: /mnt/Share/Perso/man2
mail: man2@$Ldap_Domain_Name
description: Man 2 account

dn: uid=ing1,$Ldap_Users_Controller
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: person
uid: ing1
userPassword: {crypt}x
cn: Ing 1
givenName: Ing
sn: 1
loginShell: /bin/bash
uidNumber: 10010
gidNumber: 20010
displayName: Ing 1
homeDirectory: /mnt/Share/Perso/ing1
mail: ing1@$Ldap_Domain_Name
description: Ing 1 account

dn: uid=ing2,$Ldap_Users_Controller
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: person
uid: ing2
userPassword: {crypt}x
cn: Ing 2
givenName: Ing
sn: 2
loginShell: /bin/bash
uidNumber: 10011
gidNumber: 20010
displayName: Ing 2
homeDirectory: /mnt/Share/Perso/ing2
mail: ing2@$Ldap_Domain_Name
description: Ing 2 account

dn: uid=dev1,$Ldap_Users_Controller
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
objectClass: person
uid: dev1
userPassword: {crypt}x
cn: Dev 1
givenName: Dev
sn: 1
loginShell: /bin/bash
uidNumber: 10020
gidNumber: 20020
displayName: Dev 1
homeDirectory: /mnt/Share/Perso/dev1
mail: dev1@$Ldap_Domain_Name
description: Dev 1 account
EOF

    echo -e "\e[33mLDAP admin file: Creating admin file\e[0m"
    cat <<EOF > $File_Ldap_Admin
dn: cn=admin,$Ldap_Domain_Controller
changetype: modify
replace: userPassword
userPassword: $Ldap_Admin_Password
EOF

    echo -e "\e[33mLDAP files: Applying configuration files\e[0m" 
    ldapadd -x -D "cn=admin,$Ldap_Domain_Controller" -w $Ldap_Admin_Password -f $File_Ldap_Ou >/dev/null 2>&1 
    ldapadd -x -D "cn=admin,$Ldap_Domain_Controller" -w $Ldap_Admin_Password -f $File_Ldap_Groups >/dev/null 2>&1 
    ldapadd -x -D "cn=admin,$Ldap_Domain_Controller" -w $Ldap_Admin_Password -f $File_Ldap_Users >/dev/null 2>&1 

    echo -e "\e[33mLDAP users: Applying new passwords\e[0m"
    ldappasswd -s "man1password" -D "cn=admin,$Ldap_Domain_Controller" -x uid=man1,$Ldap_Users_Controller -w $Ldap_Admin_Password >/dev/null 2>&1 
    ldappasswd -s "man2password" -D "cn=admin,$Ldap_Domain_Controller" -x uid=man2,$Ldap_Users_Controller -w $Ldap_Admin_Password >/dev/null 2>&1 
    ldappasswd -s "ing1password" -D "cn=admin,$Ldap_Domain_Controller" -x uid=ing1,$Ldap_Users_Controller -w $Ldap_Admin_Password >/dev/null 2>&1 
    ldappasswd -s "ing2password" -D "cn=admin,$Ldap_Domain_Controller" -x uid=ing2,$Ldap_Users_Controller -w $Ldap_Admin_Password >/dev/null 2>&1 
    ldappasswd -s "dev1password" -D "cn=admin,$Ldap_Domain_Controller" -x uid=dev1,$Ldap_Users_Controller -w $Ldap_Admin_Password >/dev/null 2>&1 
    
    # Modify the admin user's password
    ldapmodify -x -D "cn=admin,$Ldap_Domain_Controller" -w $Ldap_Admin_Password -f $File_Ldap_Admin  >/dev/null 2>&1 
    
    # Deleting the .ldif files
    rm $File_Ldap_Ou
    rm $File_Ldap_Groups
    rm $File_Ldap_Users
    rm $File_Ldap_Admin
}

#endregion 

#region Main

# Update package list
apt-get update >/dev/null 2>&1

# Packages installations
echo -e "\e[36m===Packages installations===\e[0m"
InstallIfNeeded net-tools
InstallIfNeeded iptables
InstallIfNeededIptablesPersistent
InstallIfNeeded dnsmasq
InstallIfNeeded apache2
InstallIfNeeded php 
InstallIfNeeded php-ldap
InstallIfNeeded php-gd
InstallIfNeeded php-imagick
InstallIfNeeded php-curl
InstallIfNeeded php-zip
InstallIfNeeded php-xml
InstallIfNeeded php-gmp
InstallIfNeeded php-mbstring
InstallIfNeeded gettext
InstallIfNeeded fonts-dejavu
InstallIfNeeded ckeditor
InstallIfNeeded libjs-jquery-jstree
InstallIfNeeded slapd 
InstallIfNeeded ldap-utils
InstallIfNeeded ldap-account-manager
InstallIfNeeded debconf
echo ""

# Configurations
echo -e "\e[36m===Hostname Configuration===\e[0m"
ConfigureHostname
echo ""

echo -e "\e[36m===Routing Configuration===\e[0m"
ConfigureRouting
echo ""

echo -e "\e[36m===DNS Configuration===\e[0m"
ConfigureDns
echo ""

echo -e "\e[36m===DHCP Configuration===\e[0m"
ConfigureDhcp
echo ""

echo -e "\e[36m===LDAP Configuration===\e[0m"
ConfigureLdap
echo ""

#endregion