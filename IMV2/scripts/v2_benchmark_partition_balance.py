"""Plan full partition redistribution from a committed inspection; never authorize it."""
from collections import Counter


def partition_balance_plan(partitions, target_hosts):
    """Retain each host's quota before moving surplus, minimizing transfer count.

    The caller must execute each move through certified transfers with fresh
    owner/epoch checks, then verify the complete desired assignment. This plan
    neither grants ownership nor replaces transfer receipts.
    """
    hosts = [host.lower() for host in target_hosts]
    if not hosts or any(not host for host in hosts) or len(set(hosts)) != len(hosts):
        raise ValueError('target hosts must be nonempty and unique')
    slots = sorted(partitions, key=lambda slot: slot['partition'])
    if not slots or [slot['partition'] for slot in slots] != list(range(len(slots))):
        raise ValueError('inspection must contain every partition exactly once')
    for slot in slots:
        if (slot.get('retired') or slot.get('transfer') or
                not slot['owner']['hostID'] or not isinstance(slot['epoch'], int) or
                isinstance(slot['epoch'], bool) or slot['epoch'] <= 0):
            raise ValueError('partition must have a live stable committed owner')
    base, remainder = divmod(len(slots), len(hosts))
    quotas = {host: base + (index < remainder) for index, host in enumerate(hosts)}
    retained = Counter()
    desired = {}
    surplus = []
    for slot in slots:
        owner = slot['owner']['hostID'].lower()
        if retained[owner] < quotas.get(owner, 0):
            desired[slot['partition']] = owner
            retained[owner] += 1
        else:
            surplus.append(slot)
    destinations = [host for host in hosts for _ in range(quotas[host] - retained[host])]
    if len(destinations) != len(surplus):
        raise AssertionError('partition balance did not conserve ownership')
    moves = []
    for slot, destination in zip(surplus, destinations):
        desired[slot['partition']] = destination
        moves.append(dict(partition=slot['partition'], sourceHost=slot['owner']['hostID'].lower(),
                          targetHost=destination, expectedEpoch=slot['epoch']))
    return dict(quotas=quotas, assignments=desired, moves=moves)


def verify_partition_balance(partitions, plan):
    """Require exact committed ownership, including retained partitions."""
    desired = {int(key): host for key, host in plan['assignments'].items()}
    observed = {}
    for slot in partitions:
        index = slot['partition']
        if index in observed or slot.get('retired') or slot.get('transfer'):
            raise ValueError('redistribution is incomplete or inspection is invalid')
        observed[index] = slot['owner']['hostID'].lower()
    if observed != desired:
        raise ValueError('committed partition ownership does not match the full plan')
    counts = Counter(observed.values())
    if any(counts[host] != quota for host, quota in plan['quotas'].items()):
        raise ValueError('committed host quotas do not match the full plan')
    return dict(counts)
