#!/usr/bin/env python3
"""Provision a private development CA and the localhost/account leaf shared by HTTPS and TCP."""
import fcntl
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile


def openssl(*args, **kwargs):
    return subprocess.run(["openssl", *args], check=True, **kwargs)


def prepare(directory):
    directory.mkdir(parents=True, exist_ok=True)
    issuer = directory / "issuer"
    tls = directory / "tls"
    for path in (issuer, tls):
        path.mkdir(mode=0o700, exist_ok=True)
    with (issuer / ".lock").open("a") as lock, tempfile.TemporaryDirectory(dir=directory) as temp:
        fcntl.flock(lock, fcntl.LOCK_EX)
        work = Path(temp)
        ca, key = issuer / "root.crt", issuer / "root.key"
        if ca.exists() != key.exists():
            raise RuntimeError("Incomplete local CA; restore the matching certificate and key")
        if not ca.exists():
            config = work / "ca.cnf"
            config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ca\n[dn]\n[ca]\n"
                              "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n")
            openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                    "-subj", "/CN=IM Local Development CA", "-config", config,
                    "-keyout", work / "key", "-out", work / "ca")
            (work / "key").replace(key)
            (work / "ca").replace(ca)
        leaf, leaf_key = tls / "leaf.pem", tls / "leaf.key"
        if not leaf_key.exists():
            openssl("genrsa", "-out", work / "key", "2048")
            (work / "key").replace(leaf_key)
        valid = (leaf.exists() and
                 subprocess.run(["openssl", "x509", "-checkend", "604800", "-noout", "-in", leaf],
                                stdout=subprocess.DEVNULL).returncode == 0 and
                 subprocess.run(["openssl", "verify", "-CAfile", ca, leaf], stdout=subprocess.DEVNULL).returncode == 0)
        if not valid:
            openssl("req", "-new", "-key", leaf_key, "-subj", "/CN=localhost", "-out", work / "request")
            extensions = work / "extensions"
            extensions.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                                  "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,DNS:account,IP:127.0.0.1\n")
            openssl("x509", "-req", "-in", work / "request", "-CA", ca, "-CAkey", key,
                    "-set_serial", str(secrets.randbits(120) or 1), "-days", "90", "-sha256",
                    "-extfile", extensions, "-out", work / "leaf")
            (work / "leaf").replace(leaf)
        for dest in (directory / "root.crt", tls / "root.crt"):
            shutil.copyfile(ca, work / "public")
            (work / "public").replace(dest)


if __name__ == "__main__":
    os.umask(0o077)
    prepare(Path(sys.argv[1]).resolve())
