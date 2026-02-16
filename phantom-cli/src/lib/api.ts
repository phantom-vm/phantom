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
}

// MARK: - TCP Client

export async function sendStreamingRequest(
  request: APIRequest,
  onChunk: (chunk: StreamChunk) => void,
  options?: { timeoutMs?: number }
): Promise<{ exitCode: number }> {
  const timeoutMs = options?.timeoutMs ?? 3600_000; // 1 hour default for streaming
  let buffer = "";
  let resolver: ((value: { exitCode: number }) => void) | null = null;
  let rejector: ((error: Error) => void) | null = null;

  const promise = new Promise<{ exitCode: number }>((resolve, reject) => {
    resolver = resolve;
    rejector = reject;
  });

  const timer = setTimeout(() => {
    if (rejector) rejector(new Error("Streaming request timed out"));
  }, timeoutMs);

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
              clearTimeout(timer);
              if (resolver) resolver({ exitCode: chunk.exitCode ?? -1 });
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
        if (rejector) rejector(error);
      },
      open(_socket) {
        const requestJson = JSON.stringify(request) + "\n";
        _socket.write(requestJson);
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
      open(_socket) {
        // Send request with newline delimiter
        const requestJson = JSON.stringify(request) + "\n";
        _socket.write(requestJson);
      },
    },
  });

  const response = await responsePromise;
  return JSON.parse(response);
}
