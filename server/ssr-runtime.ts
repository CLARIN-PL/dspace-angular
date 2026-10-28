import type { Request, Response } from 'express';
import axios from 'axios';
import LRU from 'lru-cache';
import { isbot } from 'isbot';

export interface PageCacheOptions {
  max: number;
  timeToLive: number;
  allowStale: boolean;
  maxSizeBytes?: number;
  maxEntrySizeBytes?: number;
}

interface CachedPage {
  page: string;
  headers: Record<string, any>;
}

export interface SsrRuntimeOptions {
  enabled: boolean;
  maxConcurrentRenders?: number;
  renderTimeoutMs?: number;
  excludePathPatterns: { pattern: string | RegExp; flag?: string }[];
  languages: string[];
  defaultLanguage: string;
  cacheHeaders: string[];
  botCache: PageCacheOptions;
  anonymousCache: PageCacheOptions;
  internalRestUrl: string;
  publicRestUrl: string;
  replaceRestUrl: boolean;
  render: (req: Request, res: Response, callback: (error: any, html?: string) => void) => void;
  renderClient: (req: Request, res: Response) => void;
  warn?: (message: string) => void;
}

/** Count outstanding work, including work whose HTTP deadline has expired. */
export class RenderGate {
  private active = 0;
  private keys = new Set<string>();
  private rejected = 0;
  private timedOut = 0;
  private expiredActive = 0;

  constructor(private maximum: number) {
    if (!Number.isSafeInteger(maximum) || maximum < 1) {
      throw new Error('maxConcurrentRenders must be a positive integer');
    }
  }

  start(key: string | undefined, timeoutMs: number, onTimeout: () => void) {
    if (this.active >= this.maximum || (key && this.keys.has(key))) {
      this.rejected++;
      return undefined;
    }
    this.active++;
    if (key) {
      this.keys.add(key);
    }
    let finished = false;
    let expired = false;
    const timer = setTimeout(() => {
      expired = true;
      this.timedOut++;
      this.expiredActive++;
      onTimeout();
    }, timeoutMs);
    timer.unref();
    return {
      expired: () => expired,
      finish: () => {
        if (finished) {
          return false;
        }
        finished = true;
        clearTimeout(timer);
        this.active--;
        if (expired) {
          this.expiredActive--;
        }
        if (key) {
          this.keys.delete(key);
        }
        return true;
      },
    };
  }

  statistics() {
    return { active: this.active, maximum: this.maximum, rejected: this.rejected,
      timedOut: this.timedOut, expiredActive: this.expiredActive };
  }
}

export function requestLanguage(req: Request, languages: string[], defaultLanguage: string): string {
  const active = languages.map(language => language.toLowerCase());
  const fallback = active.includes(defaultLanguage?.toLowerCase())
    ? defaultLanguage.toLowerCase() : (active[0] || 'en');
  const cookie = req.cookies?.dsLanguage;
  if (typeof cookie === 'string' && active.includes(cookie.toLowerCase())) {
    return cookie.toLowerCase();
  }
  const requested = (req.get('accept-language') || '').split(',')
    .map((entry, index) => {
      const [tag, ...parameters] = entry.trim().toLowerCase().split(';');
      const quality = parameters.find(parameter => parameter.trim().startsWith('q='));
      return { tag, quality: quality ? Number(quality.trim().substring(2)) : 1, index };
    })
    .filter(entry => entry.tag && entry.tag !== '*' && Number.isFinite(entry.quality) && entry.quality > 0)
    .sort((first, second) => second.quality - first.quality || first.index - second.index);
  for (const entry of requested) {
    const match = active.find(language => language === entry.tag) ||
      active.find(language => language === entry.tag.split('-')[0]);
    if (match) {
      return match;
    }
  }
  return fallback;
}

/** Only plain, public landing pages are eligible for a shared response. */
export function isCacheableRequest(req: Request): boolean {
  if (req.method !== 'GET' || req.cookies?.dsAuthInfo || req.get('authorization') || req.url.includes('?')) {
    return false;
  }
  return /^(?:\/?|\/home|\/(?:items|collections|communities)\/[a-f0-9-]{36}(?:\/full)?|\/static\/[a-z0-9-]+(?:\.html)?)$/i
    .test(req.path.replace(/\/$/, ''));
}

/** Match only known scanner paths at the UI root, never resource filenames. */
export function isScannerPath(path: string): boolean {
  return /^\/(?:\.git|\.svn|\.env|wp-admin|wp-includes|cgi-bin)(?:[/.]|$)/i.test(path) ||
    /^\/[^/]+\.(?:php|asp|aspx|jsp|cgi|dll)(?:\/|$)/i.test(path);
}

function createPageCache(options: PageCacheOptions, defaultBytes: number) {
  if (!options.max) {
    return undefined;
  }
  const maxSize = options.maxSizeBytes ?? defaultBytes;
  return new LRU<string, CachedPage>({
    max: options.max,
    maxSize,
    maxEntrySize: Math.min(options.maxEntrySizeBytes ?? 4 * 1024 * 1024, maxSize),
    ttl: options.timeToLive,
    allowStale: options.allowStale,
    // Conservatively account for two bytes per character plus object overhead.
    sizeCalculation: (value, key) => 2 * (key.length + value.page.length + JSON.stringify(value.headers).length) + 1024,
  });
}

export class SsrPageRuntime {
  private gate: RenderGate;
  private botCache: LRU<string, CachedPage>;
  private anonymousCache: LRU<string, CachedPage>;
  private excluded: RegExp[];
  private timeoutMs: number;

  constructor(private options: SsrRuntimeOptions) {
    this.gate = new RenderGate(options.maxConcurrentRenders ?? 4);
    this.timeoutMs = options.renderTimeoutMs ?? 10000;
    if (!Number.isSafeInteger(this.timeoutMs) || this.timeoutMs < 1) {
      throw new Error('renderTimeoutMs must be a positive integer');
    }
    this.excluded = (options.excludePathPatterns || []).map(pattern => new RegExp(pattern.pattern, pattern.flag || ''));
    this.botCache = createPageCache(options.botCache, 64 * 1024 * 1024);
    this.anonymousCache = createPageCache(options.anonymousCache, 16 * 1024 * 1024);
  }

  handle = (req: Request, res: Response) => {
    if (isScannerPath(req.path)) {
      res.status(404).set('Cache-Control', 'no-store').type('text/plain').send('Not found');
      return;
    }
    if (!this.options.enabled || req.method !== 'GET' || this.excluded.some(pattern => {
      pattern.lastIndex = 0;
      return pattern.test(req.path);
    })) {
      this.options.renderClient(req, res);
      return;
    }

    const key = isCacheableRequest(req)
      ? `${req.url}::lang=${requestLanguage(req, this.options.languages, this.options.defaultLanguage)}` : undefined;
    const selectedCache = isbot(req.get('user-agent') || '') ? this.botCache : this.anonymousCache;
    const cached = key && selectedCache?.get(key);
    if (cached) {
      Object.entries(cached.headers).forEach(([name, value]) => res.setHeader(name, value));
      res.locals.ssr = true;
      res.send(cached.page);
      // With allowStale, LRU removes an expired entry after returning it once.
      // The next request refreshes it using its own live response context.
      return;
    }

    const lease = this.gate.start(key, this.timeoutMs, () => {
      this.options.warn?.('SSR response deadline exceeded; outstanding work remains counted');
      this.unavailable(res);
    });
    if (!lease) {
      this.unavailable(res);
      return;
    }
    const complete = (error: any, html?: string) => {
      if (!lease.finish() || lease.expired() || res.headersSent || res.destroyed) {
        return;
      }
      if (error || typeof html !== 'string') {
        this.options.warn?.('SSR rendering failed');
        if (isbot(req.get('user-agent') || '')) {
          this.unavailable(res);
        } else {
          this.options.renderClient(req, res);
        }
        return;
      }
      if (this.options.replaceRestUrl && this.options.internalRestUrl !== this.options.publicRestUrl) {
        html = html.split(this.options.internalRestUrl).join(this.options.publicRestUrl);
      }
      if (key && res.statusCode >= 200 && res.statusCode < 300 && !res.hasHeader('Set-Cookie') &&
          !/private|no-store/i.test(String(res.getHeader('Cache-Control') || ''))) {
        const headers: Record<string, any> = {};
        this.options.cacheHeaders.filter(name => !/^set-cookie$/i.test(name)).forEach(name => {
          if (res.hasHeader(name)) {
            headers[name] = res.getHeader(name);
          }
        });
        const value = { page: html, headers };
        this.botCache?.set(key, value);
        this.anonymousCache?.set(key, value);
      }
      res.locals.ssr = true;
      res.send(html);
    };
    try {
      this.options.render(req, res, complete);
    } catch (error) {
      complete(error);
    }
  };

  statistics() {
    return {
      render: this.gate.statistics(),
      botCache: { entries: this.botCache?.size || 0, bytes: this.botCache?.calculatedSize || 0 },
      anonymousCache: { entries: this.anonymousCache?.size || 0, bytes: this.anonymousCache?.calculatedSize || 0 },
    };
  }

  isStalled(): boolean {
    const state = this.gate.statistics();
    return state.expiredActive === state.maximum;
  }

  private unavailable(res: Response) {
    if (!res.headersSent && !res.destroyed) {
      res.status(503).set({ 'Retry-After': '1', 'Cache-Control': 'no-store' }).type('text/plain').send('Temporarily unavailable');
    }
  }
}

export function readinessHandler(url: string, timeoutMs = 3000, client = axios) {
  return (_req: Request, res: Response) => {
    res.set('Cache-Control', 'no-store');
    void client.get(url, { timeout: timeoutMs }).then(response => {
      if (!res.headersSent && !res.destroyed) {
        res.status(response.status).send(response.data);
      }
    }).catch(() => {
      if (!res.headersSent && !res.destroyed) {
        res.status(503).json({ status: 'DOWN', error: 'Backend health check unavailable' });
      }
    });
  };
}
