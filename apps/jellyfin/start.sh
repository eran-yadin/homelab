#!/usr/bin/env bash
# Start, then two things the install alone did not finish:
#  1. the media folder exists, with Movies/Shows/Music, and belongs to you
#     (it was created by docker as root, so nothing could be copied into it);
#  2. with a GPU passed in, Jellyfin is told to USE it. Passing /dev/dri only
#     makes the chip visible; Jellyfin's own setting stays "none" and every
#     transcode runs on the CPU. Set once (marker file), so a later choice made
#     in Jellyfin's dashboard is left alone.
set -euo pipefail
# shellcheck disable=SC1091
. "$HOMELAB_ROOT/lib/contract.sh"

set +e; bash "$HOMELAB_ROOT/lib/kinds/compose.sh" start; rc=$?; set -e
[ "$rc" = 0 ] || [ "$rc" = "$EX_NOOP" ] || exit "$rc"

media="$($SUDO sed -n 's/^MEDIA_DIR=//p' "$APP_STATE/.env" 2>/dev/null || true)"; media="${media:-/srv/media}"
for d in "$media" "$media/Movies" "$media/Shows" "$media/Music"; do
    if ! [ -d "$d" ]; then run $SUDO mkdir -p "$d"; fi
done
if [ "$(stat -c %U "$media" 2>/dev/null || true)" = root ]; then
    log "jellyfin: $media belongs to root; giving it to $(owner_user) so media can be copied in"
    run $SUDO chown "$(owner_user):$(owner_group)" "$media" "$media/Movies" "$media/Shows" "$media/Music"
fi

dk_resolve || true
marker="$APP_STATE/.hwaccel-set"
if [ -e /dev/dri/renderD128 ] && ! $SUDO test -e "$marker" && [ "${#DK[@]}" -gt 0 ]; then
    vol="$("${DK[@]}" volume inspect -f '{{.Mountpoint}}' jellyfin_config 2>/dev/null || true)"
    xml="$vol/config/encoding.xml"
    if [ -n "$vol" ] && $SUDO test -f "$xml"; then
        if $SUDO grep -q '<HardwareAccelerationType>none</HardwareAccelerationType>' "$xml"; then
            log "jellyfin: turning on Intel QuickSync transcoding (it was set to none)"
            # QSV on /dev/dri/renderD128; decode what a 7th-gen+ Intel iGPU can.
            run_sh "$SUDO python3 - '$xml' <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('<HardwareAccelerationType>none</HardwareAccelerationType>', '<HardwareAccelerationType>qsv</HardwareAccelerationType>')
codecs = ''.join('<string>%s</string>' % c for c in ['h264', 'hevc', 'mpeg2video', 'vc1', 'vp8', 'vp9'])
if re.search(r'<HardwareDecodingCodecs\s*/>', s):
    s = re.sub(r'<HardwareDecodingCodecs\s*/>', '<HardwareDecodingCodecs>%s</HardwareDecodingCodecs>' % codecs, s)
elif re.search(r'<HardwareDecodingCodecs>.*?</HardwareDecodingCodecs>', s, re.S):
    s = re.sub(r'<HardwareDecodingCodecs>.*?</HardwareDecodingCodecs>', '<HardwareDecodingCodecs>%s</HardwareDecodingCodecs>' % codecs, s, flags=re.S)
open(p, 'w').write(s)
PY"
            run "${DK[@]}" restart jellyfin >/dev/null
            ok "jellyfin: hardware transcoding on (Dashboard > Playback > Transcoding shows Intel QuickSync)"
        fi
        run_sh "$SUDO touch '$marker'"
    fi
fi
exit "$rc"
