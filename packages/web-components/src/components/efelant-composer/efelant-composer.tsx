import { Component, Event, EventEmitter, Host, Prop, h } from "@stencil/core";

@Component({
  tag: "efelant-composer",
  styleUrl: "efelant-composer.css",
  shadow: true,
})
export class EfelantComposer {
  @Prop() placeholder = "Message";
  @Prop() disabled = false;
  @Event() efelantSend!: EventEmitter<string>;

  private onSubmit = (event: Event) => {
    event.preventDefault();
    const form = event.target as HTMLFormElement;
    const data = new FormData(form);
    const text = String(data.get("text") ?? "").trim();
    if (text.length === 0 || this.disabled) {
      return;
    }
    this.efelantSend.emit(text);
    form.reset();
  };

  render() {
    return (
      <Host>
        <form part="form" onSubmit={this.onSubmit}>
          <input name="text" part="input" disabled={this.disabled} placeholder={this.placeholder} />
          <button part="send" type="submit" disabled={this.disabled}>
            Send
          </button>
        </form>
      </Host>
    );
  }
}
