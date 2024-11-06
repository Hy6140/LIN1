#!/usr/bin/bash
# ==============================================================================================================
# Title         -   SRV02_LIN1_SCRIPT-02.sh
# Author        -   Nuno Ribeiro Pereira (nuno.ribeiro@eduvaud.ch)
# Creation      -   11.11.24
# Last Update   -   01.11.24 by Nuno Ribeiro Pereira
#
# Description   -   This script automates the installation and configuration of a dns, dhcp, routage and ldap.
#                   All the packages necessary are installed by the script.
#                   
# Prerequisites -   Debian with a compatible version
#                   Admin privilieges
#                   One Host-Only interface
#
# Valid Systems -   Debian 12.6.4 | Debian 11.2.0
# Version       -   V1.0
# ==============================================================================================================

#region variables
File_NetworkInterfaces="/etc/network/interfaces" 
File_Resolv="/etc/resolv.conf"

Ip_SRV2="10.10.10.22"
Ip_Gateway="10.10.10.11"
Ip_DNS1="10.10.10.11"

Int_HostOnly="ens33"

Ldap_Domain_Name="lin1.local"

Hostname_SRV2="SRV-LIN1-02"
#endregion

#region Functions

# Configure the hostname
function ConfigureHostname {
    current_hostname=$(hostnamectl status --static)
    
    if [ "$current_hostname" != "$Hostname_SRV2.$Ldap_Domain_Name" ]; then
        echo -e "\e[33mConfiguring hostname\e[0m"
        hostnamectl set-hostname $Hostname_SRV2.$Ldap_Domain_Name
    else
        echo -e "\e[32mHostname already set to $Hostname_SRV2.$Ldap_Domain_Name\e[0m"
    fi
}

# Configure the DNS
function ConfigureDns {
    if ! grep -q "nameserver $Ip_DNS1" $File_Resolv; then
        echo -e "\e[33mConfiguring DNS\e[0m"
        cat <<EOF > $File_Resolv
domain $Ldap_Domain_Name
search $Ldap_Domain_Name
nameserver $Ip_DNS1
EOF
    else
        echo -e "\e[32mDNS already configured\e[0m"
    fi
}

# Configure network interfaces
function ConfigureNetworkInterface {
    echo -e "\e[33mInterfaces file: Configuring network interface\e[0m"
    cat <<EOF > $File_NetworkInterfaces
# The loopback network interface
auto lo
iface lo inet loopback

# Interface $Int_HostOnly (Host-Only)
auto $Int_HostOnly
allow-hotplug $Int_HostOnly
iface $Int_HostOnly inet static
address $Ip_SRV2/24
gateway $Ip_Gateway
EOF
    echo -e "\e[32mInterfaces file: Interface configured ( IP -> $Ip_SRV2 ), ssh session will be disconnected\e[0m"
    systemctl restart networking.service
}

#endregion

#region Main

# Configurations
echo -e "\e[36m===Configuring Hostname===\e[0m"
ConfigureHostname
echo ""

echo -e "\e[36m===Configuring DNS===\e[0m"
ConfigureDns
echo ""

echo -e "\e[36m===Configuring Network Interface===\e[0m"
ConfigureNetworkInterface
echo ""

#endregion
