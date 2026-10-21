#!/usr/bin/env python3
"""검증된 공개 Mac 설정을 앱 서명 전의 빌드 리소스에 넣는다."""
import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import stat


SCHEMA = "ccr.owner-mac-bootstrap/v1"
RESOURCE = "CCR-OwnerMacBootstrap.json"
FIELDS = {"schema", "macID", "fingerprint", "addresses", "remotePort"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("공개 설정에 중복 필드가 있습니다.")
        result[key] = value
    return result


def validate(data):
    if len(data) > 4096:
        raise ValueError("공개 설정의 크기 한도를 초과했습니다.")
    value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != FIELDS or value["schema"] != SCHEMA:
        raise ValueError("공개 설정의 필드나 버전이 맞지 않습니다.")
    fingerprint = value["fingerprint"]
    if not isinstance(fingerprint, str) or len(fingerprint) != 43:
        raise ValueError("공개 TLS 지문이 맞지 않습니다.")
    key = base64.b64decode(fingerprint + "=", altchars=b"-_", validate=True)
    if len(key) != 32 or base64.urlsafe_b64encode(key).decode().rstrip("=") != fingerprint:
        raise ValueError("공개 TLS 지문이 정규 형식이 아닙니다.")
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    prefix = int.from_bytes(key[:10], "big")
    expected_id = "".join(alphabet[(prefix >> shift) & 31] for shift in range(75, -1, -5))
    if value["macID"] != expected_id:
        raise ValueError("Mac ID와 공개 지문이 일치하지 않습니다.")
    if type(value["remotePort"]) is not int or not 1 <= value["remotePort"] <= 65535:
        raise ValueError("원격 포트가 유효하지 않습니다.")
    addresses = value["addresses"]
    if not isinstance(addresses, list) or not 1 <= len(addresses) <= 8:
        raise ValueError("공개 Tailnet 주소 목록이 유효하지 않습니다.")
    if any(not isinstance(address, str) for address in addresses) or len(set(addresses)) != len(addresses):
        raise ValueError("공개 Tailnet 주소가 중복되거나 잘못되었습니다.")
    for address in addresses:
        ip = ipaddress.ip_address(address)
        network = ipaddress.ip_network("100.64.0.0/10" if ip.version == 4 else "fd7a:115c:a1e0::/48")
        if ip.compressed != address or ip not in network:
            raise ValueError("정규 Tailnet 주소만 사용할 수 있습니다.")
    return value


def regular_path(path):
    path = Path(path).absolute()
    if path.resolve() != path:
        raise ValueError("심볼릭 링크를 통해 연결 설정을 공급할 수 없습니다.")
    return path


def provision(profile, expected_sha256, output):
    profile = regular_path(profile)
    output = regular_path(output)
    if output.name != RESOURCE or output.is_relative_to(Path("/Applications")):
        raise ValueError("서명 전 빌드의 공개 리소스 경로가 필요합니다.")
    with os.fdopen(os.open(profile, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            raise ValueError("공개 설정의 소유자나 쓰기 권한이 맞지 않습니다.")
        data = source.read(4097)
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected_sha256:
        raise ValueError("승인된 공개 설정의 해시와 일치하지 않습니다.")
    validate(data)
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    output = regular_path(output)
    if output.exists():
        if not output.is_file() or output.read_bytes() != data:
            raise ValueError("기존 빌드 리소스가 다릅니다. 새 빌드 경로를 사용하세요.")
    else:
        with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as target:
            target.write(data)
    if hashlib.sha256(output.read_bytes()).hexdigest() != digest:
        raise ValueError("공급된 공개 리소스의 읽기 확인에 실패했습니다.")
    return {"schema": "ccr.owner-bootstrap-provision/v1", "profileSHA256": digest,
            "outputSHA256": digest, "outputPath": str(output), "bytes": len(data),
            "requiresAppCodeSign": True, "deviceCalls": 0, "networkCalls": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--profile-sha256", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        result = provision(args.profile, args.profile_sha256, args.output)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(2, str(error) + "\n")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
