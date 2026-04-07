#!/bin/bash

# ============================================================
# SCRIPT V3 : HOTSPOT + OPENNDS + IPTABLES - VERSION CORRIGÉE
# Auteur   : Script original V2 corrigé et documenté
# But      : Transformer un Raspberry Pi (ou équivalent Linux)
#            en hotspot Wi-Fi avec portail captif (voucher)
#
# CORRECTIONS APPORTÉES PAR RAPPORT À LA V2 :
#   [FIX 1]  Détection automatique des interfaces réseau
#            (plus de noms codés en dur wlan0/eth0)
#   [FIX 2]  Commande "unmask" corrigée (systemctl unmask)
#            et "disable" remplacé par "enable"
#   [FIX 3]  Variable PASS initialisée avant la boucle while
#   [FIX 4]  Règles IPTables nettoyées : suppression des
#            règles redondantes HTTP/HTTPS (la règle TCP
#            générique les couvre déjà)
#   [FIX 5]  Port SSH (22) exclu de la redirection TCP
#            pour ne pas couper l'administration distante
#   [FIX 6]  Ports 67/68 (DHCP = UDP) retirés de la règle
#            TCP car ils n'ont aucun effet sur une règle TCP
#   [FIX 7]  Chaîne INPUT sécurisée : le Pi n'accepte plus
#            toutes les connexions entrantes depuis le Wi-Fi
# ============================================================


# ============================================================
# VÉRIFICATION : Le script doit être lancé en root (sudo)
# Sans les droits root, aucune des commandes système
# (apt, iptables, systemctl...) ne fonctionnera.
# ============================================================
if [ "$EUID" -ne 0 ]; then
  echo "ERREUR : Ce script doit être lancé avec sudo."
  echo "  --> sudo ./install_opennds_v3.sh"
  exit 1
fi


echo "======================================================"
echo "   Installation Hotspot + OpenNDS + IPTABLES  V3     "
echo "======================================================"


# ============================================================
# [FIX 1] DÉTECTION AUTOMATIQUE DES INTERFACES RÉSEAU
# ============================================================
# Sur les systèmes Linux modernes, les interfaces ne
# s'appellent plus forcément "wlan0" et "eth0".
# Le nommage prévisible peut donner "wlp2s0", "enp3s0", etc.
#
# On détecte automatiquement :
#   - L'interface Wi-Fi  : la première interface dont le nom
#     commence par "wl" (wlan, wlp, wlx...)
#   - L'interface filaire : la première interface dont le nom
#     commence par "e" (eth, enp, ens...)
#
# "ip -o link show" liste toutes les interfaces.
# "awk" filtre et extrait le nom (2ème champ, on retire le ':').
# "grep" filtre par préfixe de nom.
# "head -1" garde uniquement la première trouvée.
# ============================================================

WIFI_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wl' | head -1)
ETH_IF=$(ip -o link show  | awk -F': ' '{print $2}' | grep '^e'  | head -1)

# Si aucune interface n'est trouvée, on arrête tout.
# Mieux vaut planter ici que de créer des règles incorrectes.
if [ -z "$WIFI_IF" ]; then
  echo "ERREUR CRITIQUE : Aucune interface Wi-Fi détectée (préfixe 'wl')."
  echo "Vérifiez que votre adaptateur Wi-Fi est bien reconnu par le système."
  exit 1
fi

if [ -z "$ETH_IF" ]; then
  echo "ERREUR CRITIQUE : Aucune interface filaire détectée (préfixe 'e')."
  echo "Vérifiez que votre câble Ethernet est branché et l'interface active."
  exit 1
fi

# On informe l'utilisateur des interfaces qui seront utilisées.
echo ""
echo "  Interface Wi-Fi   détectée : $WIFI_IF"
echo "  Interface filaire détectée : $ETH_IF"
echo ""


# ============================================================
# ÉTAPE 1/8 — INSTALLATION DES PAQUETS
# ============================================================
# On met d'abord à jour la liste des paquets disponibles
# puis on installe tous les outils nécessaires :
#
#   hostapd          : Daemon qui transforme la carte Wi-Fi
#                      en point d'accès (Access Point)
#   dnsmasq          : Serveur DHCP (attribue les IPs aux
#                      clients) + DNS local
#   opennds          : Gestionnaire de portail captif
#   apache2          : Serveur web qui héberge la page PHP
#   php php-curl     : Langage de la page du portail
#   iptables-persistent : Permet de sauvegarder les règles
#                      iptables pour qu'elles survivent
#                      aux redémarrages
# ============================================================
echo "[1/8] Mise à jour et installation des paquets..."
# apt-get update && apt-get upgrade -y
apt-get install -y \
  hostapd \
  dnsmasq \
  opennds \
  apache2 \
  php \
  php-curl \
  iptables-persistent


# ============================================================
# ÉTAPE 2/8 — CONFIGURATION IP STATIQUE SUR L'INTERFACE WI-FI
# ============================================================
# Le Pi doit avoir une IP fixe sur son interface Wi-Fi
# pour que les clients puissent le joindre de façon stable.
#
# On utilise 192.168.50.1/24, ce qui signifie :
#   - IP du Pi (passerelle) : 192.168.50.1
#   - Plage réseau disponible : 192.168.50.0 à 192.168.50.255
#
# "sed -i" supprime d'abord toute configuration précédente
# pour $WIFI_IF dans /etc/dhcpcd.conf afin d'éviter
# les doublons en cas de ré-exécution du script.
#
# "nohook wpa_supplicant" empêche dhcpcd d'interférer
# avec la configuration Wi-Fi gérée par hostapd.
# ============================================================
echo "[2/8] Configuration IP statique sur $WIFI_IF..."

# Suppression propre de l'ancienne config si elle existe
sed -i "/^interface $WIFI_IF/,/^$/d" /etc/dhcpcd.conf

# Ajout de la nouvelle configuration statique
cat >> /etc/dhcpcd.conf <<EOF

# --- Configuration hotspot pour $WIFI_IF ---
interface $WIFI_IF
    static ip_address=192.168.50.1/24
    nohook wpa_supplicant
EOF

# On redémarre l'interface pour appliquer immédiatement.
# NOTE : On le fait ICI et pas avant la config hostapd,
# sinon l'interface monte sans configuration valide.
ip link set "$WIFI_IF" down
ip link set "$WIFI_IF" up


# ============================================================
# ÉTAPE 3/8 — SAISIE INTERACTIVE DES PARAMÈTRES UTILISATEUR
# ============================================================
echo ""
echo "======================================================"
echo "  Paramètres du Hotspot"
echo "======================================================"

# Lecture du SSID (nom visible du réseau Wi-Fi)
read -p "Nom du Hotspot (SSID) : " SSID

# Demande si le réseau doit avoir un mot de passe
read -p "Protéger avec un mot de passe ? (o/n) : " HAS_PASS

# [FIX 3] Initialisation explicite de PASS avant la boucle.
# Sans cette ligne, si le shell est strict (set -u),
# la variable non définie provoquerait une erreur.
PASS=""

if [ "$HAS_PASS" = "o" ] || [ "$HAS_PASS" = "O" ]; then
    # Boucle jusqu'à obtenir un mot de passe d'au moins 8 caractères.
    # WPA2 exige un minimum de 8 caractères. En dessous, hostapd
    # refusera de démarrer.
    while [ ${#PASS} -lt 8 ]; do
        read -sp "Mot de passe (minimum 8 caractères) : " PASS
        echo  # Saut de ligne après la saisie masquée
        if [ ${#PASS} -lt 8 ]; then
            echo "  --> Trop court ! Il faut au moins 8 caractères."
        fi
    done
    # Mode sécurité WPA2 (valeur 2 pour hostapd)
    SECURITY=2
else
    # Réseau ouvert, sans authentification Wi-Fi
    SECURITY=0
    PASS=""
fi

# Génération d'une clé secrète aléatoire pour le protocole FAS.
# FAS (Forward Authentication Service) est le mécanisme
# utilisé par OpenNDS pour sécuriser l'échange avec la
# page PHP. Cette clé doit rester secrète.
# "openssl rand -hex 16" génère 16 octets aléatoires
# encodés en hexadécimal (32 caractères au total).
FAS_KEY=$(openssl rand -hex 16)


# ============================================================
# ÉTAPE 4/8 — CONFIGURATION DE HOSTAPD (POINT D'ACCÈS WI-FI)
# ============================================================
# hostapd gère la couche radio Wi-Fi.
# Il transforme la carte Wi-Fi en Access Point auquel
# les clients vont se connecter.
#
# Paramètres notables :
#   hw_mode=g      : 802.11g (2.4 GHz, compatible avec tout)
#   channel=6      : Canal 6 (bon choix par défaut, peu
#                    encombré dans la plupart des bureaux)
#   ieee80211n=1   : Active le mode 802.11n (Wi-Fi 4)
#                    pour de meilleures performances
#   wmm_enabled=1  : Wi-Fi Multimedia, requis par 802.11n
#   macaddr_acl=0  : Pas de filtrage par adresse MAC
#   auth_algs=1    : Authentification ouverte (requise pour WPA)
#   ignore_broadcast_ssid=0 : SSID visible (non masqué)
# ============================================================
echo "[4/8] Configuration Hostapd..."
cat > /etc/hostapd/hostapd.conf <<EOF
# Interface Wi-Fi à utiliser comme Access Point
interface=$WIFI_IF

# Driver nl80211 : driver générique Linux pour le Wi-Fi
driver=nl80211

# Nom du réseau Wi-Fi (SSID)
ssid=$SSID

# Mode radio : g = 802.11g (2.4 GHz)
hw_mode=g

# Canal radio (1, 6 ou 11 sont les canaux non chevauchants)
channel=6

# Activation du Wi-Fi N (meilleur débit)
ieee80211n=1
wmm_enabled=1
ht_capab=[HT40][SHORT-GI-20][DSSS_CCK-40]

# Contrôle d'accès MAC : 0 = tout le monde peut se connecter
macaddr_acl=0

# Type d'authentification : 1 = Open System (requis pour WPA2)
auth_algs=1

# SSID visible dans la liste des réseaux
ignore_broadcast_ssid=0
EOF

# Ajout conditionnel de la section WPA2 si un mot de passe est défini
if [ "$SECURITY" -eq 2 ]; then
    cat >> /etc/hostapd/hostapd.conf <<EOF

# --- Sécurité WPA2 ---
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
EOF
fi

# Indique à hostapd où trouver son fichier de configuration.
# Par défaut la ligne est commentée, on la décommente.
sed -i 's|#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

# [FIX 2] Correction de la V2 :
#   - "unmask" était appelé sans "systemctl" → commande invalide
#   - "disable" après "unmask" était contradictoire
#
# Sur certaines distributions, hostapd est "masqué" par défaut
# (masquage systemd = impossible à démarrer).
# "systemctl unmask" le rend à nouveau utilisable.
# "systemctl enable" l'active au démarrage automatiquement.
systemctl unmask hostapd
systemctl enable hostapd


# ============================================================
# ÉTAPE 5/8 — CONFIGURATION DNSMASQ (DHCP + DNS)
# ============================================================
# dnsmasq remplit deux rôles ici :
#   1. SERVEUR DHCP : Attribue automatiquement une adresse IP
#      à chaque client Wi-Fi qui se connecte.
#   2. SERVEUR DNS  : Résout les noms de domaine pour les
#      clients (en forwardant vers 8.8.8.8).
#
# dhcp-range : Plage d'IPs distribuées aux clients
#              (de .50 à .150), bail de 12 heures
# dhcp-option=3 : Indique aux clients que la passerelle
#                 par défaut est le Pi (192.168.50.1)
# dhcp-option=6 : Indique aux clients que le DNS
#                 est aussi le Pi
# server=8.8.8.8 : dnsmasq redirige les requêtes DNS
#                  vers le DNS de Google
# ============================================================
echo "[5/8] Configuration DHCP (dnsmasq)..."

# Sauvegarde de la configuration originale avant écrasement
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig

cat > /etc/dnsmasq.conf <<EOF
# Interface sur laquelle écouter (uniquement le Wi-Fi)
interface=$WIFI_IF

# Plage DHCP : attribue des IPs de .50 à .150, bail 12h
dhcp-range=192.168.50.50,192.168.50.150,12h

# Option 3 = route par défaut (passerelle) → le Pi
dhcp-option=3,192.168.50.1

# Option 6 = serveur DNS → le Pi
dhcp-option=6,192.168.50.1

# Le Pi forward les requêtes DNS vers Google
server=8.8.8.8

# Journalisation pour débogage
log-queries
log-dhcp
EOF


# ============================================================
# ÉTAPE 6/8 — CONFIGURATION IPTABLES (CŒUR DU SYSTÈME)
# ============================================================
# IPTables est le pare-feu Linux. On l'utilise pour :
#   A. Partager la connexion internet du Pi avec les clients
#   B. Intercepter TOUT le trafic des clients non-authentifiés
#      et le rediriger vers le portail captif
#   C. Sécuriser le Pi lui-même (chaîne INPUT)
# ============================================================
echo "[6/8] Configuration avancée IPTables..."

# --- Activation du routage IP ---
# Par défaut, Linux ne route pas les paquets entre interfaces.
# On doit activer ip_forward pour que les clients puissent
# accéder à internet via le Pi (qui fait office de routeur).
# La modification dans sysctl.conf rend ça persistant
# au redémarrage.
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p   # Application immédiate sans redémarrer


# --- Nettoyage complet des règles existantes ---
# Indispensable pour repartir d'une base propre et éviter
# les conflits ou doublons si le script est ré-exécuté.
iptables -F              # Vide toutes les chaînes en filter
iptables -t nat -F       # Vide toutes les chaînes en nat
iptables -t mangle -F    # Vide toutes les chaînes en mangle
iptables -X              # Supprime les chaînes personnalisées


# ==========================================================
# A. RÈGLES NAT — PARTAGE DE CONNEXION INTERNET
# ==========================================================
# MASQUERADE : Quand un paquet client sort vers internet
# via $ETH_IF, le Pi remplace l'IP source du client
# par sa propre IP publique (comme une box internet).
# C'est le NAT classique.
iptables -t nat -A POSTROUTING -o "$ETH_IF" -j MASQUERADE

# FORWARD : Autorise les paquets à transiter entre les interfaces.
# Règle 1 : Autorise les réponses venant d'internet (ESTABLISHED/RELATED)
#           à revenir vers les clients Wi-Fi.
iptables -A FORWARD -i "$ETH_IF" -o "$WIFI_IF" \
  -m state --state RELATED,ESTABLISHED -j ACCEPT

# Règle 2 : Autorise les clients Wi-Fi à envoyer des paquets vers internet.
iptables -A FORWARD -i "$WIFI_IF" -o "$ETH_IF" -j ACCEPT


# ==========================================================
# B. RÈGLES INPUT — SÉCURISATION DU PI LUI-MÊME
# ==========================================================
# [FIX 7] La V2 n'avait AUCUNE règle INPUT.
# Cela signifiait que le Pi acceptait toutes les connexions
# entrantes depuis les clients Wi-Fi, y compris sur des ports
# sensibles (SSH, bases de données, etc.)
#
# On définit une politique par défaut et on n'autorise
# que ce qui est nécessaire :
#   - Connexions déjà établies (réponses au Pi lui-même)
#   - SSH sur l'interface filaire uniquement (administration)
#   - DNS (53) : pour répondre aux requêtes DNS des clients
#   - DHCP (67 UDP) : pour distribuer les IPs
#   - HTTP (80) : pour servir la page du portail
#   - Port 2050 : API d'authentification OpenNDS
# ==========================================================

# Politique par défaut : on refuse tout ce qui n'est pas explicitement autorisé
iptables -P INPUT DROP

# On autorise le loopback (interface interne lo) — toujours nécessaire
iptables -A INPUT -i lo -j ACCEPT

# On autorise les connexions déjà établies ou liées à des connexions sortantes
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH : uniquement depuis l'interface filaire (administration sécurisée)
# JAMAIS depuis le Wi-Fi pour éviter les risques si un client malveillant
# essaie de se connecter au Pi.
iptables -A INPUT -i "$ETH_IF" -p tcp --dport 22 -j ACCEPT

# DNS : les clients Wi-Fi envoient leurs requêtes DNS au Pi (dnsmasq)
iptables -A INPUT -i "$WIFI_IF" -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i "$WIFI_IF" -p tcp --dport 53 -j ACCEPT

# DHCP : les clients demandent une IP au démarrage (broadcast UDP)
iptables -A INPUT -i "$WIFI_IF" -p udp --dport 67 -j ACCEPT

# HTTP : la page du portail est servie par Apache sur le port 80
iptables -A INPUT -i "$WIFI_IF" -p tcp --dport 80 -j ACCEPT

# OpenNDS : le port 2050 est utilisé par OpenNDS pour valider
# l'authentification des clients depuis la page PHP
iptables -A INPUT -i "$WIFI_IF" -p tcp --dport 2050 -j ACCEPT


# ==========================================================
# C. RÈGLES PREROUTING — REDIRECTION VERS LE PORTAIL CAPTIF
# ==========================================================
# PREROUTING intercepte les paquets AVANT qu'ils soient
# routés. Cela permet de rediriger le trafic des clients
# non-authentifiés vers le portail local, même si
# le client essaie de joindre google.com ou autre.
#
# [FIX 4] La V2 avait 3 règles distinctes (HTTP, HTTPS,
# puis TCP générique). La règle générique couvrant déjà
# HTTP et HTTPS, les deux premières étaient du code mort.
# On garde uniquement la règle générique, propre et lisible.
#
# [FIX 5] On exclut le port 22 (SSH) — absent de la V2 —
# pour ne pas rediriger les connexions SSH depuis le Wi-Fi
# (certes bloquées en INPUT, mais mieux vaut être cohérent).
#
# [FIX 6] On retire les ports 67 et 68 de la liste des
# exceptions : ce sont des ports UDP, ils n'ont aucun effet
# dans une règle "-p tcp". Ça évitait de donner une fausse
# impression de protection.
#
# Ports exclus de la redirection :
#   2050 : Port d'authentification OpenNDS (OBLIGATOIRE,
#          sinon l'auth tourne en boucle infinie)
#   22   : SSH (administration distante)
# ==========================================================

# Redirection de TOUT le trafic TCP des clients Wi-Fi
# vers le Pi (192.168.50.1), SAUF les ports critiques.
# Le portail PHP et OpenNDS s'occupent ensuite de laisser
# passer les clients qui ont un voucher valide.
iptables -t nat -A PREROUTING \
  -i "$WIFI_IF" \
  -p tcp \
  -m multiport ! --dports 2050,22 \
  -j DNAT --to-destination 192.168.50.1

# Note : La redirection HTTPS (443) provoquera une erreur
# de certificat SSL dans le navigateur client car le Pi
# ne possède pas de certificat valide pour les domaines
# demandés. C'est un comportement attendu et connu
# des portails captifs : les navigateurs modernes gèrent
# cela en proposant quand même d'accéder à la page.


# --- Sauvegarde des règles IPTables ---
# Sans cette commande, toutes les règles disparaissent
# au prochain redémarrage.
# iptables-persistent les sauvegarde dans :
#   /etc/iptables/rules.v4 (IPv4)
#   /etc/iptables/rules.v6 (IPv6)
netfilter-persistent save


# ============================================================
# ÉTAPE 7/8 — CONFIGURATION D'OPENNDS
# ============================================================
# OpenNDS est le daemon qui gère le portail captif :
#   - Il maintient la liste des clients authentifiés
#   - Il crée ses propres règles iptables pour laisser
#     passer les clients validés
#   - Il communique avec la page PHP via le protocole FAS
#
# FAS (Forward Authentication Service) :
#   fas_enabled  : Active le mode FAS (délègue l'auth à PHP)
#   fas_path     : Chemin vers la page PHP du portail
#   fas_url      : URL de base du serveur web (le Pi)
#   fas_key      : Clé secrète partagée entre OpenNDS et PHP
#                  pour sécuriser les échanges
# ============================================================
echo "[7/8] Configuration OpenNDS..."

# Sauvegarde de la configuration originale
cp /etc/opennds/opennds.conf /etc/opennds/opennds.conf.bak

# Suppression des directives qu'on va réécrire
# (évite les doublons en cas de ré-exécution)
sed -i '/^GatewayInterface/d' /etc/opennds/opennds.conf
sed -i '/^GatewayName/d'      /etc/opennds/opennds.conf
sed -i '/^fas_enabled/d'      /etc/opennds/opennds.conf
sed -i '/^fas_path/d'         /etc/opennds/opennds.conf
sed -i '/^fas_url/d'          /etc/opennds/opennds.conf
sed -i '/^fas_key/d'          /etc/opennds/opennds.conf

# Ajout de la configuration FAS
cat >> /etc/opennds/opennds.conf <<EOF

# --- Configuration Portail Captif ---

# Interface Wi-Fi gérée par OpenNDS
GatewayInterface $WIFI_IF

# Nom affiché du portail
GatewayName Portail_Securise

# Activation du mode FAS (délègue l'authentification à la page PHP)
fas_enabled enabled

# Chemin relatif vers la page PHP du portail
fas_path /mon_portail.php

# URL du serveur web hébergeant la page
fas_url http://192.168.50.1

# Clé secrète FAS (générée aléatoirement à chaque installation)
fas_key $FAS_KEY
EOF


# ============================================================
# ÉTAPE 8/8 — CRÉATION DE LA PAGE PHP DU PORTAIL
# ============================================================
# Cette page est ce que voit l'utilisateur quand il
# se connecte au Wi-Fi et ouvre son navigateur.
# Elle demande un code voucher et, si valide, appelle
# l'API OpenNDS pour autoriser le client.
#
# Vouchers disponibles (modifiables dans le tableau $vouchers) :
#   1H   : 60 minutes d'accès
#   30M  : 30 minutes d'accès
#   ADMIN: 24 heures d'accès
# ============================================================
echo "[8/8] Création de la page PHP du portail..."

cat << 'PHPEOF' > /var/www/html/mon_portail.php
<?php
// ============================================================
// PORTAIL CAPTIF — Page d'authentification par voucher
// ============================================================

// Adresse IP du Pi (passerelle)
$gateway_address = "192.168.50.1";

// Clé FAS : sera remplacée par le script bash via sed
// Elle doit correspondre à "fas_key" dans opennds.conf
$fas_key = "###FAS_KEY###";

// Tableau des codes voucher valides
// Clé = code saisi par l'utilisateur
// Valeur = durée d'accès EN MINUTES
$vouchers = [
    "1H"    => 60,    // 1 heure
    "30M"   => 30,    // 30 minutes
    "ADMIN" => 1440,  // 24 heures (usage administrateur)
];

// Récupération des paramètres envoyés par OpenNDS dans l'URL
// OpenNDS les passe automatiquement lors de la redirection vers le portail
$client_ip  = $_GET['clientip']  ?? '';   // IP du client Wi-Fi
$client_mac = $_GET['clientmac'] ?? '';   // Adresse MAC du client
$redir      = $_GET['redir']     ?? '';   // URL vers laquelle rediriger après auth
$tok        = $_GET['tok']       ?? '';   // Token de session OpenNDS

$msg = "";  // Message d'erreur à afficher à l'utilisateur

// Traitement du formulaire quand l'utilisateur clique sur "Connecter"
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $code = strtoupper(trim($_POST['voucher'] ?? ''));  // On normalise en majuscules

    if (array_key_exists($code, $vouchers)) {
        // Code valide : on calcule la durée en secondes
        $duration = $vouchers[$code] * 60;

        // Construction de l'URL d'authentification OpenNDS
        // OpenNDS écoute sur le port 2050 et attend ces paramètres
        $auth_url = "http://" . $gateway_address . ":2050/opennds_auth/";

        $params = [
            'tok'       => $tok,
            'redir'     => $redir,
            'clientip'  => $client_ip,
            'clientmac' => $client_mac,
            'duration'  => $duration,
            'fas_key'   => $fas_key,
        ];

        // Redirection vers OpenNDS qui va débloquer le client
        header("Location: " . $auth_url . "?" . http_build_query($params));
        exit;

    } else {
        // Code inconnu
        $msg = "Code invalide. Veuillez réessayer.";
    }
}
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Accès Wi-Fi</title>
    <style>
        body {
            font-family: sans-serif;
            background: #f4f4f9;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
        }
        .box {
            background: white;
            padding: 30px;
            border-radius: 8px;
            text-align: center;
            width: 300px;
            box-shadow: 0 4px 10px rgba(0,0,0,0.1);
        }
        input {
            width: 100%;
            padding: 10px;
            margin: 10px 0;
            box-sizing: border-box;
            border: 1px solid #ccc;
            border-radius: 4px;
        }
        button {
            width: 100%;
            padding: 10px;
            background: #007bff;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 1em;
        }
        button:hover { background: #0056b3; }
        .error { color: red; font-size: 0.9em; }
    </style>
</head>
<body>
    <div class="box">
        <h2>Accès Wi-Fi</h2>
        <p>Entrez votre code pour vous connecter.</p>

        <?php if ($msg): ?>
            <p class="error"><?= htmlspecialchars($msg) ?></p>
        <?php endif; ?>

        <form method="POST" action="">
            <!-- Champs cachés pour conserver les paramètres OpenNDS -->
            <input type="hidden" name="clientip"  value="<?= htmlspecialchars($client_ip) ?>">
            <input type="hidden" name="clientmac" value="<?= htmlspecialchars($client_mac) ?>">
            <input type="hidden" name="redir"     value="<?= htmlspecialchars($redir) ?>">
            <input type="hidden" name="tok"       value="<?= htmlspecialchars($tok) ?>">

            <input type="text"
                   name="voucher"
                   placeholder="Code (ex : 1H, 30M)"
                   autocomplete="off"
                   autocapitalize="characters"
                   required>
            <button type="submit">Se connecter</button>
        </form>
    </div>
</body>
</html>
PHPEOF

# Remplacement du placeholder ###FAS_KEY### par la vraie clé
# générée à l'étape 3 par openssl
sed -i "s/###FAS_KEY###/$FAS_KEY/" /var/www/html/mon_portail.php

# Le fichier doit appartenir à www-data (utilisateur Apache)
# pour qu'Apache puisse le lire et l'exécuter
chown www-data:www-data /var/www/html/mon_portail.php


# ============================================================
# ACTIVATION DES SERVICES
# ============================================================
# On active les trois services pour qu'ils démarrent
# automatiquement à chaque démarrage du Pi :
#   hostapd  : Point d'accès Wi-Fi
#   dnsmasq  : DHCP + DNS
#   opennds  : Gestion du portail captif
# ============================================================
systemctl enable hostapd dnsmasq opennds


# ============================================================
# RÉCAPITULATIF FINAL
# ============================================================
echo ""
echo "======================================================"
echo "   INSTALLATION TERMINÉE AVEC SUCCÈS — V3"
echo "======================================================"
echo ""
echo "  SSID (nom du réseau) : $SSID"
echo "  Interface Wi-Fi      : $WIFI_IF"
echo "  Interface Internet   : $ETH_IF"
echo "  IP du portail        : http://192.168.50.1"
echo "  Port auth OpenNDS    : 2050"
echo ""
echo "  Codes voucher disponibles :"
echo "    1H    → 60 minutes d'accès"
echo "    30M   → 30 minutes d'accès"
echo "    ADMIN → 24 heures d'accès"
echo ""
echo "  Trafic redirigé : TOUT TCP sauf ports 22 (SSH) et 2050 (auth)"
echo "  SSH autorisé uniquement depuis : $ETH_IF (filaire)"
echo ""
echo "======================================================"
echo ""
echo "ATTENTION : Le système va redémarrer pour appliquer toutes les configurations."
echo "Assurez-vous qu'aucun travail important n'est en cours."
echo ""

# Boucle de confirmation avec validation de la réponse
while true; do
    read -p "Voulez-vous redémarrer maintenant ? (o/n) : " confirm
    case $confirm in
        [oO]|[oO][uU][iI])
            echo "Redémarrage du système..."
            reboot
            break
            ;;
        [nN]|[nN][oO][nN])
            echo "Redémarrage annulé."
            echo "NOTE : Certaines configurations ne seront actives qu'après le prochain redémarrage."
            echo "Vous pouvez redémarrer manuellement plus tard avec : sudo reboot"
            break
            ;;
        *)
            echo "Réponse invalide. Veuillez répondre par 'o' (oui) ou 'n' (non)."
            ;;
    esac
done