import { ProxyDto } from '@api/dto/proxy.dto';

export type ProxyPoolEntry = Required<Pick<ProxyDto, 'host' | 'port' | 'protocol'>> &
  Pick<ProxyDto, 'username' | 'password'>;

/**
 * Parse PROXY_POOL entries.
 * Formats per line/item:
 *   host:port:username:password
 *   host:port:protocol:username:password
 * Separators between entries: newline, comma, or JSON array of strings.
 */
export function parseProxyPool(raw?: string): ProxyPoolEntry[] {
  if (!raw?.trim()) {
    return [];
  }

  let items: string[] = [];
  const trimmed = raw.trim();

  if (trimmed.startsWith('[')) {
    try {
      const parsed = JSON.parse(trimmed) as unknown;
      if (Array.isArray(parsed)) {
        items = parsed.map((v) => String(v).trim()).filter(Boolean);
      }
    } catch {
      items = [];
    }
  }

  if (!items.length) {
    items = trimmed
      .split(/[\n,]+/)
      .map((v) => v.trim())
      .filter(Boolean);
  }

  return items.map(parseProxyPoolEntry);
}

export function parseProxyPoolEntry(line: string): ProxyPoolEntry {
  const parts = line.split(':').map((p) => p.trim());
  if (parts.length < 4) {
    throw new Error(
      `Invalid PROXY_POOL entry "${line}". Expected host:port:username:password or host:port:protocol:username:password`,
    );
  }

  const host = parts[0];
  const port = parts[1];
  const knownProtocols = new Set(['http', 'https', 'socks4', 'socks5']);

  let protocol = 'http';
  let username: string;
  let password: string;

  if (parts.length >= 5 && knownProtocols.has(parts[2].toLowerCase())) {
    protocol = parts[2].toLowerCase();
    password = parts[parts.length - 1];
    username = parts.slice(3, -1).join(':');
  } else {
    password = parts[parts.length - 1];
    username = parts.slice(2, -1).join(':');
  }

  if (!host || !port || !username || !password) {
    throw new Error(`Invalid PROXY_POOL entry "${line}": missing host/port/username/password`);
  }

  return { host, port, protocol, username, password };
}

export function proxyPoolKey(proxy: { host?: string | null; port?: string | null; username?: string | null }): string {
  return `${proxy.host || ''}:${proxy.port || ''}:${proxy.username || ''}`;
}
