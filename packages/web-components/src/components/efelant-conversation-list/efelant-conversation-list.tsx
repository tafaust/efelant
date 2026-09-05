import { Component, Host, Prop, h } from "@stencil/core";

@Component({
  tag: "efelant-conversation-list",
  styleUrl: "efelant-conversation-list.css",
  shadow: true,
})
export class EfelantConversationList {
  @Prop() tenantId?: string;

  render() {
    return (
      <Host>
        <nav part="list">
          <slot />
        </nav>
      </Host>
    );
  }
}
