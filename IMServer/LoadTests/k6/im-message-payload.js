export function richTextContent(text) {
  return {
    type: 'rich_text',
    body: {
      text,
      entities: [],
    },
  };
}

export function initialDerivedState() {
  return {
    recallState: { active: {} },
    edits: [],
    reactions: [],
    streamState: null,
  };
}
