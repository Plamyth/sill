import struct
import unittest
from types import SimpleNamespace
from probe import BufferList, AudioBuffer, NativeHAL, C, capture, decode, usable


def observation(value=None, has=True, error=None):
    return {"has": has, "sizeStatus": 0 if has else None, "getStatus": 0 if has else None,
            "settableStatus": 0 if has else None, "settable": False if has else None,
            "value": value, "error": error}


class FakeHAL:
    def __init__(self, change=None):
        self.enumerations = 0
        self.change = change

    def observe(self, device, selector, scope="glob", element=0, kind="u32"):
        if selector == "dev#":
            self.enumerations += 1
            return observation([2, 3] if self.enumerations > 1 and self.change == "devices" else [2])
        after = self.enumerations > 1
        if selector in ["dIn ", "dOut", "sOut"]:
            return observation(3 if after and self.change == "default" else 2)
        if selector == "uid ":
            return observation("changed" if after and self.change == "uid" else str(device))
        if selector == "lnam": return observation("fixture")
        if selector == "slay": return observation(2 if scope == "outp" else 0)
        if selector == "oink": return observation(99 if after and self.change == "hog" else -1)
        if selector in ["gone", "goin"]: return observation(1 if after and self.change == "running" else 0)
        if selector in ["livn", "tran"]: return observation(1)
        if selector == "mute" and scope == "outp" and element == 1:
            return observation(1)
        return observation(has=False)


class ProbeTests(unittest.TestCase):
    def test_native_boundary_status_and_sizes_without_hardware(self):
        def backend(has=True, settable_status=0, get_status=0, returned=4, data=struct.pack("=i", -1)):
            native = NativeHAL.__new__(NativeHAL)
            calls = []
            native.has = lambda *_: has
            def settable(device, address, writable):
                calls.append("settable"); writable._obj.value = 1; return settable_status
            def size(device, address, qualifier_size, qualifier, length):
                calls.append("size"); length._obj.value = len(data); return 0
            def get(device, address, qualifier_size, qualifier, length, storage):
                calls.append("get"); C.memmove(storage, data, len(data)); length._obj.value = returned; return get_status
            native.settable, native.size, native.get = settable, size, get
            return native, calls
        native, calls = backend(has=False)
        self.assertFalse(native.observe(2, "oink", kind="pid")["has"])
        self.assertEqual(calls, [])
        native, _ = backend(settable_status=-1)
        row = native.observe(2, "oink", kind="pid")
        self.assertEqual(row["value"], -1); self.assertIsNone(row["settable"])
        self.assertEqual(row["settableStatus"], -1)
        native, _ = backend(returned=3)
        row = native.observe(2, "oink", kind="pid")
        self.assertIsNone(row["value"]); self.assertEqual(row["returnedSize"], 3)
        native, _ = backend(get_status=-50)
        self.assertEqual(native.observe(2, "oink", kind="pid")["getStatus"], -50)
        native, calls = backend(data=b"a" * 65537)
        self.assertEqual(native.observe(2, "oink", kind="pid")["error"], "property_size_unavailable")
        self.assertNotIn("get", calls)
        released = []
        native, _ = backend(data=struct.pack("P", 12345), returned=3)
        native.cf = SimpleNamespace(CFRelease=released.append)
        self.assertIsNone(native.observe(2, "uid ", kind="string")["value"])
        self.assertEqual(released, [12345])

    def test_absent_and_failed_are_distinct(self):
        absent = observation(has=False)
        failed = observation(error="read_failed")
        self.assertFalse(usable(absent)); self.assertFalse(usable(failed))
        self.assertNotEqual(absent, failed)

    def test_signed_hog_and_nonfinite(self):
        self.assertEqual(decode(struct.pack("=i", -1), "pid"), -1)
        for value in [float("nan"), float("inf")]:
            with self.assertRaises(ValueError): decode(struct.pack("=f", value), "float")
        with self.assertRaises(ValueError): decode(b"", "u32")

    def test_bounded_device_ids(self):
        self.assertEqual(decode(b"", "ids"), [])
        for data in [b"a", struct.pack("=II", 2, 2), struct.pack("=I", 0), b"a" * 4100]:
            with self.assertRaises(ValueError): decode(data, "ids")

    def test_channel_layout_bounds(self):
        data = bytearray(BufferList.buffer.offset + C.sizeof(AudioBuffer))
        struct.pack_into("=I", data, 0, 1)
        struct.pack_into("=I", data, BufferList.buffer.offset, 32)
        self.assertEqual(decode(data, "channels"), 32)
        self.assertEqual(decode(b"", "channels"), 0)
        for invalid in [b"a", struct.pack("=I", 1), struct.pack("=I", 129)]:
            with self.assertRaises(ValueError): decode(invalid, "channels")
        struct.pack_into("=I", data, BufferList.buffer.offset, 257)
        with self.assertRaises(ValueError): decode(data, "channels")

    def test_master_absent_does_not_hide_channel_control(self):
        result = capture(FakeHAL(), ["fixture"])
        controls = result["endpoints"][0]["scopes"]["outp"]["controls"]
        self.assertFalse(controls[0]["mute"]["has"])
        self.assertEqual(controls[1]["mute"]["value"], 1)
        self.assertEqual(len(controls), 3)
        self.assertTrue(result["anchorsUnchanged"])
        self.assertFalse(result["physicalAccepted"])
        self.assertEqual(result["propertyWrites"], 0)

    def test_each_observed_change_invalidates_anchor_equality(self):
        for change in ["devices", "uid", "default", "hog", "running"]:
            with self.subTest(change=change):
                self.assertFalse(capture(FakeHAL(change))["anchorsUnchanged"])

    def test_failed_anchor_is_unknown_and_missing_filter_is_visible(self):
        class Failed(FakeHAL):
            def observe(self, device, selector, *args, **kwargs):
                if selector == "uid ": return observation(error="read_failed")
                return super().observe(device, selector, *args, **kwargs)
        self.assertIsNone(capture(Failed())["anchorsUnchanged"])
        result = capture(FakeHAL(), ["absent"])
        self.assertEqual(result["endpoints"], [])
        self.assertEqual(result["requestedNamesMissing"], ["absent"])

    def test_failed_channel_query_keeps_master_observation(self):
        class FailedChannels(FakeHAL):
            def observe(self, device, selector, scope="glob", element=0, kind="u32"):
                if selector == "slay": return observation(error="read_failed")
                if selector == "volm" and element == 0: return observation(0.5)
                return super().observe(device, selector, scope, element, kind)
        controls = capture(FailedChannels())["endpoints"][0]["scopes"]["outp"]["controls"]
        self.assertEqual(len(controls), 1)
        self.assertEqual(controls[0]["volumeScalar"]["value"], 0.5)

    def test_confirmed_change_survives_other_failed_anchor(self):
        class FailedUID(FakeHAL):
            def observe(self, device, selector, *args, **kwargs):
                if selector == "uid ": return observation(error="read_failed")
                return super().observe(device, selector, *args, **kwargs)
        result = capture(FailedUID("default"))
        self.assertFalse(result["anchorReadsComplete"])
        self.assertFalse(result["anchorsUnchanged"])
        self.assertIn("anchors/defaults/input", result["observedAnchorChanges"])


if __name__ == "__main__":
    unittest.main()
