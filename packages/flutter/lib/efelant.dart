/// Embeddable Flutter SDK for Efelant.
///
/// The standalone messenger in `/app` remains the full product. Host apps
/// import this package to attach communication to a domain object.
library;

export 'src/client.dart';
export 'src/models.dart';
export 'src/theme.dart';
export 'src/generated/catalog.g.dart';
export 'src/generated/stencil_widgets.g.dart';
export 'src/generated/tokens.g.dart';
export 'src/widgets/efelant_composer.dart';
export 'src/widgets/efelant_context_feed.dart';
export 'src/widgets/efelant_conversation.dart';
export 'src/widgets/efelant_conversation_list.dart';
export 'src/widgets/efelant_status_event.dart';
export 'src/widgets/efelant_unread_badge.dart';
