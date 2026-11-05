# Stack domotique : babyphone

Date : 2026-11-05. Branche : `stack-domotique`.

## Objectif

Utiliser la caméra E220 flashée avec Thingino comme babyphone :

- regarder et écouter le direct depuis le navigateur du téléphone, derrière Traefik et Authelia ;
- recevoir une notification ntfy quand la caméra entend du bruit ou voit du mouvement ;
- être prévenu si la caméra cesse de fonctionner.

La stack s'appelle `domotique` : elle accueillera plus tard d'autres appareils.

## Hors périmètre

- Reconnaissance des pleurs (classification audio) et détection du réveil (pose, yeux, mouvement
  soutenu dans le lit) : le bébé n'est pas né, on part d'une détection simple de bruit et de
  mouvement. Ces détections pourront remplacer les déclencheurs plus tard sans changer
  l'architecture.
- Détection d'objets Frigate et Frigate+.
- Application mobile Home Assistant : elle ne passe pas le forward-auth d'Authelia, l'accès se
  fait par le navigateur.
- Mode armé ou plages horaires : la détection est toujours active.

## Contexte vérifié

- La caméra est à `192.168.1.50` sur le LAN. Depuis athena, le port 554 répond en RTSP
  (`401 Unauthorized`, Digest, realm `thingino`) et l'interface web répond sur 80 et 443.
- athena a une RTX 2080 SUPER (8 Go, inutilisée), 8 cœurs et 11 Go de RAM (environ 6,7 Go
  disponibles).
- ntfy tourne sur apollon (stack `utils`) ; les stacks `backup` y publient via `NTFY_SERVER`.
- Le GPU est déjà utilisé sur athena par Jellyfin (`runtime: nvidia` + réservation `deploy`).

## Architecture

Un fichier : `domotique/athena.domotique.yml`, `name: domotique`.

| Service          | Rôle                                                                                                                                  | Exposition                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `frigate`        | Lit le RTSP de la caméra ; go2rtc intégré pour le direct WebRTC/MSE avec le son ; niveau sonore ; détection de mouvement ; enregistrements | Traefik + Authelia (`traefik-conf.port`), authentification Frigate désactivée |
| `mosquitto`      | Bus MQTT entre Frigate et Home Assistant                                                                                              | Réseau interne de la stack, aucun port publié                                |
| `home-assistant` | Intégration Frigate (HACS), intégration ntfy, automatisations d'alerte, tableau de bord avec le direct                               | Traefik + Authelia (`traefik-conf.port`), `trusted_proxies` = apollon        |

```
Caméra E220 (192.168.1.50, RTSP ch0 / ch1)
   │
   ▼
frigate ──(direct WebRTC/MSE)──▶ Traefik / Authelia ──▶ navigateur du téléphone
   │ MQTT : niveau sonore, mouvement, captures
   ▼
mosquitto ──▶ home-assistant ──(intégration ntfy)──▶ ntfy (apollon), topic babyphone
```

- Le RTSP reste sur le LAN entre athena et la caméra.
- Le sous-flux `ch1` sert à la détection, le flux principal `ch0` au direct et aux
  enregistrements.
- Le GPU sert au décodage vidéo de Frigate (même configuration que Jellyfin).
- Données et configuration sous le volume `docker-data` : `domotique/frigate`,
  `domotique/mosquitto`, `domotique/home-assistant`. La configuration Frigate, `mosquitto.conf`
  et les automatisations HA y vivent, sauvegardées par la stack `backup`, non versionnées.
- Enregistrements Frigate : 3 jours de rétention.
- La stack est ajoutée à `.github/renovate.json` (alternance de `managerFilePatterns` et règle
  `packageRules` à son nom).

## Détection et alertes

| Alerte       | Déclencheur (automatisation HA)                                 | Priorité ntfy | Contenu                                            |
| ------------ | --------------------------------------------------------------- | ------------- | -------------------------------------------------- |
| Bruit        | niveau sonore Frigate (dBFS) au-dessus du seuil pendant 3 s     | urgente (5)   | « Bruit dans la chambre », lien vers le direct     |
| Mouvement    | capteur de mouvement Frigate actif                              | haute (4)     | « Mouvement dans la chambre », capture, lien direct |
| Hors ligne   | caméra indisponible dans HA depuis 2 min                        | urgente (5)   | « Babyphone : caméra hors ligne »                  |

- Délai minimal de 5 min entre deux alertes d'un même type (`mode: single` terminé par un
  `delay`).
- Seuil sonore : réglé une fois la caméra installée, d'après les niveaux mesurés.
- Mouvement : valeurs par défaut de Frigate, sans masque. `lightning_threshold` reste actif et
  ignore le basculement jour / infrarouge.
- Topic ntfy dédié `babyphone`, pour une sonnerie et une priorité propres sur le téléphone.
- Le direct : une page du tableau de bord HA avec la carte Frigate (son activé) ; l'interface
  Frigate en direct sert de repli.

## Variables

À créer après accord, au moment de l'implémentation :

| Variable                     | Fichier                                  | Valeur                                    |
| ---------------------------- | ---------------------------------------- | ----------------------------------------- |
| `ATHENA_FRIGATE_PORT`        | `/mnt/secrets/ports.env`                 | prochain port libre de la plage 12000     |
| `ATHENA_HOME_ASSISTANT_PORT` | `/mnt/secrets/ports.env`                 | prochain port libre de la plage 12000     |
| `CAMERA_RTSP_USER`           | `/mnt/secrets/domotique/domotique.env`   | fourni par le propriétaire                |
| `CAMERA_RTSP_PASSWORD`       | `/mnt/secrets/domotique/domotique.env`   | fourni par le propriétaire                |
| `MQTT_PASSWORD`              | `/mnt/secrets/domotique/domotique.env`   | aléatoire, généré                         |

## Pannes

- Caméra hors ligne : alerte ntfy (voir ci-dessus).
- Healthchecks : `frigate` (`/api/version`), `home-assistant` (`/manifest.json`), `mosquitto`
  (`mosquitto_sub` sur `$SYS`, avec une limite de temps).
- ntfy injoignable : rien de prévu, comme pour les sauvegardes. Les logs passent par vector et
  dozzle.

## Points à vérifier pendant le plan

1. Le capteur de niveau sonore exposé par Frigate et par son intégration HA (nom de l'entité, unité).
2. Le codec audio de la caméra : WebRTC exige Opus ou PCMU, sinon go2rtc transcode.
3. La capacité de l'action ntfy de HA à joindre une capture ; à défaut, le message ne contient
   que le lien vers le direct.
4. La façon dont HA joint ntfy (même `NTFY_SERVER` que les sauvegardes, authentification).

## Vérification

- Avant le push : `orchestrator-cli lint` passe.
- PR : Lint et notification ntfy ; rien n'est déployé avant la fusion.
- Après la fusion par le propriétaire :
  1. les trois conteneurs sont `healthy` et Frigate lit la caméra (images par seconde > 0) ;
  2. le propriétaire crée le compte HA, installe l'intégration Frigate via HACS et ajoute
     l'intégration ntfy ;
  3. un claquement de mains donne une alerte « bruit », un geste devant la caméra une alerte
     « mouvement », la caméra débranchée 2 min une alerte « hors ligne » ;
  4. le direct avec le son s'ouvre dans le navigateur du téléphone après la connexion Authelia.
