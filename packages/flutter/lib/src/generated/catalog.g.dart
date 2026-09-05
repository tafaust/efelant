// GENERATED from Stencil docs-json. Do not edit.
class StencilComponentSpec {
  const StencilComponentSpec({required this.tag, required this.props, required this.events});
  final String tag;
  final List<String> props;
  final List<String> events;
}

const stencilComponentCatalog = <StencilComponentSpec>[
  StencilComponentSpec(tag: 'efelant-composer', props: ['disabled', 'placeholder'], events: ['efelantSend']),
  StencilComponentSpec(tag: 'efelant-context-feed', props: ['contextType', 'externalId', 'tenantId'], events: []),
  StencilComponentSpec(tag: 'efelant-conversation', props: ['contextType', 'conversationId', 'externalId', 'tenantId'], events: []),
  StencilComponentSpec(tag: 'efelant-conversation-list', props: ['tenantId'], events: []),
  StencilComponentSpec(tag: 'efelant-status-event', props: ['message', 'status'], events: []),
  StencilComponentSpec(tag: 'efelant-unread-badge', props: ['count'], events: []),
];
