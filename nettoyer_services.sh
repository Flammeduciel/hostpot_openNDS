#!/bin/bash

# ============================================================
# SCRIPT DE NETTOYAGE - SUPPRIME LES ANCIENNES CONFIGURATIONS
# À exécuter avant une nouvelle installation de hotspot
# ============================================================

echo "======================================================"
echo "   NETTOYAGE DES ANCIENNES CONFIGURATIONS HOTSPOT"
echo "======================================================"

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "ERREUR : Ce script doit être lancé avec sudo."
  exit 1
fi

echo ""
echo "Arrêt des services potentiellement conflictuels..."
echo ""

# Arrêter tous les services liés au hotspot
services_to_stop=(
    "hostapd"
    "dnsmasq"
    "opennds"
    "isc-dhcp-server"
    "isc-dhcp-server6"
    "udhcpd"
    "bind9"
    "named"
    "apache2"
    "nginx"
    "lighttpd"
)

for service in "${services_to_stop[@]}"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "  [ARRÊT] $service"
        systemctl stop "$service" 2>/dev/null
    fi
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "  [DESACTIVE] $service"
        systemctl disable "$service" 2>/dev/null
    fi
done

echo ""
echo "Suppression des fichiers de configuration..."
echo ""

# Supprimer les configurations hostapd
if [ -f /etc/hostapd/hostapd.conf ]; then
    echo "  [SUPPRIME] /etc/hostapd/hostapd.conf"
    rm -f /etc/hostapd/hostapd.conf
fi

# Supprimer les configurations dnsmasq
if [ -f /etc/dnsmasq.conf ]; then
    echo "  [SUPPRIME] /etc/dnsmasq.conf"
    rm -f /etc/dnsmasq.conf
fi

# Supprimer les configurations opennds
if [ -f /etc/opennds/opennds.conf ]; then
    echo "  [SUPPRIME] /etc/opennds/opennds.conf"
    rm -f /etc/opennds/opennds.conf
fi

# Supprimer les pages web du portail
if [ -f /var/www/html/mon_portail.php ]; then
    echo "  [SUPPRIME] /var/www/html/mon_portail.php"
    rm -f /var/www/html/mon_portail.php
fi

# Nettoyer les règles iptables
echo ""
echo "Nettoyage des règles iptables..."
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
echo "  [OK] Règles iptables réinitialisées"

# Sauvegarder les règles nettoyées
netfilter-persistent save 2>/dev/null
echo "  [OK] Règles sauvegardées"

# Nettoyer la configuration dhcpcd.conf
echo ""
echo "Nettoyage de /etc/dhcpcd.conf..."
# Supprimer les anciennes configurations hotspot (lignes avec static ip_address)
sed -i '/# --- Configuration hotspot/,/^$/d' /etc/dhcpcd.conf
echo "  [OK] Anciennes config IP statique supprimées"

# Désactiver le routage IP
sed -i 's/net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf
echo "  [OK] IP forward désactivé"

# Supprimer les interfaces virtuelles hostapd
echo ""
echo "Nettoyage des interfaces Wi-Fi virtuelles..."
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlan[0-9]+mon$'); do
    echo "  [SUPPRIME] interface $iface"
    ip link delete "$iface" 2>/dev/null
done

# Redémarrer les services réseau
echo ""
echo "Redémarrage des services réseau..."
systemctl restart dhcpcd 2>/dev/null
systemctl restart networking 2>/dev/null

echo ""
echo "======================================================"
echo "   NETTOYAGE TERMINÉ"
echo "======================================================"
echo ""
echo "Vous pouvez maintenant installer votre nouveau hotspot."
echo "Conseil : Redémarrez le système pour être sûr que tout est propre."
echo ""
read -p "Voulez-vous redémarrer maintenant ? (o/n) : " confirm
case $confirm in
    [oO]|[oO][uU][iI])
        echo "Redémarrage..."
        reboot
        ;;
    *)
        echo "Redémarrage annulé. Faites 'sudo reboot' plus tard."
        ;;
esac
