import { Component, Host, Prop, h } from "@stencil/core";

@Component({
  tag: "efelant-status-event",
  styleUrl: "efelant-status-event.css",
  shadow: true,
})
export class EfelantStatusEvent {
  @Prop() status = "";
  @Prop() message = "";

  render() {
    return (
      <Host>
        <article part="status">
          <strong part="label">{this.status}</strong>
          {this.message ? <p part="message">{this.message}</p> : null}
        </article>
      </Host>
    );
  }
}
