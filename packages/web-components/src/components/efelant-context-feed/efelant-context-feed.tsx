import { Component, Host, Prop, h } from "@stencil/core";

@Component({
  tag: "efelant-context-feed",
  styleUrl: "efelant-context-feed.css",
  shadow: true,
})
export class EfelantContextFeed {
  @Prop() tenantId!: string;
  @Prop() contextType!: string;
  @Prop() externalId!: string;

  render() {
    return (
      <Host>
        <ol part="feed">
          <slot />
        </ol>
      </Host>
    );
  }
}
