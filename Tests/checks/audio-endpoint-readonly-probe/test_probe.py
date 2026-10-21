import ctypes as C
import json
import unittest
from dataclasses import dataclass

import probe as p


def uint(value):
    return bytes(C.c_uint32(value))


def buffer_list(channels):
    size = p.AudioBufferList.buffers.offset + len(channels) * C.sizeof(p.AudioBuffer)
    storage = bytearray(size)
    storage[:4] = uint(len(channels))
    for index, count in enumerate(channels):
        start = p.AudioBufferList.buffers.offset + index * C.sizeof(p.AudioBuffer)
        storage[start:start + C.sizeof(p.AudioBuffer)] = bytes(p.AudioBuffer(count, 0, None))
    return bytes(storage)


@dataclass
class FakeProperty:
    data: bytes | str
    size_status: int = 0
    get_status: int = 0
    settable_status: int = 0
    settable: bool = False
    size: int | None = None
    returned_size: int | None = None

    def capacity(self):
        if self.size is not None:
            return self.size
        return C.sizeof(C.c_void_p) if isinstance(self.data, str) else len(self.data)


class FakeBackend:
    def __init__(self):
        self.properties = {}
        self.calls = []
        self.anchor_count = 0
        self.change = None

    def put(self, device, selector, data, scope="global", element=0, **options):
        entry = FakeProperty(data, **options)
        self.properties[(device, p.Address(selector, scope, element))] = entry
        return entry

    def has(self, device, address):
        self.calls.append(("has", device, address))
        if device == p.SYSTEM and address == p.Address("dev#"):
            self.anchor_count += 1
            if self.anchor_count == 2 and self.change:
                self.change(self)
        return (device, address) in self.properties

    def get_size(self, device, address):
        self.calls.append(("size", device, address))
        entry = self.properties[(device, address)]
        return entry.size_status, entry.capacity()

    def is_settable(self, device, address):
        self.calls.append(("settable", device, address))
        entry = self.properties[(device, address)]
        return entry.settable_status, entry.settable

    def get(self, device, address, size, kind):
        self.calls.append(("get", device, address))
        entry = self.properties[(device, address)]
        returned = entry.capacity() if entry.returned_size is None else entry.returned_size
        return p.ReadResult(entry.get_status, returned, entry.data)


def inventory():
    backend = FakeBackend()
    backend.put(p.SYSTEM, "dev#", uint(11))
    for selector in p.DEFAULTS.values():
        backend.put(p.SYSTEM, selector, uint(11))
    for name, (selector, kind) in p.GLOBALS.items():
        data = "DN32-LIVE" if name == "name" else "uid-11" if kind == "string" else uint(1)
        if name == "hog":
            data = bytes(C.c_int32(-1))
        if name.startswith("isRunning"):
            data = uint(0)
        backend.put(11, selector, data)
    for scope in ("input", "output"):
        backend.put(11, "slay", buffer_list([32]), scope)
    return backend


class ObservationTests(unittest.TestCase):
    def test_absent_stops_and_failed_read_remains_present(self):
        backend = FakeBackend()
        address = p.Address("mute", "output")
        absent = p.observe(backend, 11, address, "bool")
        self.assertFalse(absent.has)
        self.assertIsNone(absent.sizeStatus)
        self.assertIsNone(absent.getStatus)
        self.assertIsNone(absent.settableStatus)
        self.assertIsNone(absent.value)
        self.assertEqual(absent.error, [])
        self.assertEqual(backend.calls, [("has", 11, address)])
        backend.put(11, "mute", uint(0), "output", get_status=-50)
        failed = p.observe(backend, 11, address, "bool")
        self.assertTrue(failed.has)
        self.assertEqual(failed.getStatus, -50)
        self.assertEqual(failed.error[0]["stage"], "get")
        self.assertIsNone(failed.value)

    def test_settable_failure_does_not_hide_successful_value(self):
        backend = FakeBackend()
        backend.put(11, "oink", bytes(C.c_int32(-1)), settable_status=-1, settable=True)
        observation = p.observe(backend, 11, p.Address("oink"), "pid")
        self.assertEqual(observation.value, -1)
        self.assertEqual(observation.getStatus, 0)
        self.assertEqual(observation.settableStatus, -1)
        self.assertIsNone(observation.settable)
        self.assertFalse(p.known(observation))

    def test_signed_hog_and_settable_are_separate(self):
        backend = FakeBackend()
        for pid in (-1, 0, 931, -2147483648):
            with self.subTest(pid=pid):
                backend.put(11, "oink", bytes(C.c_int32(pid)), settable=True)
                observation = p.observe(backend, 11, p.Address("oink"), "pid")
                self.assertEqual(observation.value, pid)
                self.assertTrue(observation.settable)

    def test_size_failure_and_invalid_capacity_never_get(self):
        for options in ({"size_status": -50}, {"size": -1}, {"size": 3},
                        {"size": p.MAX_BYTES + 1}):
            with self.subTest(options=options):
                backend = FakeBackend()
                backend.put(11, "mute", uint(0), **options)
                observation = p.observe(backend, 11, p.Address("mute"), "bool")
                self.assertTrue(observation.error)
                self.assertIsNone(observation.getStatus)
                self.assertNotIn("get", [call[0] for call in backend.calls])

    def test_returned_size_shrink_growth_and_payload_mismatch(self):
        for data, returned in ((uint(0), 0), (uint(0), 8), (b"\x00", 4)):
            with self.subTest(data=data, returned=returned):
                backend = FakeBackend()
                backend.put(11, "mute", data, size=4, returned_size=returned)
                observation = p.observe(backend, 11, p.Address("mute"), "bool")
                self.assertEqual(observation.getStatus, 0)
                self.assertEqual(observation.returnedSize, returned)
                self.assertIsNone(observation.value)
                self.assertTrue(observation.error)

    def test_nan_infinity_and_scalar_range_are_not_json_values(self):
        for selector, kind, values in (("volm", "scalar", (float("nan"), float("inf"), -0.1, 1.1)),
                                       ("vold", "float", (float("nan"), -float("inf")))):
            for value in values:
                with self.subTest(selector=selector, value=value):
                    backend = FakeBackend()
                    backend.put(11, selector, bytes(C.c_float(value)))
                    observation = p.observe(backend, 11, p.Address(selector), kind)
                    self.assertIsNone(observation.value)
                    self.assertTrue(observation.error)
                    json.dumps(p.asdict(observation), allow_nan=False)

    def test_channel_sum_uses_all_buffers_and_main_absence_does_not_skip_elements(self):
        backend = inventory()
        backend.put(11, "slay", buffer_list([32, 32]), "input")
        backend.put(11, "mute", uint(1), "input", 64)
        backend.put(11, "volm", bytes(C.c_float(0.25)), "input", 1)
        device = p.read_device(backend, 11)
        scope = device["scopes"]["input"]
        self.assertEqual(scope["channels"].value, 64)
        self.assertEqual(len(scope["controls"]["mute"]), 65)
        self.assertFalse(scope["controls"]["mute"][0]["observation"].has)
        self.assertEqual(scope["controls"]["mute"][64]["observation"].value, 1)
        self.assertEqual(scope["controls"]["volumeScalar"][1]["observation"].value, 0.25)

    def test_channel_settable_failure_keeps_actual_element_range(self):
        backend = inventory()
        backend.put(11, "slay", buffer_list([33]), "input", settable_status=-50)
        scope = p.read_device(backend, 11)["scopes"]["input"]
        self.assertEqual(scope["channels"].value, 33)
        self.assertEqual(len(scope["controls"]["mute"]), 34)
        self.assertFalse(scope["complete"])

    def test_bad_buffer_lists_are_errors_without_channel_truncation(self):
        bad_pointer = bytearray(buffer_list([2]))
        start = p.AudioBufferList.buffers.offset
        bad_pointer[start:start + C.sizeof(p.AudioBuffer)] = bytes(p.AudioBuffer(2, 4, 1234))
        for raw in (b"\x00", uint(1), uint(p.MAX_BUFFERS + 1),
                    buffer_list([p.MAX_CHANNELS + 1]), bytes(bad_pointer)):
            with self.subTest(raw=raw[:16]):
                backend = inventory()
                backend.put(11, "slay", raw, "input")
                scope = p.read_device(backend, 11)["scopes"]["input"]
                self.assertIsNone(scope["channels"].value)
                self.assertTrue(scope["channels"].error)
                self.assertFalse(scope["complete"])
                self.assertEqual(len(scope["controls"]["mute"]), 1)

    def test_zero_channel_configurations(self):
        for raw in (b"", uint(0), buffer_list([])):
            backend = FakeBackend()
            backend.put(11, "slay", raw, "input")
            self.assertEqual(p.observe(backend, 11, p.Address("slay", "input"), "channels").value, 0)

    def test_bad_device_lists(self):
        for raw, size in ((uint(11) * 2, None), (uint(0), None), (b"x", None),
                          (b"", (p.MAX_DEVICES + 1) * 4)):
            backend = FakeBackend()
            backend.put(p.SYSTEM, "dev#", raw, size=size)
            observation = p.observe(backend, p.SYSTEM, p.Address("dev#"), "ids")
            self.assertIsNone(observation.value)
            self.assertTrue(observation.error)


class StabilityTests(unittest.TestCase):
    def test_stable_receipt_is_not_physical_acceptance(self):
        backend = inventory()
        report = p.collect(backend, ["DN32-LIVE"])
        self.assertEqual(report["stability"]["state"], "stable")
        self.assertTrue(report["diagnosticComplete"])
        self.assertEqual(report["propertyWrites"], 0)
        for field in ("ioStarted", "hogAcquired", "physicalAccepted", "audioSamplesRead", "keysRead"):
            self.assertIs(report[field], False)
        self.assertFalse(report["stability"]["atomic"])
        self.assertEqual(report["devices"][0]["hog"]["value"], -1)

    def test_hotplug_uid_all_three_defaults_hog_and_both_running_changes(self):
        mutations = [("deviceIDs", p.SYSTEM, "dev#", uint(12)),
                     ("devices.11.uid", 11, "uid ", "replacement-uid"),
                     ("devices.11.hog", 11, "oink", bytes(C.c_int32(732))),
                     ("devices.11.isRunningSomewhere", 11, "gone", uint(1)),
                     ("devices.11.isRunning", 11, "goin", uint(1))]
        mutations += [(f"defaults.{name}", p.SYSTEM, selector, uint(0))
                      for name, selector in p.DEFAULTS.items()]
        for expected, device, selector, data in mutations:
            with self.subTest(expected=expected):
                backend = inventory()
                backend.change = lambda target, d=device, s=selector, v=data: target.put(d, s, v)
                report = p.collect(backend)
                self.assertEqual(report["stability"]["state"], "unknown")
                self.assertFalse(report["diagnosticComplete"])
                self.assertIn(expected, [item["path"] for item in report["stability"]["changes"]])

    def test_missing_and_failed_anchor_values_remain_unknown(self):
        for absent in (True, False):
            backend = inventory()
            if absent:
                del backend.properties[(11, p.Address("oink"))]
            else:
                backend.put(11, "oink", uint(0), get_status=-50)
            report = p.collect(backend)
            self.assertEqual(report["stability"]["state"], "unknown")
            self.assertIn("devices.11.hog", report["stability"]["unknown"])

    def test_duplicate_uids_and_unlisted_defaults_remain_unknown(self):
        backend = inventory()
        backend.put(p.SYSTEM, "dev#", uint(11) + uint(12))
        backend.put(12, "uid ", "uid-11")
        backend.put(p.SYSTEM, "dOut", uint(77))
        report = p.collect(backend)
        self.assertFalse(report["diagnosticComplete"])
        self.assertTrue(report["stability"]["issues"])

    def test_repeated_exact_name_filters_select_three_devices(self):
        backend = inventory()
        names = ["DN32-LIVE", "LG TV SSCR2", "‘iPhone’ 마이크"]
        backend.put(p.SYSTEM, "dev#", uint(11) + uint(12) + uint(13))
        for device, name in zip((11, 12, 13), names):
            backend.put(device, "lnam", name)
        report = p.collect(backend, names)
        self.assertEqual([device["id"] for device in report["devices"]], [11, 12, 13])
        self.assertEqual(report["selectionErrors"], [])
        self.assertTrue(p.collect(backend, ["존재하지 않는 장치"])["selectionErrors"])
        backend.put(12, "lnam", "DN32-LIVE")
        self.assertTrue(p.collect(backend, ["DN32-LIVE"])["selectionErrors"])


class CFStringOwnershipTests(unittest.TestCase):
    def test_successful_get_releases_even_on_bad_size_type_or_conversion(self):
        for failure in (None, "size", "type", "conversion"):
            with self.subTest(failure=failure):
                releases = []

                class FakeCF:
                    def CFGetTypeID(self, pointer):
                        return 2 if failure == "type" else 1

                    def CFStringGetTypeID(self):
                        return 1

                    def CFStringGetLength(self, pointer):
                        return 1

                    def CFStringGetMaximumSizeForEncoding(self, length, encoding):
                        return 3

                    def CFStringGetCString(self, pointer, output, capacity, encoding):
                        C.memmove(output, b"a\x00", 2)
                        return failure != "conversion"

                    def CFRelease(self, pointer):
                        releases.append(pointer)

                def fake_get(device, address, qualifier_size, qualifier, used, output):
                    C.cast(output, C.POINTER(C.c_void_p))[0] = 1234
                    if failure == "size":
                        C.cast(used, C.POINTER(C.c_uint32))[0] = 1
                    return 0

                backend = p.NativeBackend.__new__(p.NativeBackend)
                backend.cf = FakeCF()
                backend._get = fake_get
                result = backend.get(11, p.Address("uid "), C.sizeof(C.c_void_p), "string")
                self.assertEqual(releases, [1234])
                self.assertEqual(result.status, 0)
                self.assertEqual(bool(result.error), failure is not None)


if __name__ == "__main__":
    unittest.main()
