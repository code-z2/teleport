// The Node test project imports src/index.ts, which re-exports the Durable Object.
// Node has no "cloudflare:workers"; mailbox behaviour is tested in the Workers runtime
// (test/mailbox.test.ts).
export class DurableObject<Env = unknown> {
  constructor(
    protected ctx: unknown,
    protected env: Env,
  ) {}
}
