export type Novel = {
  url?: string;
  id: string;
  title: string;
  alias?: string | null;
  author: string;
  status: string;
  coverUrl?: string | null;
  tags: string[];
  publisher?: string | null;
  description?: string | null;
};

export type Chapter = {
  index: number;
  name: string;
  url?: string | null;
};

export type Volume = {
  index: number;
  name: string;
  chapterCount: number;
  coverUrl?: string | null;
  chapters: Chapter[];
};

export type PreviewResponse = {
  novel: Novel;
  catalog: {
    volumes: Volume[];
  };
  source: {
    name: string;
    url: string;
  };
};

export type NovelSearchResult = {
  source: "bili" | "wenku" | string;
  sourceName: string;
  id: string;
  title: string;
  url: string;
  author?: string | null;
  description?: string | null;
  coverUrl?: string | null;
};

export type SearchResponse = {
  query: string;
  source: string;
  page: number;
  results: NovelSearchResult[];
};

export type LogEntry = {
  time: string;
  level: "INFO" | "ERROR" | string;
  message: string;
};

export type JobFile = {
  id: string;
  name: string;
  sizeBytes: number;
  createdAt: string;
  expiresAt: string;
  expired: boolean;
  downloadUrl?: string | null;
};

export type PackJob = {
  id: string;
  url: string;
  status: "queued" | "running" | "completed" | "failed" | "canceled";
  message: string;
  error?: string | null;
  phase?: string | null;
  currentVolume?: string | null;
  currentChapter?: string | null;
  activeChapterCount?: number;
  completed: number;
  total: number;
  percent: number;
  createdAt: string;
  updatedAt: string;
  startedAt?: string | null;
  finishedAt?: string | null;
  novel?: Novel | null;
  catalog?: { volumes: Volume[] } | null;
  logs: LogEntry[];
  files: JobFile[];
};

export type PackJobProgress = {
  id: string;
  status: PackJob["status"];
  message: string;
  error?: string | null;
  phase?: string | null;
  currentVolume?: string | null;
  currentChapter?: string | null;
  activeChapterCount?: number;
  completed: number;
  total: number;
  percent: number;
  updatedAt: string;
  startedAt?: string | null;
  finishedAt?: string | null;
  latestLog?: LogEntry | null;
};

export type JobListResponse = {
  jobs: PackJob[];
};

export type DeleteJobResponse = {
  deleted: boolean;
  id: string;
  missing?: boolean;
};

export type CreateJobPayload = {
  url: string;
  volumeIndexes: number[];
  volumeRange?: string;
  combineVolume: boolean;
  addChapterTitle: boolean;
};

export type RuntimeConfig = {
  maxConcurrent: number;
  chapterConcurrency: number;
  imageConcurrency: number;
  sourceRateMode: "stable" | "fast" | string;
  fileTtlHours: number;
};

export type HealthResponse = {
  ok: boolean;
  time: string;
  config?: RuntimeConfig;
};
