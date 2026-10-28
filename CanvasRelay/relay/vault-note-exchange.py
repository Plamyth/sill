import ctypes
import os
import sys

library = ctypes.CDLL(None, use_errno=True)
left, right = map(os.fsencode, sys.argv[1:3])
if sys.platform == "darwin":
    exchange = library.renamex_np
    exchange.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    result = exchange(left, right, 0x00000002)
elif sys.platform.startswith("linux"):
    exchange = library.renameat2
    exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    result = exchange(-100, left, -100, right, 2)
else:
    sys.exit(69)
if result != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
