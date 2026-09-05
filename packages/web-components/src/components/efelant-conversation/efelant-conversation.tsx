import { Component, Host, Prop, h } from "@stencil/core";

@Component({
  tag: "efelant-conversation",
  styleUrl: "efelant-conversation.css",
  shadow: true,
})
export class EfelantConversation {
  @Prop() tenantId!: string;
  @Prop() conversationId?: string;
  @Prop() contextType?: string;
  @Prop() externalId?: string;

  render() {
    return (
      <Host>
        <section part="conversation">
          <slot name="header" />
          <div part="timeline">
            <slot />
          </div>
          <slot name="composer" />
        </section>
      </Host>
    );
  }
}
