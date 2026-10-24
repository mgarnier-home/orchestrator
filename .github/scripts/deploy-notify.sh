#!/usr/bin/env bash
# Publie sur ntfy le résultat d'un déploiement : succès ou échec global dans l'icône du titre,
# une ligne ✅ / ❌ par stack, et les dernières lignes de log des stacks en échec.
#
# Le dossier de résultats est écrit par l'étape « Restart updated stacks » de deploy.yaml :
#   results       une ligne « <stack> <success|failure> » par stack redéployée
#   <stack>.log   sortie de `orchestrator restart <stack>`
#
# Exemple de test sans envoi :
#   mkdir -p /tmp/deploy && echo "media failure" > /tmp/deploy/results && echo "boom" > /tmp/deploy/media.log
#   .github/scripts/deploy-notify.sh --dry-run failure /tmp/deploy

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage : deploy-notify.sh [options] <status> <results-dir>

  status       success | failure | cancelled (job.status du workflow)
  results-dir  dossier contenant results et les <stack>.log (peut ne pas exister)

Options :
  --server <hôte>   serveur ntfy, avec ou sans schéma (https:// par défaut)
  --topic <topic>   topic ntfy
  --run-url <url>   lien vers le run GitHub Actions (bouton et clic)
  --commit <sha>    commit déployé (HEAD par défaut)
  --dry-run         affiche la requête au lieu de l'envoyer
EOF
  exit 1
}

server=""
topic=""
run_url=""
commit=HEAD
dry_run=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --server | --topic | --run-url | --commit)
      [ $# -ge 2 ] || { echo "$1 attend une valeur" >&2; usage; }
      case "$1" in
        --server) server=$2 ;;
        --topic) topic=$2 ;;
        --run-url) run_url=$2 ;;
        --commit) commit=$2 ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage ;;
    -*) echo "Option inconnue : $1" >&2; usage ;;
    *) args+=("$1"); shift ;;
  esac
done
[ ${#args[@]} -eq 2 ] || usage
status=${args[0]}
results_dir=${args[1]}
case "$status" in
  success | failure | cancelled) ;;
  *) echo "Status inconnu : $status" >&2; usage ;;
esac

if [ "$dry_run" = "1" ]; then
  server=${server:-ntfy.invalid}
  topic=${topic:-dry-run}
fi
[ -n "$server" ] && [ -n "$topic" ] || { echo "--server et --topic sont requis" >&2; usage; }

# Les logs vont sur stderr : en --dry-run, stdout ne contient que la requête.
log() { echo "[deploy-notify] $*" >&2; }

# Sans schéma, https : en http, Traefik répond par une redirection que curl ne suit pas.
ntfy_url="${server%/}"
[[ "$ntfy_url" == *://* ]] || ntfy_url="https://$ntfy_url"

log "statut du workflow : $status, résultats : $results_dir, ntfy : $ntfy_url, topic : $topic, dry-run : $dry_run"

stacks=()
lines=()
failed=0
if [ -f "$results_dir/results" ]; then
  while read -r stack result; do
    [ -n "$stack" ] || continue
    stacks+=("$stack")
    log "stack $stack : $result"
    if [ "$result" = "success" ]; then
      lines+=("✅ $stack")
    else
      failed=1
      lines+=("❌ $stack")
      if [ -s "$results_dir/$stack.log" ]; then
        # En cas d'erreur, cobra affiche l'aide de la commande après le message : on coupe au
        # « Usage: » pour garder l'erreur elle-même. Couleurs ANSI retirées : ntfy affiche le
        # texte brut.
        lines+=("$(sed -E -e '/^Usage:/,$d' -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$results_dir/$stack.log" | tail -n 10)" "")
      fi
    fi
  done <"$results_dir/results"
else
  log "aucun fichier results : le workflow s'est arrêté avant le redéploiement des stacks"
fi

case "$status" in
  cancelled) lines+=("Déploiement annulé.") ;;
  failure) [ ${#stacks[@]} -gt 0 ] || lines+=("Le workflow a échoué avant le redéploiement des stacks.") ;;
esac
[ "$status" = "success" ] && [ "$failed" = "0" ] && tag=white_check_mark || tag=x

if [ ${#stacks[@]} -gt 0 ]; then
  joined=$(IFS=,; echo "${stacks[*]}")
  title="Deploy ${joined//,/, }"
else
  title="Deploy"
fi

message=$(printf '%s\n' "${lines[@]}")
message+=$'\n\n'"$(git log -1 --format='%s%nBy %an' "$commit")"

actions='[]'
if [ -n "$run_url" ]; then
  actions=$(jq -n --arg url "$run_url" '[{action: "view", label: "🔎 View run", url: $url}]')
fi

body=$(jq -n \
  --arg topic "$topic" \
  --arg title "$title" \
  --arg message "$message" \
  --arg tag "$tag" \
  --arg click "$run_url" \
  --argjson actions "$actions" \
  '{topic: $topic, title: $title, message: $message, tags: [$tag], actions: $actions}
    + if $click != "" then {click: $click} else {} end')

log "notification : « $title », tag $tag"

if [ "$dry_run" = "1" ]; then
  log "dry-run : POST $ntfy_url/ non envoyé"
  echo "POST $ntfy_url/"
  jq . <<<"$body"
  exit 0
fi

response=$(mktemp)
code=$(curl -sS -o "$response" -w '%{http_code}' -X POST -H "Content-Type: application/json" --data "$body" "$ntfy_url/")
log "réponse ntfy : HTTP $code $(jq -c '{id, event, topic}' "$response" 2>/dev/null || head -c 300 "$response")"
rm -f "$response"
[[ "$code" == 2* ]] || { log "échec : ntfy n'a pas accepté la requête"; exit 1; }
