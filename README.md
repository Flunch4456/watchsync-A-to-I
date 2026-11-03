# WatchLink — étape 1 : rythme cardiaque montre → iPhone

Deux petites apps qui se parlent en Bluetooth Low Energy :

- `wear/` : app Wear OS pour la Galaxy Watch FE. Elle lit le capteur cardiaque et se présente à l'iPhone comme un capteur Bluetooth standard (profil « Heart Rate »).
- `ios/` : app iPhone (SwiftUI). Elle se connecte à la montre et affiche les battements en direct.

Pourquoi ce choix : le profil Heart Rate est un standard Bluetooth. Pas besoin de protocole maison, et l'iPhone sait le lire nativement.

## Nouveautés de la version 0.5.0

- **Notifications iPhone → montre** (réglage dans Réglages > Notifications sur la montre) : la montre se connecte au service de notifications d'Apple (ANCS). Il faut l'appairer (iOS le propose) puis activer « Partager les notifications du système » dans Réglages iOS > Bluetooth > (i) à côté de la montre. Retour arrière : branche `stable-v0.4.0`.
- **Sonnerie de l'iPhone** : bip en boucle même écran éteint (mode audio en arrière-plan), en plus des notifications sonores de secours. Le volume dépend de celui de l'iPhone.

## Nouveautés de la version 0.4.0

- **Liaison par code** : sur la montre, touche « Lier l'iPhone » → un code à 6 chiffres s'affiche (valable 2 min). Tape-le sur l'iPhone. Ensuite la montre ne parle qu'à cet iPhone. Pour changer d'iPhone, « Oublier la liaison » sur la montre.
- **Montre retirée** : la mesure cardiaque est coupée et l'iPhone envoie une notification « Montre retirée » (réglable).
- **Mesures hors connexion** : sans iPhone, la montre garde rythme, batterie et pas 7 jours et les envoie à la reconnexion.
- **Depuis la montre** : boutons pour faire sonner / vibrer / annuler l'iPhone. Écran allumé : son + vibration. Écran éteint : iOS limite aux notifications sonores répétées pendant 1 minute.
- Onglet **Santé** : sommeil estimé (approximatif, d'après le rythme cardiaque la nuit) et rythme au repos.
- Limite : Samsung Health ne donne pas son sommeil à une app tierce sur la montre ; l'estimation est donc la nôtre.

Retour arrière : branche `stable-v0.3.0`.

## Nouveautés de la version 0.3.0

- Fréquence de la mesure cardiaque réglable depuis l'iPhone : en continu, toutes les 10 s / 30 s / 1 min / 5 min / 15 min, ou désactivée (pour économiser la batterie).
- Pas du jour comptés par la montre, et distance estimée à partir de ta taille (réglable). Onglet **Activité** avec les pas des 7 derniers jours.
- Graphique de la batterie de la montre sur 48 h.
- Boutons pour faire sonner la montre, la faire vibrer seulement, ou annuler.
- Icône pour les deux apps.

Pour que la montre compte les pas, accorde aussi cette permission si l'app ne la demande pas :

```
adb shell pm grant fr.nino.watchlink android.permission.ACTIVITY_RECOGNITION
```

## Fonctions (version 0.2.0)

App iPhone, trois onglets :

- **En direct** : battements, niveau de batterie de la montre, min / moyenne / max de la session, courbe des 2 dernières minutes.
- **Historique** : sessions des 7 derniers jours avec courbe et statistiques, export CSV (par session ou tout d'un coup).
- **Réglages** : alertes de rythme (seuils bas et haut, vibration de la montre, notification iPhone), démarrage automatique de la montre, bouton pour faire sonner la montre.

App montre : diffusion en arrière-plan écran éteint (service au premier plan), reprise automatique après un redémarrage, vibration d'alerte, sonnerie de recherche (coupée seule après 1 minute ou avec le bouton « Couper la sonnerie »).

Pas encore : l'affichage des notifications de l'iPhone sur la montre (étape suivante).

Pour revenir à la première version stable : le tag `v0.1.0-stable` de ce dépôt.

Conseil pour que Samsung ne coupe pas l'app en arrière-plan : `adb shell dumpsys deviceidle whitelist +fr.nino.watchlink`

## 1. Compiler (sur GitHub, sans Mac)

1. Pousse ce dossier dans un dépôt GitHub.
2. Onglet **Actions** → le workflow **Build** se lance tout seul à chaque push.
3. Quand il est vert, ouvre l'exécution et télécharge les deux « Artifacts » :
   - `WatchLink-montre-apk` → contient `app-debug.apk`
   - `WatchLink-iphone-ipa` → contient `WatchLink.ipa`

Les artifacts sont des zips : décompresse-les.

## 2. Installer l'APK sur la montre (PC Windows)

```
adb connect IP_DE_LA_MONTRE:PORT
adb install -r app-debug.apk
```

L'IP et le port sont affichés dans les options développeur de la montre, section Débogage ADB via Wi-Fi.

Au premier lancement, l'app demande les permissions (capteurs, Bluetooth, notifications). Tu peux aussi les accorder par ADB :

```
adb shell pm grant fr.nino.watchlink android.permission.BODY_SENSORS
adb shell pm grant fr.nino.watchlink android.permission.BLUETOOTH_CONNECT
adb shell pm grant fr.nino.watchlink android.permission.BLUETOOTH_ADVERTISE
adb shell pm grant fr.nino.watchlink android.permission.POST_NOTIFICATIONS
```

## 3. Installer l'IPA sur l'iPhone

Ouvre `WatchLink.ipa` avec SideStore (partager → SideStore), qui la signe avec ton certificat.

## 4. Tester

1. Sur la montre : ouvre **WatchLink** → **Démarrer**. Garde-la bien serrée au poignet pour que le capteur mesure.
2. Sur l'iPhone : ouvre **WatchLink**, autorise le Bluetooth, touche ta montre dans la liste (« Galaxy Watch FE … »).
3. Les battements s'affichent. La montre est mémorisée : la reconnexion se fait ensuite toute seule.

## Si ça ne marche pas

- La montre n'apparaît pas dans la liste : vérifie que l'app montre est bien démarrée (statut « En attente de l'iPhone… »).
- Statut « Pas de capteur cardiaque » ou le BPM reste à `--` : le capteur met quelques secondes à démarrer, et il faut que la montre soit portée.
- Le build GitHub échoue : copie-moi l'erreur du log, je corrige.

## Prochaines étapes

2. Notifications iPhone → montre (service ANCS d'Apple)
3. Réglages et finitions
