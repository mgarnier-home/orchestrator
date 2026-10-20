# orchestrator

Fichiers Docker Compose de tous les services du homelab. Chaque dossier est une stack, chaque
fichier décrit cette stack sur un hôte.

## Déploiement

- Un push sur `main` lance `.github/workflows/deploy.yaml`, qui redémarre chaque stack dont un
  fichier a changé. **Pousser, c'est déployer.**
- Renovate ouvre une PR par stack et la fusionne automatiquement, donc la déploie.
- Tu ne déploies jamais toi-même sans demande explicite, ni par `git push`, ni par
  `orchestrator-cli`.

## Commandes

| Action                                | Commande                                              |
| ------------------------------------- | ----------------------------------------------------- |
| Valider tous les fichiers compose     | `orchestrator-cli lint`                               |
| Agir sur une stack d'un hôte          | `orchestrator-cli <up\|down\|restart> <stack> <hôte>` |
| Agir sur une stack, tous les hôtes    | `orchestrator-cli <up\|down\|restart> <stack>`        |
| Agir sur un seul service d'une stack  | ajouter `--service <nom>`                             |

L'ordre des trois mots est libre (`orchestrator-cli athena media restart` fonctionne aussi).
`lint` est libre ; `up`, `down` et `restart` demandent un accord.

## Écrire un service

- Fichier : `<stack>/<hôte>.<stack>.yml`, avec `name: <stack>` en tête. Un fichier nommé
  autrement est ignoré par la CLI.
- Image : registre explicite, version et digest (`docker.io/org/image:1.2.3@sha256:…`). Jamais
  `latest`.
- `container_name` explicite et `restart: unless-stopped`.
- Données persistantes : volume externe `docker-data` avec `subpath: <stack>/<service>/…`. Le
  dossier correspondant est sous `/mnt/docker-data`.
- Port publié : `${<HÔTE>_<SERVICE>_PORT}:<port du conteneur>`, variable définie dans
  `/mnt/secrets/ports.env`. Plages : zephyr 10000, apollon 11000, athena 12000, atlas 13000.
- Secrets et configuration : `${VARIABLE}`, jamais de valeur en dur. Les variables viennent des
  fichiers `.env` à la racine de `/mnt/secrets` et de `/mnt/secrets/<stack>/`.
- Un `healthcheck` quand l'image offre de quoi en faire un.

```yaml
name: utils

services:
  ntfy:
    image: docker.io/binwiederhier/ntfy:v2.28.0@sha256:6ef4b819f722fccdc036af611c4774cfdc2de821ab74fdd48bbf4c9d6f8973da
    container_name: ntfy
    restart: unless-stopped
    ports:
      - ${APOLLON_NTFY_PORT}:80
    volumes:
      - type: volume
        source: docker-data
        volume:
          subpath: utils/ntfy
        target: /etc/ntfy
    labels:
      traefik-conf.port: ${APOLLON_NTFY_PORT}

volumes:
  docker-data:
    external: true
```

## Exposition

- `traefik-conf.port: ${…_PORT}` suffit pour qu'un service soit routé par Traefik (sur apollon).
  `traefik-conf.name` change le sous-domaine.
- Par défaut un service reçoit la liste d'IP autorisées (`ip-wl`), le géoblocage (`geoblock`) et
  Authelia. **Rien n'est public** : les services ne sont joignables que depuis quelques IP
  définies.
- Toute exception (routeur explicite `traefik-conf.http.routers.<nom>.*`, autre chaîne de
  middlewares, service public) se décide avec le propriétaire. Ne la propose pas de toi-même
  comme allant de soi.

## Ajouter un service ou une stack

1. Demande sur quel hôte le placer.
2. Choisis le prochain port libre dans la plage de l'hôte et annonce-le, avec toutes les autres
   variables à créer, avant toute écriture dans `/mnt/secrets`.
3. Pour une nouvelle stack, ajoute-la dans `.github/renovate.json` : dans l'alternance de
   `managerFilePatterns` et dans une règle `packageRules` à son nom.

## Définition de « terminé »

`orchestrator-cli lint` passe. Le déploiement ne fait pas partie de « terminé » : il se fait sur
demande.
