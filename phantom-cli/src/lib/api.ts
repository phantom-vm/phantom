// MARK: - Types

export interface APIRequest {
  method: string;
  params?: Record<string, any>;
}

export interface APIResponse {
  result?: any;
  error?: {
    code: string;
    message: string;
  };
}

export interface IPSW {
  id: string;
  path: string;
  size: number;
}

export interface VM {
  id: string;
  path: string;
  state: string;
}

// MARK: - Streaming Types

export interface StreamChunk {
  type: "stdout" | "stderr" | "done";
  data?: string;
  exitCode?: number;
  error?: string;
  /// "base64" when `data` is bytes rather than text — everything that comes
  /// back from a pty.
  encoding?: string;
}

// MARK: - TCP Client

/// A request written in as many passes as the socket needs.
///
/// `socket.write` returns how many bytes it took, not how many it was given —
/// the rest has to wait for the socket to drain. Requests are not always small
/// (a job's whole script is base64-encoded into a `vm.execStream` command), and
/// a partial write left the daemon holding half a request, waiting for a
/// delimiter that was still sitting in this process.
function requestWriter(request: APIRequest) {
  const bytes = new TextEncoder().encode(JSON.stringify(request) + "\n");
  let written = 0;

  return (socket: { write(data: Uint8Array): number }) => {
    while (written < bytes.length) {
      const n = socket.write(bytes.subarray(written));
      if (n <= 0) return; // Socket is full — the drain handler resumes this
      written += n;
    }
  };
}

export async function sendStreamingRequest(
  request: APIRequest,
  onChunk: (chunk: StreamChunk) => void,
  options?: {
    timeoutMs?: number;
    /// Called once the connection is up, with a way to keep writing to it —
    /// how an interactive session sends keystrokes and window sizes to a
    /// command that is already running. Whatever it returns is run when the
    /// stream ends, for putting the terminal back.
    onOpen?: (write: (frame: unknown) => void) => (() => void) | void;
  }
): Promise<{ exitCode: number }> {
  const timeoutMs = options?.timeoutMs ?? 3600_000; // 1 hour default for streaming
  let buffer = "";
  let resolver: ((value: { exitCode: number }) => void) | null = null;
  let rejector: ((error: Error) => void) | null = null;
  let teardown: (() => void) | void;

  const promise = new Promise<{ exitCode: number }>((resolve, reject) => {
    resolver = resolve;
    rejector = reject;
  });

  const timer = setTimeout(() => {
    if (rejector) rejector(new Error("Streaming request timed out"));
  }, timeoutMs);

  // One queue for everything this side sends: the request, then any frames an
  // interactive session adds. `socket.write` reports how many bytes it took,
  // not how many it was given, so what is left waits for the drain.
  const queue: Uint8Array[] = [new TextEncoder().encode(JSON.stringify(request) + "\n")];
  let offset = 0;
  let socketRef: { write(data: Uint8Array): number } | null = null;

  const flush = () => {
    if (!socketRef) return;
    while (queue.length) {
      const head = queue[0]!;
      const n = socketRef.write(head.subarray(offset));
      if (n <= 0) return;
      offset += n;
      if (offset >= head.length) {
        queue.shift();
        offset = 0;
      }
    }
  };

  const send = (frame: unknown) => {
    queue.push(new TextEncoder().encode(JSON.stringify(frame) + "\n"));
    flush();
  };

  const finish = (exitCode: number) => {
    clearTimeout(timer);
    if (teardown) teardown();
    if (resolver) resolver({ exitCode });
  };

  await Bun.connect({
    hostname: "localhost",
    port: 9090,
    socket: {
      data(_socket, data) {
        buffer += new TextDecoder().decode(data);

        // Process all complete lines
        let newlineIndex: number;
        while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
          const line = buffer.substring(0, newlineIndex);
          buffer = buffer.substring(newlineIndex + 1);

          try {
            const chunk: StreamChunk = JSON.parse(line);
            if (chunk.type === "done") {
              finish(chunk.exitCode ?? -1);
              _socket.end();
              return;
            }
            onChunk(chunk);
          } catch {
            // Skip malformed lines
          }
        }
      },
      error(_socket, error) {
        clearTimeout(timer);
        if (teardown) teardown();
        if (rejector) rejector(error);
      },
      close() {
        // The daemon closing without a done chunk is still the end of the
        // session — a terminal left in raw mode would be worse than a wrong
        // exit code.
        if (teardown) teardown();
      },
      drain(_socket) {
        socketRef = _socket;
        flush();
      },
      open(_socket) {
        socketRef = _socket;
        flush();
        teardown = options?.onOpen?.(send);
      },
    },
  });

  return promise;
}

export async function sendRequest(
  request: APIRequest,
  options?: { timeoutMs?: number }
): Promise<APIResponse> {
  const timeoutMs = options?.timeoutMs ?? 30_000;
  let buffer = "";
  let responseResolver: ((value: string) => void) | null = null;
  let responseRejector: ((error: Error) => void) | null = null;

  const responsePromise = new Promise<string>((resolve, reject) => {
    responseResolver = resolve;
    responseRejector = reject;
  });

  const timer = setTimeout(() => {
    if (responseRejector) {
      responseRejector(new Error("Request timed out"));
    }
  }, timeoutMs);

  const writeRequest = requestWriter(request);

  await Bun.connect({
    hostname: "localhost",
    port: 9090,
    socket: {
      data(_socket, data) {
        buffer += new TextDecoder().decode(data);

        // Check for newline delimiter
        const newlineIndex = buffer.indexOf("\n");
        if (newlineIndex !== -1) {
          const response = buffer.substring(0, newlineIndex);
          clearTimeout(timer);
          if (responseResolver) {
            responseResolver(response);
          }
          _socket.end();
        }
      },
      error(_socket, error) {
        clearTimeout(timer);
        if (responseRejector) {
          responseRejector(error);
        }
      },
      drain(_socket) {
        writeRequest(_socket);
      },
      open(_socket) {
        writeRequest(_socket);
      },
    },
  });

  const response = await responsePromise;
  return JSON.parse(response);
}
