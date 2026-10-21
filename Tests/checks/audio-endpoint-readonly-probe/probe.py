#!/usr/bin/env python3
"""CoreAudio 속성의 읽기 전용 표본. 오디오 데이터나 보호 성공을 측정하지 않는다."""

import argparse
import ctypes as C
import json
import math
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path


MAX_BYTES = 64 * 1024
MAX_DEVICES = 4096
MAX_BUFFERS = 1024
MAX_CHANNELS = 4096
MAX_STRING_UNITS = 16384
SYSTEM = 1
SCOPES = {"global": "glob", "input": "inpt", "output": "outp"}
DEFAULTS = {"input": "dIn ", "output": "dOut", "systemOutput": "sOut"}
CONTROLS = {"mute": ("mute", "bool"), "volumeScalar": ("volm", "scalar"),
            "volumeDecibels": ("vold", "float")}
GLOBALS = {"uid": ("uid ", "string"), "name": ("lnam", "string"),
           "alive": ("livn", "bool"), "transport": ("tran", "uint"),
           "hog": ("oink", "pid"), "isRunningSomewhere": ("gone", "bool"),
           "isRunning": ("goin", "bool")}
ANCHOR_FIELDS = ("uid", "hog", "isRunningSomewhere", "isRunning")


@dataclass(frozen=True)
class Address:
    selector: str
    scope: str = "global"
    element: int = 0


@dataclass
class PropertyObservation:
    has: bool | None = None
    sizeStatus: int | None = None
    getStatus: int | None = None
    settableStatus: int | None = None
    settable: bool | None = None
    value: object = None
    error: list = field(default_factory=list)
    sizeBytes: int | None = None
    returnedSize: int | None = None


@dataclass
class ReadResult:
    status: int
    returned_size: int
    data: bytes | str
    error: str | None = None


class NativeAddress(C.Structure):
    _fields_ = [("selector", C.c_uint32), ("scope", C.c_uint32), ("element", C.c_uint32)]


class AudioBuffer(C.Structure):
    _fields_ = [("channels", C.c_uint32), ("byte_size", C.c_uint32), ("data", C.c_void_p)]


class AudioBufferList(C.Structure):
    _fields_ = [("count", C.c_uint32), ("buffers", AudioBuffer * 1)]


def fourcc(value):
    return int.from_bytes(value.encode("ascii"), "big")


class NativeBackend:
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("네이티브 조회는 macOS에서만 지원합니다.")
        hal = C.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        address = C.POINTER(NativeAddress)
        u32ptr = C.POINTER(C.c_uint32)
        self._has = hal.AudioObjectHasProperty
        self._has.argtypes = [C.c_uint32, address]
        self._has.restype = C.c_ubyte
        self._size = hal.AudioObjectGetPropertyDataSize
        self._size.argtypes = [C.c_uint32, address, C.c_uint32, C.c_void_p, u32ptr]
        self._size.restype = C.c_int32
        self._get = hal.AudioObjectGetPropertyData
        self._get.argtypes = [C.c_uint32, address, C.c_uint32, C.c_void_p, u32ptr, C.c_void_p]
        self._get.restype = C.c_int32
        self._settable = hal.AudioObjectIsPropertySettable
        self._settable.argtypes = [C.c_uint32, address, C.POINTER(C.c_ubyte)]
        self._settable.restype = C.c_int32
        for name, args, result in (
            ("CFGetTypeID", [C.c_void_p], C.c_ulong),
            ("CFStringGetTypeID", [], C.c_ulong),
            ("CFStringGetLength", [C.c_void_p], C.c_long),
            ("CFStringGetMaximumSizeForEncoding", [C.c_long, C.c_uint32], C.c_long),
            ("CFStringGetCString", [C.c_void_p, C.c_void_p, C.c_long, C.c_uint32], C.c_ubyte),
            ("CFRelease", [C.c_void_p], None),
        ):
            function = getattr(self.cf, name)
            function.argtypes = args
            function.restype = result

    @staticmethod
    def _address(address):
        return NativeAddress(fourcc(address.selector), fourcc(SCOPES[address.scope]), address.element)

    def has(self, device, address):
        native = self._address(address)
        return bool(self._has(device, C.byref(native)))

    def get_size(self, device, address):
        native, size = self._address(address), C.c_uint32()
        status = self._size(device, C.byref(native), 0, None, C.byref(size))
        return status, size.value

    def is_settable(self, device, address):
        native, value = self._address(address), C.c_ubyte()
        status = self._settable(device, C.byref(native), C.byref(value))
        return status, bool(value.value)

    def get(self, device, address, size, kind):
        validate_size(size, kind)
        native, used = self._address(address), C.c_uint32(size)
        storage = C.create_string_buffer(max(1, size))
        status = self._get(device, C.byref(native), 0, None, C.byref(used), storage)
        result = ReadResult(status, used.value, b"")
        if status != 0:
            return result
        if kind != "string":
            result.data = storage.raw[:min(size, used.value)]
            return result
        pointer = C.c_void_p.from_buffer(storage).value
        if pointer is None:
            result.error = "CFString 포인터가 비어 있습니다."
            return result
        try:
            if used.value != size:
                raise ValueError("CFString 반환 크기가 요청 크기와 다릅니다.")
            if self.cf.CFGetTypeID(pointer) != self.cf.CFStringGetTypeID():
                raise ValueError("반환 객체가 CFString이 아닙니다.")
            length = self.cf.CFStringGetLength(pointer)
            if not 0 <= length <= MAX_STRING_UNITS:
                raise ValueError("CFString 길이가 상한을 벗어났습니다.")
            encoding = 0x08000100  # kCFStringEncodingUTF8
            capacity = self.cf.CFStringGetMaximumSizeForEncoding(length, encoding) + 1
            if not 1 <= capacity <= MAX_BYTES:
                raise ValueError("UTF-8 변환 버퍼가 상한을 벗어났습니다.")
            text = C.create_string_buffer(capacity)
            if not self.cf.CFStringGetCString(pointer, text, capacity, encoding):
                raise ValueError("CFString UTF-8 변환이 실패했습니다.")
            result.data = text.value.decode("utf-8")
            if len(result.data.encode("utf-16-le")) // 2 != length:
                raise ValueError("CFString 변환 중 문자열이 잘렸습니다.")
        except (ValueError, UnicodeError) as error:
            result.error = str(error)
        finally:
            # Name과 DeviceUID는 SDK 계약상 성공한 get의 호출자 소유다.
            self.cf.CFRelease(pointer)
        return result


def validate_size(size, kind):
    if not isinstance(size, int) or not 0 <= size <= MAX_BYTES:
        raise ValueError("속성 버퍼 크기가 상한을 벗어났습니다.")
    expected = C.sizeof(C.c_void_p) if kind == "string" else 4
    if kind == "ids":
        if size % 4 or size // 4 > MAX_DEVICES:
            raise ValueError("장치 목록 크기가 잘못됐습니다.")
    elif kind == "channels":
        if size != 0 and size < 4:
            raise ValueError("AudioBufferList 헤더가 잘렸습니다.")
    elif size != expected:
        raise ValueError("속성 자료형과 버퍼 크기가 다릅니다.")


def decode(data, kind):
    if kind == "string":
        if not isinstance(data, str) or not data or "\x00" in data:
            raise ValueError("장치 문자열이 비어 있거나 잘못됐습니다.")
        return data
    if kind == "ids":
        ids = [C.c_uint32.from_buffer_copy(data[i:i + 4]).value for i in range(0, len(data), 4)]
        if 0 in ids or len(ids) != len(set(ids)):
            raise ValueError("장치 ID가 0이거나 중복됐습니다.")
        return sorted(ids)
    if kind == "channels":
        if not data:
            return 0
        count = C.c_uint32.from_buffer_copy(data[:4]).value
        offset, stride = AudioBufferList.buffers.offset, C.sizeof(AudioBuffer)
        if count > MAX_BUFFERS or (count and offset + count * stride > len(data)):
            raise ValueError("AudioBufferList 개수 또는 버퍼 경계가 잘못됐습니다.")
        total = 0
        for index in range(count):
            start = offset + index * stride
            buffer = AudioBuffer.from_buffer_copy(data[start:start + stride])
            if buffer.data:
                raise ValueError("StreamConfiguration의 데이터 포인터가 NULL이 아닙니다.")
            total += buffer.channels
            if total > MAX_CHANNELS:
                raise ValueError("실제 채널 합계가 조회 상한을 넘었습니다. 채널을 자르지 않습니다.")
        return total
    ctype = {"pid": C.c_int32, "float": C.c_float, "scalar": C.c_float}.get(kind, C.c_uint32)
    value = ctype.from_buffer_copy(data).value
    if kind in ("float", "scalar") and not math.isfinite(value):
        raise ValueError("음량 값이 NaN 또는 무한대입니다.")
    if kind == "scalar" and not 0 <= value <= 1:
        raise ValueError("VolumeScalar가 0..1 범위를 벗어났습니다.")
    if kind == "bool" and value not in (0, 1):
        raise ValueError("상태 값이 0 또는 1이 아닙니다.")
    return value


def observe(backend, device, address, kind):
    observation = PropertyObservation()

    def error(stage, message):
        observation.error.append({"stage": stage, "message": str(message)})

    try:
        observation.has = backend.has(device, address)
    except (OSError, ValueError) as failure:
        error("has", failure)
        return observation
    if not observation.has:
        return observation
    try:
        status, settable = backend.is_settable(device, address)
        observation.settableStatus = status
        if status == 0:
            observation.settable = settable
        else:
            error("settable", f"OSStatus {status}")
    except (OSError, ValueError) as failure:
        error("settable", failure)
    try:
        status, size = backend.get_size(device, address)
        observation.sizeStatus, observation.sizeBytes = status, size
        if status != 0:
            error("size", f"OSStatus {status}")
            return observation
        validate_size(size, kind)
    except (OSError, ValueError) as failure:
        error("size", failure)
        return observation
    try:
        result = backend.get(device, address, size, kind)
        observation.getStatus, observation.returnedSize = result.status, result.returned_size
        if result.status != 0:
            error("get", f"OSStatus {result.status}")
            return observation
        if result.returned_size != size:
            raise ValueError("조회 중 반환 크기가 변했습니다.")
        if result.error:
            raise ValueError(result.error)
        if kind != "string" and len(result.data) != result.returned_size:
            raise ValueError("반환 데이터와 반환 크기가 다릅니다.")
        observation.value = decode(result.data, kind)
    except (OSError, ValueError, TypeError) as failure:
        error("get", failure)
    return observation


def readable(observation):
    return (observation.has is True and observation.sizeStatus == 0 and observation.getStatus == 0
            and not any(error["stage"] != "settable" for error in observation.error))


def known(observation):
    return readable(observation) and not observation.error


def global_property(backend, device, name):
    selector, kind = GLOBALS[name]
    return observe(backend, device, Address(selector), kind)


def anchor(backend):
    ids = observe(backend, SYSTEM, Address("dev#"), "ids")
    defaults = {name: observe(backend, SYSTEM, Address(selector), "uint")
                for name, selector in DEFAULTS.items()}
    devices = {}
    issues = []
    if readable(ids):
        for device in ids.value:
            devices[str(device)] = {name: global_property(backend, device, name)
                                    for name in ("name",) + ANCHOR_FIELDS}
        uids = [device["uid"].value for device in devices.values() if readable(device["uid"])]
        if len(uids) != len(set(uids)):
            issues.append("장치 UID가 중복됐습니다.")
        for name, observation in defaults.items():
            if readable(observation) and observation.value != 0 and observation.value not in ids.value:
                issues.append(f"기본 장치 {name}의 ID가 장치 목록에 없습니다.")
    return {"deviceIDs": ids, "defaults": defaults, "devices": devices, "issues": issues}


def compare_anchors(before, after):
    def observations(snapshot):
        result = {"deviceIDs": snapshot["deviceIDs"]}
        result.update({f"defaults.{name}": value for name, value in snapshot["defaults"].items()})
        for device, fields in snapshot["devices"].items():
            result.update({f"devices.{device}.{name}": fields[name] for name in ANCHOR_FIELDS})
        return result

    left, right = observations(before), observations(after)
    changes, unknown = [], []
    for path in sorted(left.keys() | right.keys()):
        first, last = left.get(path), right.get(path)
        if first != last:
            changes.append({"path": path, "before": asdict(first) if first else None,
                            "after": asdict(last) if last else None})
        if first is None or last is None or not known(first) or not known(last):
            unknown.append(path)
    issues = before["issues"] + after["issues"]
    return {"state": "unknown" if changes or unknown or issues else "stable",
            "changes": changes, "unknown": unknown, "issues": issues,
            "atomic": False}


def read_device(backend, device):
    result = {"id": device, **{name: global_property(backend, device, name) for name in GLOBALS}}
    result["scopes"] = {}
    for scope in ("input", "output"):
        channels = observe(backend, device, Address("slay", scope), "channels")
        controls = {}
        for name, (selector, kind) in CONTROLS.items():
            elements = range(channels.value + 1) if readable(channels) else (0,)
            controls[name] = [{"element": element,
                               "observation": observe(backend, device, Address(selector, scope, element), kind)}
                              for element in elements]
        result["scopes"][scope] = {"channels": channels, "controls": controls,
                                   "complete": known(channels)}
    return result


def json_value(value):
    if isinstance(value, PropertyObservation):
        return asdict(value)
    raise TypeError(f"지원하지 않는 JSON 자료형 {type(value).__name__}")


def collect(backend, device_names=()):
    started = datetime.now(timezone.utc).isoformat()
    before = anchor(backend)
    wanted = set(device_names)
    matches = {name: [] for name in wanted}
    selected = []
    for device, fields in before["devices"].items():
        name = fields["name"]
        if readable(name) and name.value in matches:
            matches[name.value].append(int(device))
        if not wanted or (readable(name) and name.value in wanted):
            selected.append(int(device))
    devices = [read_device(backend, device) for device in selected]
    after = anchor(backend)
    selection_errors = [f"장치 이름 {name!r}의 일치 개수가 {len(ids)}입니다."
                        for name, ids in sorted(matches.items()) if len(ids) != 1]
    report = {"schemaVersion": 1, "startedAt": started,
              "completedAt": datetime.now(timezone.utc).isoformat(),
              "deviceNameFilters": sorted(wanted), "selectionErrors": selection_errors,
              "devices": devices, "anchors": {"before": before, "after": after},
              "stability": compare_anchors(before, after),
              "propertyWrites": 0, "ioStarted": False, "hogAcquired": False,
              "physicalAccepted": False, "audioSamplesRead": False, "keysRead": False,
              "limitations": ["전후 표본의 일치만 비교하며 원자적 스냅샷이나 중간 변동 부재를 보장하지 않습니다.",
                              "settable과 running 표본은 전체 물리 차단이나 항구적 무음의 증거가 아닙니다.",
                              "조회한 공개 HAL 속성으로 모든 공개·비공개 수단의 존재 여부를 추정하지 않습니다."]}
    encoded = json.loads(json.dumps(report, default=json_value, allow_nan=False))

    def has_error(value):
        if isinstance(value, dict):
            return bool(value.get("error")) or any(has_error(item) for item in value.values())
        return isinstance(value, list) and any(has_error(item) for item in value)

    complete = (not selection_errors and encoded["stability"]["state"] == "stable"
                and not has_error(encoded) and all(scope["complete"] for device in devices
                    for scope in device["scopes"].values()))
    encoded["diagnosticComplete"] = complete
    return encoded


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-name", action="append", default=[], help="정확한 장치 이름. 반복 지정 가능")
    parser.add_argument("--output", required=True, type=Path, help="부모가 storage-route로 정한 새 JSON 절대경로")
    args = parser.parse_args(argv)
    if not args.output.is_absolute():
        parser.error("--output에는 storage-route가 반환한 절대경로가 필요합니다.")
    try:
        # 기존 영수증을 덮지 않도록 HAL 로드 전에 새 출력 파일을 확보한다.
        with args.output.open("x", encoding="utf-8") as output:
            report = collect(NativeBackend(), args.device_name)
            json.dump(report, output, ensure_ascii=False, indent=2, allow_nan=False)
            output.write("\n")
    except (OSError, RuntimeError) as error:
        print(f"진단을 완료하지 못했습니다. {error}", file=sys.stderr)
        return 2
    return 0 if report["diagnosticComplete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
