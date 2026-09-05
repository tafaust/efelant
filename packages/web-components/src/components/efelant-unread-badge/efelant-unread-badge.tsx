import { Component, Host, Prop, h } from "@stencil/core";

@Component({
  tag: "efelant-unread-badge",
  styleUrl: "efelant-unread-badge.css",
  shadow: true,
})
export class EfelantUnreadBadge {
  @Prop() count = 0;

  render() {
    if (this.count <= 0) {
      return <Host hidden />;
    }
    return (
      <Host>
        <span part="badge">{this.count > 99 ? "99+" : this.count}</span>
      </Host>
    );
  }
}
