/* Inert stub for optional wallet-SDK dependencies (x402 payment schemes)
   that are dynamically imported but never executed in our config. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const anything: any = new Proxy(function () {}, {
  get: () => anything,
  apply: () => anything,
});

export default anything;
export const toClientEvmSigner = anything;