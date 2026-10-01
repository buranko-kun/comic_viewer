/** ComicViewer source API v1. Declarations are optional; deployed plugins remain one JS file. */
type PluginResource = string | { url: string; referrer?: string; useBrowserCookies?: boolean };
interface PluginContext {
  url: string;
  settings: Record<string, string | number | boolean>;
  operationID: string;
  refresh: boolean;
  signal: AbortSignal;
  diagnostic(event: Record<string, unknown>): void;
}
interface PluginSetting {
  id: string;
  title: string;
  description?: string;
  type: 'string' | 'text' | 'password' | 'number' | 'bool' | 'boolean' | 'toggle' | 'select' | 'picker';
  defaultValue: string | number | boolean;
  options?: string[];
}
interface PluginManifest {
  id: string;
  name: string;
  version: string;
  apiVersion?: 1;
  homepage?: string;
  description?: string;
  tags?: string[];
  /** static-session + browser-session: blank same-origin worker; no homepage scripts/subresources. */
  capabilities?: string[];
  settings?: PluginSetting[];
  /** Default 60 seconds; allowed range 1–900. Navigation independently times out after 30s. */
  operationTimeoutSeconds?: number;
}
interface PluginComic {
  id?: string;
  title?: string;
  description?: string;
  cover?: PluginResource | null;
  series?: string;
  format?: string;
  mirrors?: string[];
  hasMirrors?: boolean;
  link?: string;
  size?: string;
  mustRead?: boolean;
  mustReadTitle?: string;
  metadata?: Record<string, string>;
  opensCatalog?: boolean;
  canRead?: boolean;
}
interface PluginCatalog {
  name?: string;
  comics?: PluginComic[];
  catalogs?: { name?: string; url: string }[];
}
interface ComicViewerSourcePlugin {
  manifest: PluginManifest;
  browseURL: string | (() => string | Promise<string>);
  settings?: Record<string, string | number | boolean>;
  parseCatalog(context: PluginContext): PluginCatalog | Promise<PluginCatalog>;
  parsePages?(context: PluginContext): { pages: PluginResource[] } | Promise<{ pages: PluginResource[] }>;
  clearCache?(): void | Promise<void>;
}
declare var ComicViewerSource: ComicViewerSourcePlugin;
