export class EfelantError extends Error {
  readonly code: string;

  constructor(message: string, code = "EFELANT") {
    super(message);
    this.name = "EfelantError";
    this.code = code;
  }
}

export class EfelantAuthError extends EfelantError {
  constructor(message: string, code = "28000") {
    super(message, code);
    this.name = "EfelantAuthError";
  }
}

export class EfelantForbiddenError extends EfelantError {
  constructor(message: string, code = "42501") {
    super(message, code);
    this.name = "EfelantForbiddenError";
  }
}

export function errorFromSql(message: string, code?: string): EfelantError {
  const text = message.toLowerCase();
  if (text.includes("not authenticated") || text.includes("session") || code === "28000") {
    return new EfelantAuthError(message, code);
  }
  if (text.includes("member") || text.includes("tenant") || code === "42501") {
    return new EfelantForbiddenError(message, code);
  }
  return new EfelantError(message, code ?? "EFELANT");
}
