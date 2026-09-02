/**
 * Browser-safe, zero-dependency loopback classification shared by the `/api`
 * Host fence and the package's `ctx.connection` state. The predicate stays
 * package-internal; client plugins consume the derived state through Cordis.
 */

/**
 * Extra hostnames treated as loopback, sourced from the build-time
 * DSH_CLIENT_LOOPBACK_HOSTS env var (comma-separated). Empty by default —
 * only standard loopback addresses (localhost, [::1], 127.0.0.0/8) are
 * recognised. Set it when a reverse proxy rewrites Host to a public
 * hostname that should still be trusted as a local client.
 */
const extraLoopbackHostnames: readonly string[] = (process.env.DSH_CLIENT_LOOPBACK_HOSTS ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

/**
 * Whether a normalized URL hostname names the local loopback authority.
 * @param hostname - WHATWG URL hostname (IPv6 literals retain brackets).
 * @returns true for localhost, IPv6 loopback, declared extra loopback
 *   hostnames, or any IPv4 address in 127/8.
 */
export function isLoopbackHostname(hostname: string): boolean {
  if (hostname === 'localhost' || hostname === '[::1]') return true
  if (extraLoopbackHostnames.includes(hostname)) return true
  const parts = hostname.split('.')
  return parts.length === 4
    && parts[0] === '127'
    && parts.every(part => /^\d{1,3}$/.test(part) && Number(part) <= 255)
}
