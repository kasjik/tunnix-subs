# Tunnix subscription list

Every Monday a GitHub Action searches GitHub for free proxy subscription
links, tests them, scores how stable they've been across runs and publishes
the best to [`subscriptions.json`](subscriptions.json). The Tunnix app
downloads that file, so it keeps finding working servers without app updates.

## How it stays alive on its own

- **Weekly schedule** (`.github/workflows/update.yml`), plus a manual
  "Run workflow" button on the Actions tab.
- **Keepalive:** each run commits `state.json`. GitHub disables schedules in
  repos with no activity for 60 days; these commits count as activity.
- **Self-healing:** links are scored over their last 6 runs. A link failing
  3 runs in a row is dropped and replaced. One bad day doesn't remove a good
  link, and a run that finds nothing never overwrites a working list.
- **Seeds** (`seeds.json`) are always tested and, when working, always
  published, as a safety net.

## Files

| File | What it is |
| --- | --- |
| `subscriptions.json` | The published list the app reads. |
| `state.json` | Score history per link (written by the Action). |
| `seeds.json` | Links you always want considered. Edit freely. |
| `bin/find_subs.dart` | Search, test and scoring logic. |
| `lib/parsers.dart`, `lib/proxy_node.dart` | Copied from the app (run `tool/sync_subs_repo.sh` in the app project after changing the app's parser). |

## Tuning

At the top of `bin/find_subs.dart`: `publishCount` (links published, 8),
`perRepoLimit` (max links per repository, 2), `dropAfterFails` (3),
`searchQueries` (what to search for).

To block a source, add its repository to `blockedRepos` in
`bin/find_subs.dart`.

## Run locally

```sh
dart pub get
MAX_REPOS=6 dart run bin/find_subs.dart
```
