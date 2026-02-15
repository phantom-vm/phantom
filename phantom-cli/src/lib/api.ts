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

export interface Image {
  id: string;
  path: string;
  size: number;
}

export interface VM {
  id: string;
  path: string;
  state: string;
}

// MARK: - TCP Client

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
