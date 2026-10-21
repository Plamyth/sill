#!/usr/bin/env python3
"""격리 테스트 빌드 전용 공개 설정. 실제 소유 Mac이나 키를 사용하지 않는다."""
import argparse
import hashlib
import json
import os
from pathlib import Path


def write_fixture(directory):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'OwnerBootstrapFixture.json'
    value = {'schema': 'ccr.owner-mac-bootstrap/v1', 'macID': '0' * 16,
             'fingerprint': 'A' * 43, 'addresses': ['100.64.0.1'], 'remotePort': 1}
    data = (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if path.is_symlink() or (path.exists() and path.read_bytes() != data):
        raise ValueError('다른 기존 테스트 프로필을 덮어쓸 수 없습니다.')
    if not path.exists():
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as target:
            target.write(data)
    return {'path': str(path), 'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    print(json.dumps(write_fixture(parser.parse_args().directory), sort_keys=True))
