"""Bounded disk-space observation for owned, disposable benchmark storage."""
import shutil
import subprocess

GIB = 1024 ** 3


def evaluate_space(host_free, postgres_free, *, host_reserve=8*GIB, postgres_reserve=2*GIB):
    if min(host_free, postgres_free) < 0:
        raise ValueError('free space cannot be negative')
    reasons = []
    if host_free < host_reserve:
        reasons.append('host_disk_reserve')
    if postgres_free < postgres_reserve:
        reasons.append('postgres_disk_reserve')
    return dict(passed=not reasons, reasons=reasons, hostFreeBytes=host_free,
        postgresFreeBytes=postgres_free, hostReserveBytes=host_reserve, postgresReserveBytes=postgres_reserve)


def observe_space(directory, postgres):
    # Caller verifies the task ownership label before sampling this container.
    output = subprocess.check_output(['docker','--context',postgres['dockerContext'],
        'exec',postgres['container'],'df','-Pk','/var/lib/postgresql/data'], text=True, timeout=10)
    columns = output.strip().splitlines()[-1].split()
    return evaluate_space(shutil.disk_usage(directory).free, int(columns[3])*1024)
