export class HttpError extends Error {
  constructor(status, message, code = 'router_error') { super(message); this.status = status; this.code = code; }
}
export const requireThat = (condition, message, status = 400) => { if (!condition) throw new HttpError(status, message); };
export const errorBody = error => ({ error: { message: error.message, type: 'aideck_router_error', code: error.code || 'router_error' } });
