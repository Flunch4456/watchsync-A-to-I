# WatchLink — étape 1 : rythme cardiaque montre → iPhone

Deux petites apps qui se parlent en Bluetooth Low Energy :

- `wear/` : app Wear OS pour la Galaxy Watch FE. Elle lit le capteur cardiaque et se présente à l'iPhone comme un capteur Bluetooth standard (profil « Heart Rate »).
- `ios/` : app iPhone (SwiftUI). Elle se connecte à la montre et affiche les battements en direct.

Pourquoi ce choix : le profil Heart Rate est un standard Bluetooth. Pas besoin de protocole maison, et l'iPhone sait le lire nativement.

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
