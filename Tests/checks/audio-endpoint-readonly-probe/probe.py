#!/usr/bin/env python3
"""공개 CoreAudio 속성만 읽는다. 오디오 샘플과 설정 쓰기 API는 사용하지 않는다."""
import argparse
import ctypes as C
import datetime
import json
import math
from pathlib import Path
import struct
import sys


def fourcc(value):
    return int.from_bytes(value.encode("ascii"), "big")


class Address(C.Structure):
    _fields_ = [("selector", C.c_uint32), ("scope", C.c_uint32), ("element", C.c_uint32)]


class AudioBuffer(C.Structure):
    _fields_ = [("channels", C.c_uint32), ("bytes", C.c_uint32), ("data", C.c_void_p)]


class BufferList(C.Structure):
    _fields_ = [("count", C.c_uint32), ("buffer", AudioBuffer)]


def decode(data, kind):
    if kind == "ids":
        if len(data) % 4 or len(data) > 4096:
            raise ValueError("invalid_device_list_size")
        ids = list(struct.unpack("=" + "I" * (len(data) // 4), data))
        if 0 in ids or len(ids) != len(set(ids)):
            raise ValueError("invalid_device_ids")
        return ids
    if kind == "channels":
        if not data:
            return 0
        if len(data) < 4:
            raise ValueError("invalid_channel_header")
        count = struct.unpack_from("=I", data)[0]
        offset, stride = BufferList.buffer.offset, C.sizeof(AudioBuffer)
        if count > 128 or (count and offset + count * stride > len(data)):
            raise ValueError("invalid_channel_buffers")
        channels = sum(struct.unpack_from("=I", data, offset + i * stride)[0] for i in range(count))
        if channels > 256:
            raise ValueError("channel_limit_exceeded")
        return channels
    if len(data) != 4:
        raise ValueError("invalid_scalar_size")
    value = struct.unpack({"u32": "=I", "pid": "=i", "float": "=f"}[kind], data)[0]
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("nonfinite_scalar")
    return value


class NativeHAL:
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("macOS_required")
        self.hal = C.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        address = C.POINTER(Address)
        self.has = self.hal.AudioObjectHasProperty
        self.has.argtypes = [C.c_uint32, address]; self.has.restype = C.c_ubyte
        self.settable = self.hal.AudioObjectIsPropertySettable
        self.settable.argtypes = [C.c_uint32, address, C.POINTER(C.c_ubyte)]; self.settable.restype = C.c_int32
        self.size = self.hal.AudioObjectGetPropertyDataSize
        self.size.argtypes = [C.c_uint32, address, C.c_uint32, C.c_void_p, C.POINTER(C.c_uint32)]
        self.size.restype = C.c_int32
        self.get = self.hal.AudioObjectGetPropertyData
        self.get.argtypes = [C.c_uint32, address, C.c_uint32, C.c_void_p, C.POINTER(C.c_uint32), C.c_void_p]
        self.get.restype = C.c_int32
        self.cf.CFStringGetCString.argtypes = [C.c_void_p, C.c_void_p, C.c_long, C.c_uint32]
        self.cf.CFStringGetCString.restype = C.c_ubyte
        self.cf.CFRelease.argtypes = [C.c_void_p]
        self.cf.CFRelease.restype = None

    def observe(self, device, selector, scope="glob", element=0, kind="u32"):
        a = Address(fourcc(selector), fourcc(scope), element)
        row = {"has": bool(self.has(device, C.byref(a))), "sizeStatus": None,
               "getStatus": None, "settableStatus": None, "settable": None,
               "dataSize": None, "returnedSize": None, "value": None, "error": None}
        if not row["has"]:
            return row
        writable = C.c_ubyte()
        row["settableStatus"] = self.settable(device, C.byref(a), C.byref(writable))
        if row["settableStatus"] == 0:
            row["settable"] = bool(writable.value)
        size = C.c_uint32()
        row["sizeStatus"] = self.size(device, C.byref(a), 0, None, C.byref(size))
        row["dataSize"] = size.value
        if row["sizeStatus"] != 0 or size.value > 65536:
            row["error"] = "property_size_unavailable"
            return row
        expected = size.value
        if kind == "string" and expected != C.sizeof(C.c_void_p):
            row["error"] = "invalid_string_size"
            return row
        data = C.create_string_buffer(max(1, expected))
        row["getStatus"] = self.get(device, C.byref(a), 0, None, C.byref(size), data)
        row["returnedSize"] = size.value
        owned_string = C.c_void_p.from_buffer_copy(data.raw[:expected]).value if kind == "string" and row["getStatus"] == 0 else None
        try:
            if row["getStatus"] != 0 or size.value != expected:
                row["error"] = "property_read_unavailable_or_size_changed"
                return row
            if kind == "string":
                if not owned_string:
                    raise ValueError("null_string")
                text = C.create_string_buffer(8192)
                if not self.cf.CFStringGetCString(owned_string, text, len(text), 0x08000100):
                    raise ValueError("string_decode_failed")
                row["value"] = text.value.decode("utf-8", errors="strict")
            else:
                row["value"] = decode(data.raw[:expected], kind)
        except (ValueError, UnicodeError) as error:
            row["error"] = str(error)
        finally:
            if owned_string:
                self.cf.CFRelease(owned_string)
        return row


def usable(row):
    return row["has"] and row["sizeStatus"] == 0 and row["getStatus"] == 0 and not row["error"]


def anchors(hal):
    devices = hal.observe(1, "dev#", kind="ids")
    result = {"devices": devices, "defaults": {key: hal.observe(1, selector)
              for key, selector in [("input", "dIn "), ("output", "dOut"), ("systemOutput", "sOut")]}, "identities": {}}
    if usable(devices):
        for device in devices["value"]:
            result["identities"][str(device)] = {
                "uid": hal.observe(device, "uid ", kind="string"),
                "alive": hal.observe(device, "livn"),
                "hog": hal.observe(device, "oink", kind="pid"),
                "runningSomewhere": hal.observe(device, "gone"),
                "runningHere": hal.observe(device, "goin")}
    return result


def anchors_complete(value):
    if not usable(value["devices"]) or not all(usable(r) for r in value["defaults"].values()):
        return False
    for rows in value["identities"].values():
        if not usable(rows["uid"]) or not usable(rows["alive"]):
            return False
        for key in ["hog", "runningSomewhere", "runningHere"]:
            row = rows[key]
            if row["has"] and (not usable(row) or row["settableStatus"] != 0):
                return False
    return True


def anchor_changes(before, after):
    changes = []
    def compare(left, right, path):
        if "has" in left:
            if left["has"] != right["has"] or usable(left) and usable(right) and left["value"] != right["value"]:
                changes.append(path)
        else:
            for key in left.keys() & right.keys():
                compare(left[key], right[key], path + "/" + key)
    compare(before, after, "anchors")
    return sorted(changes)


def capture(hal, names=()):
    before = anchors(hal)
    endpoints, found = [], set()
    ids = before["devices"]["value"] if usable(before["devices"]) else []
    for device in ids:
        name = hal.observe(device, "lnam", kind="string")
        if names and (not usable(name) or name["value"] not in names):
            continue
        if usable(name):
            found.add(name["value"])
        row = {"id": device, "name": name, "identity": before["identities"][str(device)],
               "transport": hal.observe(device, "tran"), "scopes": {}}
        for scope in ["inpt", "outp"]:
            channels = hal.observe(device, "slay", scope, kind="channels")
            controls = []
            for element in range((channels["value"] if usable(channels) else 0) + 1):
                controls.append({"element": element, **{key: hal.observe(device, selector, scope, element, kind)
                    for key, selector, kind in [("mute", "mute", "u32"), ("volumeScalar", "volm", "float"), ("volumeDecibels", "vold", "float")]}})
            row["scopes"][scope] = {"channels": channels, "controls": controls}
        endpoints.append(row)
    after = anchors(hal)
    complete = anchors_complete(before) and anchors_complete(after)
    changes = anchor_changes(before, after)
    return {"schema": "ccr-audio-endpoint-readonly/v1", "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "readOnly": True, "propertyWrites": 0, "ioStarted": False, "hogAcquired": False,
            "physicalAccepted": False, "hostExitIsolationProven": False,
            "before": before, "endpoints": endpoints, "after": after,
            "anchorReadsComplete": complete, "observedAnchorChanges": changes,
            "anchorsUnchanged": False if changes else (before == after if complete else None),
            "requestedNamesMissing": sorted(set(names) - found),
            "limitations": ["전후 값의 일치는 원자적 스냅샷이나 중간 변경 부재를 증명하지 않습니다.",
                "설정 가능 속성·현재 독점 소유 PID·실행 값은 차단 성공이나 종료 후 지속 보호의 증거가 아닙니다.",
                "실행 값은 장치 단위 관측이며 프로세스 목록·오디오 샘플·모든 물리 경로를 확인하지 않습니다.",
                "나열한 공개 속성의 부재를 모든 공개·공급업체 차단 수단의 부재로 확대하지 않습니다."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-name", action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = capture(NativeHAL(), args.device_name)
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")
    print(json.dumps({"output": str(args.output), "endpoints": len(result["endpoints"]),
                      "anchorsUnchanged": result["anchorsUnchanged"], "propertyWrites": 0}, ensure_ascii=False))


if __name__ == "__main__":
    main()
