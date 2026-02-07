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

export async function sendRequest(request: APIRequest): Promise<APIResponse> {
  let buffer = "";
  let responseResolver: ((value: string) => void) | null = null;

  const responsePromise = new Promise<string>((resolve) => {
    responseResolver = resolve;
  });

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
          if (responseResolver) {
            responseResolver(response);
          }
          _socket.end();
        }
      },
      error(_socket, error) {
        console.error("Connection error:", error);
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
