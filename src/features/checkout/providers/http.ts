/** Minimal HTTP port so provider code is unit-tested with a fake and never touches the network. */
export interface HttpRequest {
  method: "GET" | "POST";
  url: string;
  headers: Readonly<Record<string, string>>;
  body?: string;
}

export interface HttpResponse {
  status: number;
  body: string;
}

export interface HttpClient {
  request(req: HttpRequest): Promise<HttpResponse>;
}

const TIMEOUT_MS = 15_000;

/** Real client. Not used by any test. */
export const fetchHttpClient: HttpClient = {
  async request(req) {
    const init: RequestInit = {
      method: req.method,
      headers: { ...req.headers },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    };
    if (req.body !== undefined) init.body = req.body;
    const response = await fetch(req.url, init);
    return { status: response.status, body: await response.text() };
  },
};
