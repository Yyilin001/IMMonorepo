#!/usr/bin/env python3
"""Load the built SDK from a non-Swift host; verify bounded operation/reply ownership."""
import argparse, ctypes, json, platform, tempfile, time
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    library = ctypes.CDLL(str(args.library.resolve()))
    signatures = {
        'im_shared_create': ([ctypes.c_char_p, ctypes.c_int32], ctypes.c_int64),
        'im_shared_submit': ([ctypes.c_int64, ctypes.c_char_p, ctypes.c_int32], ctypes.c_int64),
        'im_shared_poll': ([ctypes.c_int64], ctypes.c_void_p),
        'im_shared_cancel': ([ctypes.c_int64], None),
        'im_shared_release': ([ctypes.c_int64], ctypes.c_int32),
        'im_shared_release_client': ([ctypes.c_int64], ctypes.c_int32),
        'im_shared_active': ([], ctypes.c_int32), 'im_shared_clients': ([], ctypes.c_int32),
        'im_shared_free': ([ctypes.c_void_p], None),
    }
    for name, (arguments, result) in signatures.items():
        fn = getattr(library, name); fn.argtypes = arguments; fn.restype = result
    def call(client, operation):
        value = json.dumps(dict(operation=operation)).encode()
        handle = library.im_shared_submit(client, value, len(value)); assert handle > 0
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            reply = library.im_shared_poll(handle)
            if reply:
                try: result = json.loads(ctypes.string_at(reply))
                finally: library.im_shared_free(reply)
                assert library.im_shared_release(handle) == 1
                assert 'error' not in result, 'Shared operation failed'
                return result
            time.sleep(.01)
        library.im_shared_cancel(handle)
        raise TimeoutError(operation)
    with tempfile.TemporaryDirectory(prefix='im-shared-abi-') as root:
        config = json.dumps(dict(accountURL='https://localhost:2', gatewayHost='localhost', gatewayPort=7443, storageDirectory=root)).encode()
        client = library.im_shared_create(config, len(config)); assert client > 0
        assert library.im_shared_release_client(client) == 0
        assert call(client, 'restore')['snapshot']['state'] == 'signedOut'
        call(client, 'close'); assert library.im_shared_release_client(client) == 1
        assert library.im_shared_active() == 0 and library.im_shared_clients() == 0
    result = dict(platform=platform.system(), library=str(args.library.resolve()), cABI=True, restore=True, closedAndReleased=True, leakedClients=0, leakedOperations=0, backendLogin=False)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))

if __name__ == '__main__': main()
