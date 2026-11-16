// Mock groups draw a stable roster from odd-numbered personal contact IDs.
bool isMockGroup(int id) => id % 4 == 0 || id == 2;

int mockGroupMemberCount(int groupId, int conversationCount) =>
    (12 + groupId % 80).clamp(1, 1 + conversationCount ~/ 2);

/// Index zero represents the current user. Every other entry is a personal contact.
int? mockGroupMemberAt(int groupId, int index, int conversationCount) {
  RangeError.checkValidRange(
    index,
    index + 1,
    mockGroupMemberCount(groupId, conversationCount),
  );
  if (index == 0) return null;
  final slot = (groupId * 17 + index - 1) % (conversationCount ~/ 2);
  return slot * 2 + 1;
}

/// The current user occupies one place in the roster. A group with no other
/// contacts can only contain messages from the current user.
int? mockSenderId(int id, int sequence, int conversationCount) {
  if (id >= conversationCount || !isMockGroup(id)) return id;
  final otherMembers = mockGroupMemberCount(id, conversationCount) - 1;
  if (otherMembers == 0) return null;
  return mockGroupMemberAt(id, 1 + sequence % otherMembers, conversationCount);
}
