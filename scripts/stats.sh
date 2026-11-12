#!/bin/bash
# Usage numbers from GitHub's own download counters. ClamDown sends nothing; these are the counts
# GitHub keeps for every release file.
#   ClamDown.dmg  downloads of the disk image: new installs, plus updates installed through Sparkle
#   appcast.xml   update checks. An installed copy checks once a day while it runs, so checks per day
#                 while a release was the latest one is roughly the number of copies in use each day.
# Needs the GitHub CLI (gh). Usage: scripts/stats.sh
set -euo pipefail

gh api repos/delef/ClamDown/releases --paginate --jq '
  [ .[] | select(.draft | not) | select(.prerelease | not) ]
  | sort_by(.published_at)
  | . as $all
  | to_entries
  | map(
      .value as $r
      | ($all[.key + 1].published_at // null) as $next
      | (($r.published_at | fromdateiso8601) as $from
         | (if $next then ($next | fromdateiso8601) else now end) as $to
         | (($to - $from) / 86400)) as $days
      | ([$r.assets[] | select(.name == "ClamDown.dmg") | .download_count] | add // 0) as $dmg
      | ([$r.assets[] | select(.name == "appcast.xml") | .download_count] | add // null) as $checks
      | [ $r.tag_name,
          ($r.published_at[:10]),
          ($days * 10 | floor / 10 | tostring),
          ($dmg | tostring),
          (if $checks == null then "-" else ($checks | tostring) end),
          (if $checks == null or $days < 1 then "-" else ($checks / $days | floor | tostring) end) ]
      | @tsv)
  | (["release", "published", "days latest", "dmg downloads", "update checks", "checks per day"] | @tsv), .[]
' | column -t -s $'\t'
