#!/bin/sh
set -eu
: "${CCR_OWNER_MAC_BOOTSTRAP_PROFILE:?승인된 외부 공개 프로필의 절대 경로가 필요합니다}"
: "${CCR_OWNER_MAC_BOOTSTRAP_SHA256:?승인된 공개 프로필의 SHA-256이 필요합니다}"
case "$CCR_OWNER_MAC_BOOTSTRAP_PROFILE" in /*) ;; *) echo '공개 프로필은 절대 경로여야 합니다.' >&2; exit 1 ;; esac
root="$(cd "${SRCROOT:?}/.." && pwd -P)"
case "$CCR_OWNER_MAC_BOOTSTRAP_PROFILE" in "$root"/*) echo '개인 Mac 프로필은 저장소 밖에서 공급하세요.' >&2; exit 1 ;; esac
exec /usr/bin/python3 "$root/Scripts/provision-owner-bootstrap.py" \
    --profile "$CCR_OWNER_MAC_BOOTSTRAP_PROFILE" \
    --profile-sha256 "$CCR_OWNER_MAC_BOOTSTRAP_SHA256" \
    --output "${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/CCR-OwnerMacBootstrap.json"
