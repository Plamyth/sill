import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile

root = Path(__file__).resolve().parents[3]
script = root / "Scripts/provision-owner-bootstrap.py"
spec = importlib.util.spec_from_file_location("provision_owner_bootstrap", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fingerprint = base64.urlsafe_b64encode(bytes(32)).decode().rstrip("=")
value = {"schema": module.SCHEMA, "macID": "0" * 16, "fingerprint": fingerprint,
         "addresses": ["100.64.1.2", "fd7a:115c:a1e0::2"], "remotePort": 7455}
count = 0


def reject(operation):
    global count
    try:
        operation()
    except (ValueError, TypeError, OSError):
        count += 1
    else:
        raise AssertionError("invalid provisioning was accepted")


with tempfile.TemporaryDirectory(prefix="ccr-owner-provision-") as scratch:
    folder = Path(scratch).resolve()
    profile = folder / "public.json"
    data = json.dumps(value).encode()
    profile.write_bytes(data)
    profile.chmod(0o600)
    digest = hashlib.sha256(data).hexdigest()
    output = folder / "staged.app" / module.RESOURCE
    receipt = module.provision(profile, digest, output)
    assert output.read_bytes() == data and receipt["requiresAppCodeSign"]
    count += 1
    assert module.provision(profile, digest, output) == receipt
    count += 1
    reject(lambda: module.provision(profile, "0" * 64, folder / "bad.app" / module.RESOURCE))
    reject(lambda: module.provision(profile, digest, folder / "other.json"))
    changed = folder / "changed.app" / module.RESOURCE
    changed.parent.mkdir()
    changed.write_bytes(b"unchanged")
    reject(lambda: module.provision(profile, digest, changed))
    assert changed.read_bytes() == b"unchanged"
    count += 1
    link = folder / "link.json"
    link.symlink_to(profile)
    reject(lambda: module.provision(link, digest, folder / "link.app" / module.RESOURCE))
    reject(lambda: module.provision(profile, digest, Path("/Applications/test.app") / module.RESOURCE))
    profile.chmod(0o622)
    reject(lambda: module.provision(profile, digest, folder / "writable.app" / module.RESOURCE))
    profile.chmod(0o600)
    for field, bad in [("token", "secret"), ("remotePort", True), ("macID", "1" * 16),
                       ("fingerprint", fingerprint + "="), ("addresses", ["192.168.1.2"]),
                       ("addresses", ["100.64.01.2"]), ("addresses", ["[fd7a:115c:a1e0::2]"]),
                       ("addresses", ["fd7a:115c:a1e0::2%en0"]),
                       ("addresses", ["100.64.1.2", "100.64.1.2"]), ("addresses", [None])]:
        invalid = dict(value)
        invalid[field] = bad
        reject(lambda: module.validate(json.dumps(invalid).encode()))
    reject(lambda: module.validate(b" " * 4097))
    reject(lambda: module.validate(data[:-1] + b',"remotePort":7455}'))
print(f"PASS {count} staging-only public resource provisioning checks; no signing, socket or device effects")
