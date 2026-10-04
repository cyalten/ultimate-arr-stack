#!/usr/bin/env bats
# Unit tests for scripts/queue-cleanup.sh: a download Sonarr or Radarr matched
# by ID and won't import on its own is left in the queue and named in the
# weekly notice, while every other blocked import is still removed.
#
# The sweep used to treat every importBlocked item as dead. A release grabbed
# by ID whose name Sonarr can't recognise (eight Netflix episodes of a Korean
# show, named by its romanised title, on 2026-10-04) finishes as a good file
# that only needs a manual import. Removing it blocklisted that release and
# threw the download away.
#
# `docker` and `curl` are stubbed on PATH, and the script runs from a copy in a
# throwaway stack directory with no .env. The curl stub serves each app's queue
# from a fixture and logs every call, with its body, to $CURL_LOG.

setup() {
    load helpers/setup
    command -v python3 >/dev/null || skip "python3 not installed"
    unset HA_WEBHOOK_URL

    STACK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$STACK/scripts"
    cp "$REPO_ROOT/scripts/queue-cleanup.sh" "$STACK/scripts/queue-cleanup.sh"

    export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    export HA_NOTICE="$BATS_TEST_TMPDIR/notice.json"
    export SONARR_QUEUE="$BATS_TEST_TMPDIR/sonarr-queue.json"
    export RADARR_QUEUE="$BATS_TEST_TMPDIR/radarr-queue.json"
    : > "$CURL_LOG"

    # Sonarr: one season-pack download matched by ID (a queue record per
    # episode), and one blocked import that is genuinely dead.
    cat > "$SONARR_QUEUE" <<'JSON'
{"totalRecords": 3, "records": [
  {"id": 1, "seriesId": 85, "status": "completed", "trackedDownloadStatus": "warning",
   "trackedDownloadState": "importBlocked", "size": 100, "sizeleft": 0,
   "title": "Pohaenjeu.S01.1080p.NF.WEB-DL.AAC2.0.H.264-playWEB",
   "statusMessages": [{"title": "Pohaenjeu.S01.1080p.NF.WEB-DL.AAC2.0.H.264-playWEB", "messages": [
     "Found matching series via grab history, but release was matched to series by ID. Automatic import is not possible. See the FAQ for details."]}]},
  {"id": 2, "seriesId": 85, "status": "completed", "trackedDownloadStatus": "warning",
   "trackedDownloadState": "importBlocked", "size": 100, "sizeleft": 0,
   "title": "Pohaenjeu.S01.1080p.NF.WEB-DL.AAC2.0.H.264-playWEB",
   "statusMessages": [{"title": "Pohaenjeu.S01.1080p.NF.WEB-DL.AAC2.0.H.264-playWEB", "messages": [
     "Found matching series via grab history, but release was matched to series by ID. Automatic import is not possible. See the FAQ for details."]}]},
  {"id": 3, "seriesId": 12, "status": "completed", "trackedDownloadStatus": "warning",
   "trackedDownloadState": "importBlocked", "size": 100, "sizeleft": 0,
   "title": "Slow.Horses.S06E03.1080p.WEB.h264-CAKES",
   "statusMessages": [{"title": "Slow.Horses.S06E03.1080p.WEB.h264-CAKES", "messages": [
     "Not an upgrade for existing episode file(s). Existing quality: WEBDL-2160p. New Quality WEBDL-1080p."]}]}
]}
JSON

    # Radarr: one film matched by ID, in Radarr's own wording.
    cat > "$RADARR_QUEUE" <<'JSON'
{"totalRecords": 1, "records": [
  {"id": 7, "movieId": 40, "status": "completed", "trackedDownloadStatus": "warning",
   "trackedDownloadState": "importBlocked", "size": 100, "sizeleft": 0,
   "title": "Eojjeolsuga.Eopda.2025.1080p.WEB-DL-GRP",
   "statusMessages": [{"title": "Eojjeolsuga.Eopda.2025.1080p.WEB-DL-GRP", "messages": [
     "Found matching movie via grab history, but release was matched to movie by ID. Manual Import required."]}]}
]}
JSON

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    cat > "$STUB_BIN/docker" <<'STUB'
#!/bin/bash
case "$1" in
  ps) printf '%s\n' gluetun sonarr radarr ;;
  exec) printf '<Config>\n  <Port>8989</Port>\n  <ApiKey>key-%s</ApiKey>\n</Config>\n' "$2" ;;
  *) exit 1 ;;
esac
STUB
    cat > "$STUB_BIN/curl" <<'STUB'
#!/bin/bash
method=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d|--data-binary) data="$2"; shift 2 ;;
    -H|-m) shift 2 ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
printf '%s %s %s\n' "$method" "$url" "$data" >> "$CURL_LOG"
case "$method $url" in
  "GET http://localhost:8989/api/v3/queue"*) cat "$SONARR_QUEUE" ;;
  "GET http://localhost:7878/api/v3/queue"*) cat "$RADARR_QUEUE" ;;
  "POST http://ha.test/"*) printf '%s' "$data" > "$HA_NOTICE" ;;
esac
STUB
    chmod +x "$STUB_BIN/docker" "$STUB_BIN/curl"
    export PATH="$STUB_BIN:$PATH"
}

# The value of one key in the notice the script posted to Home Assistant.
notice() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$HA_NOTICE" "$1"
}

@test "a dry run lists downloads matched by ID and would remove only the dead one" {
    run "$STACK/scripts/queue-cleanup.sh"
    assert_success
    assert_output --partial "Left for manual import: Pohaenjeu.S01"
    assert_output --partial "Left for manual import: Eojjeolsuga.Eopda.2025"
    assert_output --partial "Would remove: Slow.Horses.S06E03"
    refute_output --partial "Would remove: Pohaenjeu"
    refute_output --partial "Would remove: Eojjeolsuga"
    # A season pack is a queue record per episode, but one download.
    [ "$(grep -c 'Left for manual import: Pohaenjeu' <<< "$output")" -eq 1 ]
}

@test "--apply never removes a download matched by ID or searches its series again" {
    run "$STACK/scripts/queue-cleanup.sh" --apply
    assert_success
    grep -q '^DELETE http://localhost:8989/api/v3/queue/3?' "$CURL_LOG"
    run grep -E '^DELETE .*/queue/(1|2|7)\?' "$CURL_LOG"
    assert_failure
    grep -q '"seriesId": 12' "$CURL_LOG"
    run grep -E '"seriesId": 85|"movieIds": \[40\]' "$CURL_LOG"
    assert_failure
}

@test "the weekly notice names the downloads waiting for a manual import, as a warning" {
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    run "$STACK/scripts/queue-cleanup.sh" --apply
    assert_success
    [ "$(notice level)" = warning ]
    [ "$(notice title)" = "Still needs manual import: 2 downloads" ]
    run notice message
    assert_output --partial "Pohaenjeu.S01.1080p.NF.WEB-DL.AAC2.0.H.264-playWEB"
    assert_output --partial "Eojjeolsuga.Eopda.2025.1080p.WEB-DL-GRP"
    assert_output --partial "Open Radarr / Sonarr → Activity → Queue and import them."
}

@test "with nothing waiting, the weekly notice stays a routine info note" {
    export HA_WEBHOOK_URL="http://ha.test/api/webhook/test"
    printf '{"totalRecords": 0, "records": []}\n' > "$RADARR_QUEUE"
    python3 - "$SONARR_QUEUE" <<'PY'
import json, sys
q = json.load(open(sys.argv[1]))
q["records"] = [r for r in q["records"] if r["id"] == 3]
q["totalRecords"] = 1
json.dump(q, open(sys.argv[1], "w"))
PY
    run "$STACK/scripts/queue-cleanup.sh" --apply
    assert_success
    [ "$(notice level)" = info ]
    [ "$(notice title)" = "Queue Cleanup" ]
}
