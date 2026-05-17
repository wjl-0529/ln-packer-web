import type {
  CreateJobPayload,
  DeleteJobResponse,
  HealthResponse,
  JobListResponse,
  PackJob,
  PackJobProgress,
  PreviewResponse,
  SearchResponse,
} from "./types";

export class ApiError extends Error {
  status: number;
  code?: string;

  constructor(message: string, status: number, code?: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

export async function getHealth(token = ""): Promise<HealthResponse> {
  return requestJson<HealthResponse>("/api/health", token);
}

export async function previewNovel(
  url: string,
  token: string,
): Promise<PreviewResponse> {
  return requestJson<PreviewResponse>("/api/novels/preview", token, {
    method: "POST",
    body: JSON.stringify({ url }),
  });
}

export async function searchNovels(
  query: string,
  source: string,
  token: string,
): Promise<SearchResponse> {
  const params = new URLSearchParams({
    query,
    source,
    page: "1",
  });
  return requestJson<SearchResponse>(`/api/novels/search?${params}`, token);
}

export async function createJob(
  payload: CreateJobPayload,
  token: string,
): Promise<PackJob> {
  return requestJson<PackJob>("/api/jobs", token, {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

export async function getJob(id: string, token: string): Promise<PackJob> {
  return requestJson<PackJob>(`/api/jobs/${id}`, token);
}

export async function cancelJob(id: string, token: string): Promise<PackJob> {
  return requestJson<PackJob>(`/api/jobs/${id}/cancel`, token, {
    method: "POST",
    body: JSON.stringify({}),
  });
}

export async function deleteJob(
  id: string,
  token: string,
): Promise<DeleteJobResponse> {
  return requestJson<DeleteJobResponse>(`/api/jobs/${id}`, token, {
    method: "DELETE",
  });
}

export async function listJobs(token: string): Promise<JobListResponse> {
  return requestJson<JobListResponse>("/api/jobs", token);
}

export function openJobEvents(
  jobId: string,
  token: string,
  onJob: (job: PackJob) => void,
  onProgress: (progress: PackJobProgress) => void,
  onError: () => void,
): EventSource {
  const events = new EventSource(withToken(`/api/jobs/${jobId}/events`, token));
  events.addEventListener("job", (event) => {
    onJob(JSON.parse((event as MessageEvent).data) as PackJob);
  });
  events.addEventListener("progress", (event) => {
    onProgress(JSON.parse((event as MessageEvent).data) as PackJobProgress);
  });
  events.onerror = () => onError();
  return events;
}

export function downloadUrl(url: string, token: string): string {
  return withToken(url, token);
}

async function requestJson<T>(
  url: string,
  token: string,
  init: RequestInit = {},
): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("content-type", "application/json");
  if (token.trim()) {
    headers.set("x-packer-token", token.trim());
  }

  const response = await fetch(url, {
    ...init,
    headers,
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const message =
      data && typeof data.error === "string"
        ? data.error
        : `请求失败 (${response.status})`;
    throw new ApiError(
      message,
      response.status,
      data && typeof data.code === "string" ? data.code : undefined,
    );
  }
  return data as T;
}

function withToken(url: string, token: string): string {
  if (!token.trim()) return url;
  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}token=${encodeURIComponent(token.trim())}`;
}
