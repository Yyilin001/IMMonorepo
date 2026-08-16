#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
status=0

while IFS= read -r -d '' document; do
  [[ -f "${repo_root}/${document}" ]] || continue
  while IFS= read -r target; do
    case "${target}" in
      ''|http://*|https://*|mailto:*|app://*|\#*) continue ;;
    esac

    target="${target%%#*}"
    [[ -n "${target}" ]] || continue
    resolved="$(cd "${repo_root}/$(dirname "${document}")" && pwd)/${target}"
    if [[ ! -e "${resolved}" ]]; then
      printf 'broken Markdown link: %s -> %s\n' "${document}" "${target}" >&2
      status=1
    fi
  done < <(
    perl -ne '
      while (/(?<!!)\[[^]]*\]\((<[^>]+>|[^()[:space:]]+)(?:[[:space:]]+["'\''\x27][^)]*["'\''\x27])?\)/g) {
        $target = $1;
        $target =~ s/^<|>$//g;
        print "$target\n";
      }
    ' "${repo_root}/${document}"
  )
done < <(git -C "${repo_root}" ls-files -z '*.md')

retired_references=(
  implementation-review-and-roadmap.md
  10-round-code-analysis.md
  test_v2_local_schema_migrations.sh
  check_v2_sql_migration_manifest.sh
  migration-manifest.sha256
  migration-baseline.lock.sha256
)
for retired_reference in "${retired_references[@]}"; do
  if rg -l -F --glob '*.md' --glob '!IMV2/docs/legacy-cleanup-plan.md' \
      -- "${retired_reference}" "${repo_root}" >/dev/null; then
    printf 'retired documentation reference remains: %s\n' "${retired_reference}" >&2
    status=1
  fi
done

if [[ "${status}" -ne 0 ]]; then
  exit "${status}"
fi

printf 'V2 Markdown links and retired-reference contract passed.\n'
