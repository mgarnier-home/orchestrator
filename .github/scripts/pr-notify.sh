#!/usr/bin/env bash
# Publie sur ntfy l'état d'une PR : résumé des images modifiées par hôte, état de la CI dans
# l'icône du titre, bouton « Accept PR » (review APPROVE) uniquement quand la CI est verte.
# Toutes les publications d'une même PR portent le même sequence_id : chacune remplace la
# précédente sur les clients ntfy.
#
# Le script doit tourner dans un clone contenant les commits base.sha et head.sha de la PR.
#
# Exemple de test sans envoi :
#   gh api repos/mgarnier-home/orchestrator/pulls/134 > /tmp/pr.json
#   .github/scripts/pr-notify.sh --dry-run success /tmp/pr.json

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage : pr-notify.sh [options] <status> <pr.json>

  status    pending | success | failure | closed
  pr.json   PR telle que renvoyée par GET /repos/{repo}/pulls/{n}

Options :
  --server <hôte>   serveur ntfy, avec ou sans schéma (https:// par défaut)
  --topic <topic>   topic ntfy
  --token <pat>     PAT GitHub (Pull requests: write), requis quand status=success
  --dry-run         affiche la requête au lieu de l'envoyer (jeton masqué)
EOF
  exit 1
}

server=""
topic=""
token=""
dry_run=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --server | --topic | --token)
      [ $# -ge 2 ] || { echo "$1 attend une valeur" >&2; usage; }
      case "$1" in
        --server) server=$2 ;;
        --topic) topic=$2 ;;
        --token) token=$2 ;;
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
pr_json=${args[1]}
case "$status" in
  pending | success | failure | closed) ;;
  *) echo "Status inconnu : $status" >&2; usage ;;
esac

if [ "$dry_run" = "1" ]; then
  server=${server:-ntfy.invalid}
  topic=${topic:-dry-run}
  token=${token:-dry-run-token}
fi
[ -n "$server" ] && [ -n "$topic" ] || { echo "--server et --topic sont requis" >&2; usage; }

# Les logs vont sur stderr : en --dry-run, stdout ne contient que la requête.
log() { echo "[pr-notify] $*" >&2; }

# Sans schéma, https : en http, Traefik répond par une redirection 301 que curl ne suit pas,
# et la notification n'arrive jamais.
ntfy_url="${server%/}"
[[ "$ntfy_url" == *://* ]] || ntfy_url="https://$ntfy_url"

pr() { jq -r "$1" "$pr_json"; }

repo=$(pr '.base.repo.full_name')
number=$(pr '.number')
sequence_id="${repo##*/}-pr-${number}"

log "PR $repo#$number, statut demandé : $status, sequence_id : $sequence_id"
log "ntfy : $ntfy_url, topic : $topic, dry-run : $dry_run, token : $([ -n "$token" ] && echo fourni || echo absent)"

send() {
  local method=$1 url=$2 body=${3:-}
  if [ "$dry_run" = "1" ]; then
    log "dry-run : $method $url non envoyé"
    echo "$method $url"
    [ -n "$body" ] && jq '(.actions[]? | select(.headers.Authorization) | .headers.Authorization) = "Bearer ***"' <<<"$body"
    return 0
  fi

  local response code
  response=$(mktemp)
  log "envoi : $method $url"
  if [ -n "$body" ]; then
    code=$(curl -sS -o "$response" -w '%{http_code}' -X "$method" -H "Content-Type: application/json" --data "$body" "$url")
  else
    code=$(curl -sS -o "$response" -w '%{http_code}' -X "$method" "$url")
  fi
  # Seuls l'identifiant et l'événement sont journalisés : la réponse reprend les boutons, donc le token.
  log "réponse ntfy : HTTP $code $(jq -c '{id, event, topic, sequence_id}' "$response" 2>/dev/null || head -c 300 "$response")"
  rm -f "$response"
  [[ "$code" == 2* ]] || { log "échec : ntfy n'a pas accepté la requête"; exit 1; }
}

if [ "$status" = "closed" ]; then
  send DELETE "$ntfy_url/$topic/$sequence_id"
  exit 0
fi

base=$(git merge-base "$(pr '.base.sha')" "$(pr '.head.sha')")
head=$(pr '.head.sha')
mapfile -t changed_files < <(git diff --name-only "$base" "$head")
log "comparaison $base..$head : ${#changed_files[@]} fichier(s) modifié(s)"
for file in "${changed_files[@]}"; do log "  $file"; done

# Lint ne tourne pas sur une PR qui ne touche que ces chemins (paths-ignore de lint.yml) :
# aucune CI à attendre, la PR est prête.
if [ "$status" = "pending" ]; then
  linted=$(printf '%s\n' "${changed_files[@]}" | grep -cvE '^(autoscaler|\.github)/' || true)
  if [ "$linted" -eq 0 ]; then
    log "aucun fichier vérifié par Lint : statut pending -> success"
    status=success
  fi
fi

# Images par service d'un fichier compose à un commit donné ({} si le fichier n'existe pas).
images_at() {
  local commit=$1 file=$2
  if git cat-file -e "$commit:$file" 2>/dev/null; then
    git show "$commit:$file" | yq -o=json '(.services // {}) | map_values(.image // "")'
  else
    echo '{}'
  fi
}

# Une ligne « | service : ancienne > nouvelle » par image modifiée. La version est le tag ; si
# seul le digest change, le digest court est ajouté pour distinguer les deux.
summary=""
for file in "${changed_files[@]}"; do
  [[ "$file" =~ ^[^/]+/([^/.]+)\.[^/]+\.ya?ml$ ]] || continue
  host=${BASH_REMATCH[1]}
  lines=$(jq -rn \
    --argjson old "$(images_at "$base" "$file")" \
    --argjson new "$(images_at "$head" "$file")" '
    def tag: split("@")[0] | if test(":[^/:]+$") then sub(".*:"; "") else "" end;
    def digest: split("@")[1] // "" | sub("^sha256:"; "") | .[0:7];
    def show($other): if tag == ($other | tag) or tag == "" then
        [tag, digest] | map(select(. != "")) | join("@")
      else tag end;
    $new | to_entries[]
      | select(.value != "" and .value != ($old[.key] // ""))
      | ($old[.key] // "") as $before
      | .value as $after
      | "| \(.key) : \(if $before == "" then "none" else ($before | show($after)) end) > \($after | show($before))"')
  if [ -z "$lines" ]; then
    log "$file ($host) : aucune image modifiée"
    continue
  fi
  log "$file ($host) : $(grep -c . <<<"$lines") image(s) modifiée(s)"
  summary+="${summary:+$'\n\n'}$host"$'\n'"$lines"
done

branch=$(pr '.head.ref')
# Les majeures d'une stack ont leur propre branche, préfixée par Renovate : renovate/stack-major-<stack>.
if [[ "$branch" == renovate/stack-major-* ]]; then
  title="Major update to ${branch#renovate/stack-major-}"
elif [[ "$branch" == renovate/stack-* ]]; then
  title="Update to ${branch#renovate/stack-}"
else
  # « chore(deps): update x » -> « Update x »
  title=$(pr '.title | sub("^[a-z]+(\\([^)]*\\))?!?: "; "") | (.[0:1] | ascii_upcase) + .[1:]')
fi

message="${summary:-Aucune image modifiée}"$'\n\n'"By $(pr '.user.login')"

case "$status" in
  pending) tag=hourglass_flowing_sand ;;
  success) tag=white_check_mark ;;
  failure) tag=x ;;
esac

url=$(pr '.html_url')
actions=$(jq -n --arg url "$url" '[{action: "view", label: "🌐 View PR", url: $url}]')
if [ "$status" = "success" ]; then
  [ -n "$token" ] || { log "--token est requis pour le bouton Accept PR"; exit 1; }
  actions=$(jq \
    --arg url "https://api.github.com/repos/$repo/pulls/$number/reviews" \
    --arg token "$token" '
    [{
      action: "http",
      label: "✅ Accept PR",
      url: $url,
      method: "POST",
      headers: {
        Authorization: "Bearer \($token)",
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
      },
      body: "{\"event\":\"APPROVE\"}",
      clear: true
    }] + .' <<<"$actions")
fi

body=$(jq -n \
  --arg topic "$topic" \
  --arg sequence_id "$sequence_id" \
  --arg title "$title" \
  --arg message "$message" \
  --arg tag "$tag" \
  --arg click "$url" \
  --argjson actions "$actions" \
  '{topic: $topic, sequence_id: $sequence_id, title: $title, message: $message,
    tags: [$tag], click: $click, actions: $actions}')

log "notification : « $title », tag $tag, boutons : $(jq -r 'map(.label) | join(", ")' <<<"$actions")"
send POST "$ntfy_url/" "$body"
