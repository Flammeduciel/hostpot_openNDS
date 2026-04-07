# Hotspot OpenNDS - Portail Captif

Ce projet transforme un Raspberry Pi (ou système Linux équivalent) en hotspot Wi-Fi avec portail captif basé sur OpenNDS.

## Scripts disponibles

### 1. `install_opennds_v3.sh` - Version complète avec internet
- **Usage** : Installation complète pour un hotspot avec partage de connexion internet
- **Requis** : Câble Ethernet branché pour la connexion internet
- **Fonctionnalités** : Hotspot Wi-Fi + Portail captif + Accès internet pour les clients authentifiés

### 2. `install_opennds_sans_internet.sh` - Version test sans internet
- **Usage** : Mode test/développement sans connexion internet
- **Requis** : Uniquement une interface Wi-Fi (pas de câble Ethernet)
- **Fonctionnalités** : Hotspot Wi-Fi + Portail captif (accès réseau local uniquement)

## Fonctionnalités communes

- **Hotspot Wi-Fi automatique** : Détection automatique des interfaces réseau
- **Portail captif OpenNDS** : Authentification par voucher (codes pré-définis)
- **Page PHP personnalisable** : Interface web d'authentification moderne
- **Sécurité renforcée** : Règles iptables restrictives et SSH sécurisé
- **Configuration automatique** : DHCP, DNS, et services configurés automatiquement

## Vouchers disponibles

| Code | Durée d'accès | Usage |
|------|--------------|-------|
| `1H` | 60 minutes | Accès standard |
| `30M` | 30 minutes | Accès court |
| `ADMIN` | 24 heures | Accès administrateur |

## Installation

### Prérequis
- Raspberry Pi ou système Linux équivalent
- Adaptateur Wi-Fi compatible
- Droits root (sudo)

### Installation version complète (avec internet)
```bash
sudo ./install_opennds_v3.sh
```

### Installation version test (sans internet)
```bash
sudo ./install_opennds_sans_internet.sh
```

## Configuration réseau

- **IP du hotspot** : `192.168.50.1/24`
- **Plage DHCP** : `192.168.50.50` à `192.168.50.150`
- **Portail captif** : `http://192.168.50.1`
- **API OpenNDS** : Port `2050`

## Architecture technique

### Services installés
- **hostapd** : Point d'accès Wi-Fi
- **dnsmasq** : Serveur DHCP et DNS
- **opennds** : Gestionnaire de portail captif
- **apache2 + php** : Serveur web pour le portail
- **iptables-persistent** : Sauvegarde des règles pare-feu

### Sécurité
- **Politique INPUT DROP** : Tout le trafic entrant bloqué par défaut
- **SSH sécurisé** : Autorisé uniquement depuis l'interface filaire (version complète)
- **Ports essentiels** : DNS (53), DHCP (67), HTTP (80), OpenNDS (2050)

## Utilisation

1. **Exécuter le script d'installation**
2. **Choisir le SSID et le mot de passe Wi-Fi**
3. **Redémarrer le système**
4. **Se connecter au hotspot Wi-Fi**
5. **S'authentifier via le portail captif avec un voucher**

## Développement et tests

### Mode test sans internet
La version `install_opennds_sans_internet.sh` est idéale pour :
- Tester le portail captif sans connexion internet
- Développer des pages personnalisées
- Déboguer les configurations

### Autoriser des services supplémentaires
Pour tester d'autres services (ex: Node.js sur port 3000) :
```bash
sudo iptables -A INPUT -i wlan0 -p tcp --dport 3000 -j ACCEPT
sudo netfilter-persistent save
```

## Fichiers de configuration

- `/etc/hostapd/hostapd.conf` : Configuration point d'accès Wi-Fi
- `/etc/dnsmasq.conf` : Configuration DHCP et DNS
- `/etc/opennds/opennds.conf` : Configuration portail captif
- `/var/www/html/mon_portail.php` : Page d'authentification
- `/etc/iptables/rules.v4` : Règles pare-feu IPv4

## Maintenance

### Redémarrer les services
```bash
sudo systemctl restart hostapd dnsmasq opennds
```

### Voir les logs
```bash
sudo journalctl -u hostapd -f
sudo journalctl -u opennds -f
sudo journalctl -u dnsmasq -f
```

### Voir les clients connectés
```bash
sudo ndsctl status
```

## Sécurité

- **Clé FAS** : Générée aléatoirement pour sécuriser la communication OpenNDS-PHP
- **Vouchers** : Codes pré-définis (modifiables dans le PHP)
- **Pare-feu** : Configuration restrictive par défaut
- **SSH** : Administration sécurisée via interface filaire uniquement

## Personnalisation

### Modifier les vouchers
Éditer `/var/www/html/mon_portail.php` :
```php
$vouchers = [
    "CODE1" => 120,    // 2 heures
    "CODE2" => 30,     // 30 minutes
    "ADMIN" => 1440,   // 24 heures
];
```

### Personnaliser la page du portail
Modifier le fichier `/var/www/html/mon_portail.php` pour changer :
- Le design et les couleurs
- Les textes et messages
- Les logos et images

## Support

Pour tout problème ou question :
1. Vérifier les logs des services
2. Confirmer la compatibilité de l'adaptateur Wi-Fi
3. S'assurer que les droits root sont corrects

## Licence

Projet libre et open-source pour usage éducatif et expérimental.
