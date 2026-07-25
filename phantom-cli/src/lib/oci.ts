// Minimal OCI Distribution client, used only for the image catalog.
//
// The daemon has its own Swift client for the multi-gigabyte image blobs; this
// one exists because the catalog is a single small JSON artifact that the CLI
// reads on every `image list`, and routing that through the daemon would buy
// nothing. Reads are anonymous where the registry allows it, which is what lets
// a fresh install list images before it has any credentials.

const MANIFEST_TYPE = "application/vnd.oci.image.manifest.v1+json";
const EMPTY_CONFIG_TYPE = "application/vnd.oci.empty.v1+json";

export interface ParsedRef {
  registry: string;
  namespace: string;
  reference: string;
}

export function parseRef(input: string): ParsedRef {
  const at = input.lastIndexOf("@");
  let remaining = input;
  let reference = "latest";

  if (at !== -1) {
    reference = input.slice(at + 1);
    remaining = input.slice(0, at);
  } else {
    const lastSlash = input.lastIndexOf("/");
    const colon = input.indexOf(":", lastSlash === -1 ? 0 : lastSlash);
    if (colon !== -1) {
      reference = input.slice(colon + 1);
      remaining = input.slice(0, colon);
    }
  }

  const slash = remaining.indexOf("/");
  if (slash === -1) throw new Error(`reference must include a registry: ${input}`);
  return {
    registry: remaining.slice(0, slash),
    namespace: remaining.slice(slash + 1),
    reference,
  };
}

export interface Credentials {
  username: string;
  password: string;
}

/// Credentials for a registry: explicit environment variables first, then
/// whatever `docker login` left behind.
///
/// The CLI resolves these and hands them to the daemon in the request, rather
/// than letting the daemon look them up: the daemon is a GUI app launched by
/// Launch Services, so it never inherits the shell environment these usually
/// live in.
export async function credentialsFor(registry: string): Promise<Credentials | undefined> {
  const envUser = process.env.PHANTOM_REGISTRY_USERNAME;
  const envPass = process.env.PHANTOM_REGISTRY_PASSWORD;
  if (envUser && envPass) return { username: envUser, password: envPass };

  const file = Bun.file(`${process.env.HOME}/.docker/config.json`);
  if (!(await file.exists())) return undefined;

  let config: {
    auths?: Record<string, { auth?: string }>;
    credsStore?: string;
    credHelpers?: Record<string, string>;
  };
  try {
    config = await file.json();
  } catch {
    return undefined;
  }

  const candidates = [registry, `https://${registry}`, `http://${registry}`];

  for (const candidate of candidates) {
    const auth = config.auths?.[candidate]?.auth;
    if (!auth) continue;
    const [username, ...rest] = Buffer.from(auth, "base64").toString().split(":");
    if (username && rest.length > 0) return { username, password: rest.join(":") };
  }

  // Docker Desktop on macOS defaults to credsStore "osxkeychain", which leaves
  // the auths entry empty and keeps the secret in the Keychain. The helper
  // protocol is a subprocess that takes the registry on stdin.
  const helper = config.credHelpers?.[registry] ?? config.credsStore;
  if (!helper) return undefined;
  if (!candidates.some((c) => config.auths?.[c] !== undefined) && !config.credHelpers?.[registry]) {
    return undefined; // not logged in to this registry
  }

  try {
    const proc = Bun.spawn([`docker-credential-${helper}`, "get"], {
      stdin: new TextEncoder().encode(registry),
      stdout: "pipe",
      stderr: "ignore",
    });
    if ((await proc.exited) !== 0) return undefined;
    const out = (await new Response(proc.stdout).json()) as {
      Username?: string;
      Secret?: string;
    };
    if (!out.Username || !out.Secret) return undefined;
    return { username: out.Username, password: out.Secret };
  } catch {
    return undefined;
  }
}

export function digestOf(data: Uint8Array): string {
  const hash = new Bun.CryptoHasher("sha256");
  hash.update(data);
  return `sha256:${hash.digest("hex")}`;
}

/// Speaks to one repository, acquiring a token only when the registry asks for
/// one. A registry with no auth at all (a local `registry:2`) has no token
/// endpoint, so requesting a token up front would fail against it.
export class RegistryClient {
  private bearer?: string;

  constructor(
    readonly ref: ParsedRef,
    private creds?: Credentials
  ) {}

  static async for(reference: string): Promise<RegistryClient> {
    const ref = parseRef(reference);
    return new RegistryClient(ref, await credentialsFor(ref.registry));
  }

  private get base() {
    const proto = this.ref.registry.startsWith("localhost") ? "http" : "https";
    return `${proto}://${this.ref.registry}/v2/${this.ref.namespace}`;
  }

  /// Request, retrying once through the token flow if challenged.
  async request(
    method: string,
    path: string,
    init: { headers?: Record<string, string>; body?: Uint8Array; redirect?: "follow" | "manual" | "error" } = {}
  ): Promise<Response> {
    const url = path.startsWith("http") ? path : `${this.base}${path}`;
    const send = () =>
      fetch(url, {
        method,
        headers: {
          ...(init.headers ?? {}),
          ...(this.bearer ? { Authorization: `Bearer ${this.bearer}` } : {}),
        },
        body: init.body,
        redirect: init.redirect ?? "follow",
        signal: AbortSignal.timeout(120_000),
      });

    let res = await send();
    if (res.status !== 401) return res;

    const challenge = res.headers.get("www-authenticate");
    if (!challenge) return res;
    this.bearer = await this.token(challenge);
    return send();
  }

  /// Exchange a `WWW-Authenticate: Bearer realm=…,service=…,scope=…` challenge
  /// for a token. Anonymous unless credentials are available — ghcr.io hands out
  /// read tokens to anyone for public packages.
  private async token(challenge: string): Promise<string> {
    const field = (name: string) => challenge.match(new RegExp(`${name}="([^"]+)"`))?.[1];
    const realm = field("realm");
    if (!realm) throw new Error(`unsupported auth challenge: ${challenge}`);

    const url = new URL(realm);
    const service = field("service");
    const scope = field("scope");
    if (service) url.searchParams.set("service", service);
    if (scope) url.searchParams.set("scope", scope);

    const headers: Record<string, string> = {};
    if (this.creds) {
      const basic = Buffer.from(`${this.creds.username}:${this.creds.password}`).toString("base64");
      headers.Authorization = `Basic ${basic}`;
    }

    const res = await fetch(url, { headers, signal: AbortSignal.timeout(30_000) });
    if (!res.ok) throw new Error(`auth failed for ${this.ref.namespace} (${res.status})`);
    const body = (await res.json()) as { token?: string; access_token?: string };
    const token = body.token ?? body.access_token;
    if (!token) throw new Error("auth response had no token");
    return token;
  }

  /// Digest the registry holds for a reference — authoritative, since only the
  /// registry knows the exact manifest bytes it stored.
  async manifestDigest(): Promise<string> {
    const res = await this.request("HEAD", `/manifests/${this.ref.reference}`, {
      headers: { Accept: MANIFEST_TYPE },
    });
    if (!res.ok) throw new Error(`could not read back the manifest (${res.status})`);
    const digest = res.headers.get("docker-content-digest");
    if (!digest) throw new Error("registry did not return a content digest");
    return digest;
  }
}

interface Manifest {
  layers: { mediaType: string; digest: string; size: number }[];
}

/// Pull an artifact's first layer blob, verifying it against its digest.
export async function pullArtifact(reference: string): Promise<Uint8Array> {
  const client = await RegistryClient.for(reference);

  const manifestRes = await client.request("GET", `/manifests/${client.ref.reference}`, {
    headers: { Accept: MANIFEST_TYPE },
  });
  if (!manifestRes.ok) throw new Error(`pulling manifest: ${manifestRes.status}`);
  const manifest = (await manifestRes.json()) as Manifest;
  const layer = manifest.layers?.[0];
  if (!layer) throw new Error("artifact has no layers");

  const blobRes = await client.request("GET", `/blobs/${layer.digest}`);
  if (!blobRes.ok) throw new Error(`pulling blob: ${blobRes.status}`);
  const data = new Uint8Array(await blobRes.arrayBuffer());

  const actual = digestOf(data);
  if (actual !== layer.digest) {
    throw new Error(`digest mismatch: expected ${layer.digest}, got ${actual}`);
  }
  return data;
}

/// Push `data` as a single-layer artifact.
export async function pushArtifact(reference: string, data: Uint8Array, layerType: string) {
  const client = await RegistryClient.for(reference);

  const empty = new Uint8Array([0x7b, 0x7d]); // "{}"
  const layerDigest = digestOf(data);
  const configDigest = digestOf(empty);

  for (const [digest, blob] of [
    [layerDigest, data],
    [configDigest, empty],
  ] as const) {
    const head = await client.request("HEAD", `/blobs/${digest}`);
    if (head.ok) continue;

    const start = await client.request("POST", `/blobs/uploads/`);
    if (!start.ok && start.status !== 202) {
      throw new Error(`starting upload: ${start.status} ${await start.text()}`);
    }
    const location = start.headers.get("location");
    if (!location) throw new Error("upload response had no Location");

    const proto = client.ref.registry.startsWith("localhost") ? "http" : "https";
    const url = new URL(location, `${proto}://${client.ref.registry}`);
    url.searchParams.set("digest", digest);

    const put = await client.request("PUT", url.toString(), {
      headers: { "Content-Type": "application/octet-stream" },
      body: blob,
    });
    if (!put.ok && put.status !== 201) {
      throw new Error(`uploading blob: ${put.status} ${await put.text()}`);
    }
  }

  const manifest = {
    schemaVersion: 2,
    mediaType: MANIFEST_TYPE,
    config: { mediaType: EMPTY_CONFIG_TYPE, digest: configDigest, size: empty.length },
    layers: [{ mediaType: layerType, digest: layerDigest, size: data.length }],
  };

  const put = await client.request("PUT", `/manifests/${client.ref.reference}`, {
    headers: { "Content-Type": MANIFEST_TYPE },
    body: new TextEncoder().encode(JSON.stringify(manifest)),
  });
  if (!put.ok && put.status !== 201) {
    throw new Error(`pushing manifest: ${put.status} ${await put.text()}`);
  }
}
