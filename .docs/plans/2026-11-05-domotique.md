# Stack domotique (babyphone) : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** une stack `domotique` sur athena (Frigate + Mosquitto + Home Assistant) qui offre le
direct audio et vidéo de la caméra E220 derrière Traefik et Authelia, et envoie sur le topic ntfy
`babyphone` une alerte de bruit, de mouvement ou de caméra hors ligne.

**Architecture :** Frigate lit le RTSP de la caméra, sert le direct (MSE par websocket via Traefik)
et publie le niveau sonore, le mouvement et ses statistiques sur Mosquitto. Home Assistant lit ces
topics MQTT avec ses propres capteurs YAML (indépendants des noms d'entités de l'intégration
Frigate) et ses automatisations publient via l'intégration ntfy.

**Technologies :** Docker Compose, Frigate 0.18.2, Home Assistant 2026.11.0, Mosquitto 2.1.2,
`orchestrator-cli`.

**Spec :** [.docs/specs/2026-11-05-domotique-design.md](../specs/2026-11-05-domotique-design.md)

## Contraintes globales

- Branche `stack-domotique` (choisie par le propriétaire, hors convention `release/*`) : le push
  et la PR demandent son accord.
- Images, copiées telles quelles :
  - `ghcr.io/blakeblackshear/frigate:0.18.2@sha256:fd60f99ffd4eb6c42360ed4e14953e270586f239309ab3983e55b2e97ffac09a`
  - `ghcr.io/home-assistant/home-assistant:2026.11.0@sha256:c6c1ca9931036bf3a2c4cc088d8db25dfea3b33935a5ecc83c40349462e2f69e`
  - `docker.io/library/eclipse-mosquitto:2.1.2-alpine@sha256:48b5f8c14504da1155156282ecc557897ff002cd60fd604aa2fd74d47bb725ff`
- Nom de la caméra dans Frigate : `babyphone`. IP : `192.168.1.50`.
- Topic ntfy : `babyphone`. Délai minimal entre deux alertes d'un même type : 5 min.
- Toute écriture dans `/mnt/secrets` ou `/mnt/docker-data` demande l'accord du propriétaire,
  et aucune valeur de secret n'apparaît dans un fichier, un commit ou une réponse.
- Rien n'est déployé par l'implémenteur : le déploiement se fait par la fusion de la PR.
- Définition de terminé : `orchestrator-cli lint` passe.

## Écarts assumés par rapport à la spec

- **Direct en MSE, pas en WebRTC.** WebRTC demande un port UDP/TCP 8555 joignable par le
  téléphone, ce que Traefik ne relaie pas. MSE passe par le websocket HTTP, donc par Authelia.
  MSE exige de l'AAC : go2rtc transcode l'audio (`#audio=aac`).
- **Mosquitto sans volume.** Sa configuration et son fichier de mots de passe sont générés au
  démarrage depuis `MQTT_PASSWORD`, sans persistance : Frigate republie ses états. Il n'y a plus
  de dossier `domotique/mosquitto`.
- **Carte de direct native de HA** (`picture-entity`, `camera_view: live`) au lieu d'une carte
  HACS : l'intégration Frigate fournit l'entité caméra, rien d'autre à installer.
- **Automatisations dans un paquet HA** (`packages/babyphone.yaml`), en YAML pur, pour qu'elles
  ne soient pas réécrites par l'éditeur d'automatisations de l'interface.

## Points de vigilance

1. **Frigate redémarre, les capteurs MQTT de HA restent sur leur dernière valeur.** Le capteur de
   statistiques a un `expire_after` ; l'alerte « hors ligne » doit aussi partir quand ce capteur
   devient `unavailable` (Frigate arrêté), pas seulement quand les images par seconde tombent à 0.
2. **Bruit continu** (pleurs prolongés, aspirateur) : une alerte, puis au plus une toutes les
   5 min, jamais une rafale.
3. **Basculement jour / infrarouge** : il ne doit pas déclencher d'alerte mouvement (vérifié au
   crépuscule, `lightning_threshold` par défaut).
4. **HA derrière Traefik** : sans `trusted_proxies` correct, HA répond 400 à toute requête
   venant d'apollon.
5. **Identifiants RTSP avec des caractères spéciaux** (`@`, `:`, `/`) : ils cassent l'URL RTSP,
   il faut les encoder en pourcentage ou les éviter.

---

### Tâche 1 : identifiants de la caméra, variables et vérification des flux

**Fichiers :**
- Modifier : `/mnt/secrets/ports.env` (accord requis)
- Créer : `/mnt/secrets/domotique/domotique.env` (accord requis)

**Interfaces :**
- Produit : `ATHENA_FRIGATE_PORT`, `ATHENA_HOME_ASSISTANT_PORT`, `CAMERA_RTSP_USER`,
  `CAMERA_RTSP_PASSWORD`, `MQTT_PASSWORD`. Chemins RTSP confirmés `/ch0` et `/ch1`.

- [ ] **Étape 1 : choisir les ports.** Prendre les deux prochains ports libres de la plage
  athena (12000) dans `ports.env`, les annoncer au propriétaire avec les trois autres variables.
- [ ] **Étape 2 : obtenir les identifiants RTSP** du propriétaire (ceux de l'interface Thingino).
  S'ils contiennent `@`, `:` ou `/`, lui demander d'en changer.
- [ ] **Étape 3 : écrire les variables après accord.** Générer `MQTT_PASSWORD` avec
  `openssl rand -hex 24`, l'écrire directement dans le fichier sans l'afficher.
- [ ] **Étape 4 : vérifier les flux** sans afficher les identifiants :

  Run : `set -a; . /mnt/secrets/domotique/domotique.env; set +a; for c in ch0 ch1; do ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_type,codec_name,width,height -of compact "rtsp://$CAMERA_RTSP_USER:$CAMERA_RTSP_PASSWORD@192.168.1.50/$c"; done`
  (depuis athena si dev-vm-home ne joint pas `192.168.1.50`)
  Attendu : pour chaque flux, une ligne `codec_type=video` (h264 ou hevc) et une ligne
  `codec_type=audio`. `ch1` a une résolution inférieure à `ch0`. Pas d'audio : activer le micro
  dans l'interface Thingino avant de continuer.

### Tâche 2 : fichier compose et Renovate

**Fichiers :**
- Créer : `domotique/athena.domotique.yml`
- Modifier : `.github/renovate.json` (ligne 32 : `managerFilePatterns` ; nouvelle règle après
  « One PR for bitwarden »)

**Interfaces :**
- Consomme : les variables de la tâche 1, plus `TIMEZONE` et `PUBLIC_DOMAIN_NAME` (`env.env`).
- Produit : services `frigate` (port conteneur 5000, sans authentification), `mosquitto`
  (1883, non publié), `home-assistant` (8123). Variables d'environnement vues par les
  conteneurs :
  - `frigate` : `FRIGATE_MQTT_PASSWORD`, `FRIGATE_RTSP_USER`, `FRIGATE_RTSP_PASSWORD`, `TZ` ;
  - `mosquitto` : `MQTT_PASSWORD` ;
  - `home-assistant` : `TZ`, `FRIGATE_URL=https://frigate.${PUBLIC_DOMAIN_NAME}`.

- [ ] **Étape 1 : écrire le fichier compose** en suivant le modèle de `jellyfin`
  ([media/athena.media.yml](../../media/athena.media.yml)) :
  - `frigate` : `runtime: nvidia` + réservation GPU comme jellyfin ; `shm_size: 256mb` ; tmpfs
    `/tmp/cache` (1 Go) ; volumes `docker-data` `domotique/frigate/config` → `/config` et
    `domotique/frigate/media` → `/media/frigate` ; port `${ATHENA_FRIGATE_PORT}:5000` ; labels
    `homepage.service: Frigate`, `traefik-conf.port: ${ATHENA_FRIGATE_PORT}` ; healthcheck
    `curl -f http://localhost:5000/api/version`.
  - `mosquitto` : pas de port, pas de volume ; `command` en `sh -c` qui écrit
    `/tmp/mosquitto.conf` (`listener 1883`, `allow_anonymous false`,
    `password_file /tmp/passwd`), crée `/tmp/passwd` avec
    `mosquitto_passwd -c -b /tmp/passwd domotique "$$MQTT_PASSWORD"`, le passe à
    `mosquitto:mosquitto` en `0700`, puis `exec mosquitto -c /tmp/mosquitto.conf` ;
    healthcheck `mosquitto_sub -u domotique -P "$$MQTT_PASSWORD" -t '$$SYS/broker/uptime' -C 1 -W 3`.
  - `home-assistant` : volume `docker-data` `domotique/home-assistant` → `/config` ; port
    `${ATHENA_HOME_ASSISTANT_PORT}:8123` ; labels `homepage.service: Home Assistant`,
    `traefik-conf.port: ${ATHENA_HOME_ASSISTANT_PORT}` ; healthcheck
    `curl -f http://localhost:8123/manifest.json` ; `depends_on: mosquitto`.
- [ ] **Étape 2 : ajouter `domotique`** à la liste de `managerFilePatterns` (ordre
  alphabétique, après `bitwarden`) et une règle `"One PR for domotique"` /
  `"matchFileNames": ["domotique/**"]` / `"groupName": "domotique"` après celle de bitwarden.
- [ ] **Étape 3 : lint.**

  Run : `cd /mnt/dev/orchestrator && orchestrator-cli lint && jq empty .github/renovate.json`
  Attendu : `All compose files are valid`, et `jq` sans sortie.
- [ ] **Étape 4 : commit** `feat(domotique): stack Frigate, Mosquitto et Home Assistant`.

### Tâche 3 : configuration de Frigate

**Fichiers :**
- Créer : `/mnt/docker-data/domotique/frigate/config/config.yml` (accord requis)

**Interfaces :**
- Consomme : variables `FRIGATE_*` de la tâche 2.
- Produit : caméra `babyphone` ; topics `frigate/babyphone/audio/dBFS`,
  `frigate/babyphone/motion` (`ON`/`OFF`), `frigate/stats`
  (`cameras.babyphone.camera_fps`) ; flux go2rtc `rtsp://frigate:8554/babyphone` (audio AAC).

- [ ] **Étape 1 : écrire `config.yml`** :
  - `mqtt` : hôte `mosquitto`, utilisateur `domotique`, mot de passe `{FRIGATE_MQTT_PASSWORD}`.
  - `ffmpeg.hwaccel_args: preset-nvidia`.
  - `go2rtc.streams` :
    - `babyphone` : `rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@192.168.1.50/ch0`, puis
      `ffmpeg:babyphone#audio=aac` ;
    - `babyphone_sub` : même URL en `/ch1`.
  - `cameras.babyphone.ffmpeg.inputs` :
    - `rtsp://127.0.0.1:8554/babyphone`, rôles `record` et `audio` ;
    - `rtsp://127.0.0.1:8554/babyphone_sub`, rôle `detect`.
  - `cameras.babyphone.live.streams` : `babyphone`, pour que le direct ait le son.
  - `audio.enabled: true`. Écoute (`listen`) et détection d'objets : valeurs par défaut.
  - Enregistrement activé, 3 jours de rétention, avec la clé de rétention de la version 0.18
    (doc « Recording » de Frigate 0.18).
- [ ] **Étape 2 : vérifier l'absence de secret en clair.**

  Run : `rg -n '@192' /mnt/docker-data/domotique/frigate/config/config.yml`
  Attendu : seulement des lignes avec `{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}`.

  La validation complète se fait au démarrage de Frigate (tâche 5).

### Tâche 4 : configuration de Home Assistant

**Fichiers :**
- Créer : `/mnt/docker-data/domotique/home-assistant/configuration.yaml` (accord requis)
- Créer : `/mnt/docker-data/domotique/home-assistant/packages/babyphone.yaml` (accord requis)

**Interfaces :**
- Consomme : topics de la tâche 3 ; entité `notify.babyphone` (créée par le propriétaire en
  tâche 5) ; entité caméra Frigate (nom relevé en tâche 5, `camera.babyphone` attendu).
- Produit : `sensor.babyphone_dbfs`, `binary_sensor.babyphone_motion`, `sensor.babyphone_fps`,
  automatisations `babyphone_bruit`, `babyphone_mouvement`, `babyphone_hors_ligne`.

- [ ] **Étape 1 : écrire `configuration.yaml`** :
  - `default_config:` ;
  - `http` : `use_x_forwarded_for: true`, `trusted_proxies: [100.64.98.99]` (apollon) ;
  - `homeassistant.packages: !include_dir_named packages` ;
  - `automation: !include automations.yaml`, avec un `automations.yaml` vide (`[]`) pour l'éditeur
    de l'interface.
- [ ] **Étape 2 : écrire `packages/babyphone.yaml`.**
  - Capteurs MQTT :
    - `sensor.babyphone_dbfs` : topic `frigate/babyphone/audio/dBFS`, unité `dB`,
      `expire_after: 60` ;
    - `binary_sensor.babyphone_motion` : topic `frigate/babyphone/motion`, `ON`/`OFF`,
      `device_class: motion` ;
    - `sensor.babyphone_fps` : topic `frigate/stats`, gabarit
      `{{ value_json.cameras.babyphone.camera_fps }}`, `expire_after: 180`.
  - Automatisations, toutes `mode: single`, action `ntfy.publish` sur `notify.babyphone`, avec
    `click: !env_var FRIGATE_URL` :

  | id                     | déclencheur                                                                   | priorité | titre / message                                    | fin                 |
  | ---------------------- | ----------------------------------------------------------------------------- | -------- | -------------------------------------------------- | ------------------- |
  | `babyphone_bruit`      | `numeric_state` de `sensor.babyphone_dbfs` `above: -35` pendant 3 s           | 5        | « Babyphone » / « Bruit dans la chambre »          | `delay: 00:05:00`   |
  | `babyphone_mouvement`  | `binary_sensor.babyphone_motion` passe à `on`                                 | 4        | « Babyphone » / « Mouvement dans la chambre », `attach_file` de l'entité caméra Frigate, `filename: babyphone.jpg` | `delay: 00:05:00` |
  | `babyphone_hors_ligne` | gabarit `{{ states('sensor.babyphone_fps') \| float(0) < 1 }}` pendant 2 min | 5        | « Babyphone » / « Caméra hors ligne »              | aucune              |

  La capture de `babyphone_mouvement` :
  `attach_file: {media_content_id: media-source://camera/camera.babyphone, media_content_type: image/jpeg}`.
  Le seuil `-35` reçoit le commentaire
  `# shortcut: seuil arbitraire, à recaler d'après sensor.babyphone_dbfs une fois la caméra installée`.
  Le gabarit de `babyphone_hors_ligne` couvre aussi `unavailable` (Frigate arrêté) grâce à
  `float(0)` (vigilance 1).
- [ ] **Étape 3 : valider la configuration** sans démarrer HA :

  Run : `docker run --rm -e FRIGATE_URL=https://frigate.example -v /mnt/docker-data/domotique/home-assistant:/config ghcr.io/home-assistant/home-assistant:2026.11.0@sha256:c6c1ca9931036bf3a2c4cc088d8db25dfea3b33935a5ecc83c40349462e2f69e python -m homeassistant --script check_config -c /config`
  Attendu : `Configuration check successful!` ou seulement des erreurs sur des intégrations pas
  encore configurées (MQTT, ntfy). Supprimer ensuite les fichiers que `check_config` aurait créés
  dans `/config`, hormis les nôtres.

### Tâche 5 : PR, déploiement et mise en service

**Fichiers :** aucun nouveau.

**Interfaces :**
- Consomme : tout ce qui précède.

- [ ] **Étape 1 : pousser et ouvrir la PR, après l'accord du propriétaire.**
  `git push -u origin stack-domotique`, puis
  `gh pr create --base main --title "Stack domotique : babyphone"`. La description, en français,
  liste les trois services, les écarts assumés et les vérifications faites.
- [ ] **Étape 2 : suivre la CI.**

  Run : `gh pr checks --watch`
  Attendu : Lint vert. Annoncer le résultat réel avec l'URL de la PR. Le propriétaire fusionne,
  ce qui déploie.
- [ ] **Étape 3 : vérifier le déploiement (lecture seule).**

  Run : `docker --context athena ps --filter name='frigate|mosquitto|home-assistant' --format '{{.Names}} {{.Status}}'`
  Attendu : trois lignes `(healthy)`.

  Run : `docker --context athena logs frigate 2>&1 | rg -i 'error|babyphone' | tail -20`
  Attendu : pas d'erreur de configuration ni de connexion RTSP ou MQTT.
- [ ] **Étape 4 : étapes d'interface, faites par le propriétaire.**
  1. Créer le compte HA.
  2. Ajouter l'intégration MQTT : hôte `mosquitto`, port 1883, utilisateur `domotique`.
  3. Installer HACS, puis l'intégration Frigate (URL `http://frigate:5000`).
  4. Ajouter l'intégration ntfy : URL de `NTFY_SERVER`, avec un compte ntfy, et un topic
     `babyphone` (entité `notify.babyphone`).
  5. S'abonner au topic `babyphone` dans l'application ntfy du téléphone.

  Relever le nom réel de l'entité caméra Frigate. S'il diffère de `camera.babyphone`, corriger
  `babyphone_mouvement`, puis recharger les automatisations.
- [ ] **Étape 5 : tableau de bord.** Le propriétaire ajoute une carte `picture-entity` sur
  l'entité caméra, avec `camera_view: live`.
- [ ] **Étape 6 : tests de bout en bout**, avec le propriétaire :
  - un claquement de mains donne une alerte « Bruit », et un second dans les 5 min n'en donne
    aucune (vigilance 2) ;
  - un geste devant la caméra donne une alerte « Mouvement » avec la capture jointe ;
  - la caméra débranchée 2 min donne une alerte « Caméra hors ligne » ;
  - `https://frigate.<domaine>` et `https://home-assistant.<domaine>` demandent Authelia, puis
    le direct joue avec le son dans le navigateur du téléphone (vigilance 4) ;
  - au premier crépuscule, le basculement infrarouge ne donne aucune alerte « Mouvement »
    (vigilance 3).
